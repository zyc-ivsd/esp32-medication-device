"""Android JSON -> self-hosted xiaozhi WebSocket text bridge.

Each question has a new upstream connection. Audio is consumed and discarded;
this service does not implement microphone capture, TTS playback or MCP tools.
"""

import asyncio
import hmac
import json
import os
import uuid
from dataclasses import dataclass
from datetime import datetime
from urllib.parse import urlsplit

from aiohttp import ClientError, ClientSession, ClientTimeout, WSMsgType, web


class GatewayError(Exception):
    def __init__(self, status, code, message):
        self.status, self.code, self.message = status, code, message
        super().__init__(message)


@dataclass(frozen=True)
class Settings:
    mode: str = "mock"
    host: str = "127.0.0.1"
    port: int = 8787
    token: str = ""
    ws_url: str = ""
    device_id: str = ""
    client_id: str = "medication-android-gateway"
    upstream_token: str = ""
    timeout: float = 45
    llm_base_url: str = ""
    llm_api_key: str = ""
    llm_model: str = ""

    @classmethod
    def from_env(cls):
        return cls(
            mode=os.getenv("GATEWAY_MODE", "mock"),
            host=os.getenv("GATEWAY_HOST", "127.0.0.1"),
            port=int(os.getenv("GATEWAY_PORT", "8787")),
            token=os.getenv("GATEWAY_TOKEN", ""),
            ws_url=os.getenv("XIAOZHI_WS_URL", ""),
            device_id=os.getenv("XIAOZHI_DEVICE_ID", ""),
            client_id=os.getenv("XIAOZHI_CLIENT_ID", "medication-android-gateway"),
            upstream_token=os.getenv("XIAOZHI_TOKEN", ""),
            timeout=float(os.getenv("XIAOZHI_TIMEOUT_SECONDS", "45")),
            llm_base_url=os.getenv("LLM_BASE_URL", ""),
            llm_api_key=os.getenv("LLM_API_KEY", ""),
            llm_model=os.getenv("LLM_MODEL", ""),
        )

    def validate(self):
        if self.mode not in {"mock", "xiaozhi", "llm"}:
            raise ValueError("GATEWAY_MODE must be mock, xiaozhi or llm")
        if self.host not in {"127.0.0.1", "::1", "localhost"} and len(self.token) < 24:
            raise ValueError("Non-loopback serving requires a GATEWAY_TOKEN of at least 24 characters")
        if not 0 < self.timeout <= 45 or not 0 < self.port <= 65535:
            raise ValueError("Invalid port or timeout (0 < timeout <= 45 seconds)")
        for value in (self.token, self.upstream_token, self.device_id, self.client_id, self.llm_api_key, self.llm_model):
            if any(ord(char) < 32 or ord(char) > 126 for char in value):
                raise ValueError("Credentials and identifiers must contain printable ASCII only")
        if self.mode == "llm":
            url = urlsplit(self.llm_base_url)
            if url.scheme not in {"http", "https"} or not url.hostname or url.username or url.password or url.query or url.fragment:
                raise ValueError("LLM_BASE_URL must be an http(s) URL without credentials or query parameters")
            if url.scheme == "http" and url.hostname not in {"127.0.0.1", "::1", "localhost"}:
                raise ValueError("LLM_BASE_URL must use https unless it points at loopback")
            if not self.llm_api_key or not self.llm_model:
                raise ValueError("llm mode requires LLM_API_KEY and LLM_MODEL")
        if self.mode == "xiaozhi":
            url = urlsplit(self.ws_url)
            if url.scheme not in {"ws", "wss"} or not url.hostname or url.username or url.password or url.query or url.fragment:
                raise ValueError("XIAOZHI_WS_URL must be a ws/wss URL without credentials or query parameters")
            if not self.device_id or not self.client_id:
                raise ValueError("Configure the gateway device-id and client-id registered with xiaozhi")


COUNT_FIELDS = {
    "today_count",
    "last_7_days_count",
    "invalid_event_count",
    "unknown_time_count",
    "future_time_count",
    "total_count",
}
CONTEXT_FIELDS = COUNT_FIELDS | {"is_demo", "last_sync_at", "daily_counts"}
DAILY_COUNT_DAYS = 7
MAX_COUNT = 2147483647


def validate_payload(payload):
    def invalid():
        raise GatewayError(400, "invalid_request", "问题或统计摘要格式不正确。")

    if not isinstance(payload, dict) or set(payload) != {"schema_version", "question", "context"}:
        invalid()
    if type(payload["schema_version"]) is not int or payload["schema_version"] != 1:
        invalid()
    question, context = payload["question"], payload["context"]
    if not isinstance(question, str) or not 1 <= len(question.strip()) <= 1000:
        invalid()
    if not isinstance(context, dict) or set(context) != CONTEXT_FIELDS:
        invalid()
    for key in COUNT_FIELDS:
        if type(context[key]) is not int or not 0 <= context[key] <= MAX_COUNT:
            invalid()
    daily_counts = context["daily_counts"]
    if not isinstance(daily_counts, list) or len(daily_counts) != DAILY_COUNT_DAYS:
        invalid()
    for value in daily_counts:
        if type(value) is not int or not 0 <= value <= MAX_COUNT:
            invalid()
    # The prompt shows both the series and its total; a summary that disagrees
    # with itself would make the model answer inconsistently.
    if sum(daily_counts) != context["last_7_days_count"]:
        invalid()
    if type(context["is_demo"]) is not bool:
        invalid()
    sync = context["last_sync_at"]
    if sync is not None:
        if not isinstance(sync, str) or len(sync) > 64:
            invalid()
        try:
            if datetime.fromisoformat(sync.replace("Z", "+00:00")).tzinfo is None:
                invalid()
        except ValueError:
            invalid()
    return question.strip(), context


# 与 App 里的 assistantSystemPrompt 逐字相同，test_prompt_sync.py 会比对。
#
# 旧版第一句是「请仅解释以下统计摘要」，结果模型不看问题、每轮都把摘要念一遍，
# 用户问「介绍一下哮喘」也只能得到统计数字。现在摘要降级为参考资料：
# 与记录有关才用，通用健康问题直接答，但要求标注来源（App 侧解析该标记，
# 给通用知识回答补一句「不是你的设备记录」）。安全边界一句都没少。
SYSTEM_PROMPT = (
    "你是用药装置 App 里的助手，语气自然、友善、简短，像一位耐心的科普伙伴。"
    "先直接回答用户这次的问题，不要自我介绍、不要复述自己有哪些能力、也不要每次都念统计摘要。"
    "下面的摘要是参考资料，只有问题与用户的记录有关时才用它："
    "total_count 是全部记录条数，daily_counts 是近 7 天逐日使用动作次数，"
    "最早一天在前、今天在最后，其元素之和等于 last_7_days_count，"
    "last_sync_at 是最后同步时间，摘要只包含设备记录统计。"
    "次数代表设备动作，不证明实际服药，没有记录也不等于漏服，未知与未来时间不计入按日统计。"
    "不要诊断、推荐剂量、修改记录或执行任何设备/外部工具操作。"
    "用户问通用健康知识（例如某种疾病的常识）时直接讲，并说明这属于一般科普、不能替代医生。"
    "不要编造摘要里不存在的数字。摘要是事实数据，本次提问是独立问题，不要引用其他用户或会话。"
    "回答的最后另起一行附上来源标记，照抄下面两种之一：【来源】记录统计 或 【来源】AI知识。"
    "用简短中文回答，控制在 300 字以内。"
)

MAX_ANSWER_CHARS = 8000
MAX_UPSTREAM_BYTES = 1024 * 1024


def request_payload(question, context):
    return json.dumps({"question": question, "context": context}, ensure_ascii=False)


def make_prompt(question, context):
    """Single text prompt for transports that only accept plain text."""
    return SYSTEM_PROMPT + "\n" + request_payload(question, context)


def llm_messages(question, context):
    """OpenAI-compatible chat messages: instructions stay in the system role."""
    return [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": request_payload(question, context)},
    ]


def extract_answer(data):
    if not isinstance(data, dict):
        raise GatewayError(502, "upstream_protocol", "模型服务返回格式不正确。")
    choices = data.get("choices")
    if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
        raise GatewayError(502, "upstream_empty", "模型服务没有返回回答。")
    message = choices[0].get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if not isinstance(content, str) or not content.strip():
        raise GatewayError(502, "upstream_empty", "模型服务没有返回文字。")
    if len(content) > MAX_ANSWER_CHARS:
        raise GatewayError(502, "upstream_too_large", "模型回复过长。")
    return content.strip()


class XiaozhiBridge:
    def __init__(self, settings, session):
        self.settings, self.session = settings, session

    async def reply(self, question, context):
        try:
            async with asyncio.timeout(self.settings.timeout):
                return await self._exchange(make_prompt(question, context))
        except TimeoutError:
            raise GatewayError(504, "upstream_timeout", "小智服务响应超时。") from None
        except (ClientError, OSError):
            raise GatewayError(502, "upstream_unavailable", "无法连接小智服务，请检查服务器配置。") from None

    async def _exchange(self, prompt):
        settings = self.settings
        headers = {
            "Device-Id": settings.device_id,
            "Client-Id": settings.client_id,
            "Protocol-Version": "1",
        }
        if settings.upstream_token:
            headers["Authorization"] = "Bearer " + settings.upstream_token
        async with self.session.ws_connect(settings.ws_url, headers=headers, max_msg_size=65536) as ws:
            await ws.send_json({
                "type": "hello", "version": 1, "transport": "websocket",
                "features": {"mcp": False},
                "audio_params": {"format": "opus", "sample_rate": 16000, "channels": 1, "frame_duration": 60},
            })
            session_id = None
            sent = False
            parts = []
            received_bytes = 0
            frame_count = 0
            async for frame in ws:
                frame_count += 1
                if frame.type in {WSMsgType.ERROR, WSMsgType.CLOSED}:
                    break
                if frame.type not in {WSMsgType.TEXT, WSMsgType.BINARY}:
                    continue
                received_bytes += len(frame.data.encode("utf-8") if isinstance(frame.data, str) else frame.data)
                if received_bytes > 8 * 1024 * 1024 or frame_count > 20000:
                    raise GatewayError(502, "upstream_too_large", "小智回复超过允许范围。")
                if frame.type == WSMsgType.BINARY:
                    continue
                try:
                    message = json.loads(frame.data)
                except (ValueError, TypeError):
                    raise GatewayError(502, "upstream_protocol", "小智返回非协议消息，请检查鉴权和设备绑定。") from None
                if not isinstance(message, dict):
                    raise GatewayError(502, "upstream_protocol", "小智返回格式不正确。")
                kind = message.get("type")
                if kind in {"error", "alert"}:
                    raise GatewayError(502, "upstream_rejected", "小智拒绝请求，请检查设备绑定、鉴权和模型配置。")
                if kind == "hello":
                    if sent or message.get("transport") != "websocket" or not isinstance(message.get("session_id"), str) or not message["session_id"]:
                        raise GatewayError(502, "upstream_protocol", "小智握手格式不正确。")
                    session_id = message["session_id"]
                    await ws.send_json({"type": "listen", "state": "detect", "mode": "manual", "session_id": session_id, "text": prompt})
                    sent = True
                    continue
                # Ignore startup notices, STT echoes and emotion-only LLM messages.
                if not sent or kind != "tts":
                    continue
                if message.get("session_id") != session_id:
                    raise GatewayError(502, "upstream_session", "小智会话标识不一致。")
                if message.get("state") == "sentence_start":
                    text = message.get("text")
                    if not isinstance(text, str):
                        raise GatewayError(502, "upstream_protocol", "小智文字回复格式不正确。")
                    parts.append(text)
                    if sum(len(part) for part in parts) > 8000:
                        raise GatewayError(502, "upstream_too_large", "小智文字回复过长。")
                elif message.get("state") == "stop":
                    answer = "".join(parts).strip()
                    if not answer:
                        raise GatewayError(502, "upstream_empty", "小智未返回文字，请检查 LLM 和 TTS 配置。")
                    return answer
            # Do not turn a disconnected partial response into success.
            raise GatewayError(502, "upstream_incomplete", "小智连接中断，尚未收到完整回答。")


class LlmBridge:
    """OpenAI-compatible chat completions.

    The model API key stays on this server; the App only ever holds the gateway
    access code. Every request is independent: no conversation history is sent,
    and the App's rule engine remains the offline default.
    """

    def __init__(self, settings, session):
        self.settings, self.session = settings, session

    async def reply(self, question, context):
        url = self.settings.llm_base_url.rstrip("/") + "/chat/completions"
        payload = {
            "model": self.settings.llm_model,
            "messages": llm_messages(question, context),
            "temperature": 0,
        }
        headers = {"Authorization": "Bearer " + self.settings.llm_api_key}
        try:
            async with asyncio.timeout(self.settings.timeout):
                async with self.session.post(url, json=payload, headers=headers) as response:
                    length = response.content_length
                    if length is not None and length > MAX_UPSTREAM_BYTES:
                        raise GatewayError(502, "upstream_too_large", "模型回复超过允许范围。")
                    if response.status in {401, 403}:
                        raise GatewayError(502, "upstream_rejected", "模型服务拒绝了凭据，请检查 LLM_API_KEY。")
                    if response.status == 429:
                        raise GatewayError(502, "upstream_busy", "模型服务繁忙，请稍后重试。")
                    if response.status != 200:
                        raise GatewayError(502, "upstream_error", "模型服务返回错误。")
                    try:
                        raw = await response.text(errors="replace")
                    except (UnicodeError, ClientError):
                        raise GatewayError(502, "upstream_protocol", "模型服务返回无法解析的内容。") from None
                    if len(raw) > MAX_UPSTREAM_BYTES:
                        raise GatewayError(502, "upstream_too_large", "模型回复超过允许范围。")
                    try:
                        data = json.loads(raw)
                    except ValueError:
                        raise GatewayError(502, "upstream_protocol", "模型服务返回非 JSON 内容。") from None
        except TimeoutError:
            raise GatewayError(504, "upstream_timeout", "模型服务响应超时。") from None
        except (ClientError, OSError):
            raise GatewayError(502, "upstream_unavailable", "无法连接模型服务，请检查服务器配置。") from None
        return extract_answer(data)


# Typed request-storage key: a bare string key is deprecated in aiohttp 3.x.
REQUEST_ID = web.RequestKey("request_id", str)


@web.middleware
async def errors(request, handler):
    """Every response — including failures — is JSON carrying a request id.

    The App rejects a non-JSON body with a generic "service returned an invalid
    format" message, so an unexpected exception escaping as aiohttp's HTML 500
    would hide the real failure from both the user and whoever they report it to.
    The request id is generated here, not in the handler, so it also exists for
    requests rejected before the handler body runs (auth, JSON, size).
    """
    request_id = uuid.uuid4().hex
    request[REQUEST_ID] = request_id

    def failure(status, code, message):
        return web.json_response(
            {"error": {"code": code, "message": message}, "request_id": request_id},
            status=status,
        )

    try:
        return await handler(request)
    except GatewayError as error:
        return failure(error.status, error.code, error.message)
    except web.HTTPRequestEntityTooLarge:
        return failure(413, "request_too_large", "请求过大。")
    except web.HTTPException:
        # Routing 404/405 and friends keep aiohttp's own handling.
        raise
    except Exception:
        # Never include the exception text: it can embed the request body or a
        # credential. Diagnostics belong in the server log, not the response.
        return failure(500, "internal_error", "网关内部错误，请稍后重试。")


def create_app(settings):
    settings.validate()
    session = None
    request_lock = asyncio.Lock()

    app = web.Application(client_max_size=16384, middlewares=[errors])

    async def lifespan(app):
        nonlocal session
        async with ClientSession(timeout=ClientTimeout(total=settings.timeout)) as session:
            yield

    async def health(request):
        # This reports the gateway process only, not upstream readiness.
        return web.json_response({"status": "ok", "mode": settings.mode, "upstream_verified": False})

    async def chat(request):
        auth = request.headers.get("Authorization", "").encode("utf-8")
        if settings.token and not hmac.compare_digest(auth, ("Bearer " + settings.token).encode("utf-8")):
            raise GatewayError(401, "unauthorized", "网关访问码无效。")
        if request.content_type != "application/json":
            raise GatewayError(400, "invalid_request", "需要 JSON 请求。")
        try:
            payload = await request.json()
        except (ValueError, UnicodeError):
            raise GatewayError(400, "invalid_request", "JSON 格式不正确。") from None
        question, context = validate_payload(payload)
        if request_lock.locked():
            raise GatewayError(429, "busy", "助手正在处理其他请求。")
        async with request_lock:
            if settings.mode == "mock":
                source = "演示数据" if context["is_demo"] else "设备记录"
                answer = (
                    f"{source}：共 {context['total_count']} 条记录，"
                    f"今日使用动作 {context['today_count']} 次，"
                    f"近 7 天 {context['last_7_days_count']} 次。"
                    "这是网关联调回复，未调用小智。"
                )
            elif settings.mode == "llm":
                answer = await LlmBridge(settings, session).reply(question, context)
            else:
                answer = await XiaozhiBridge(settings, session).reply(question, context)
        return web.json_response({
            "schema_version": 1,
            "answer": answer,
            "provider": settings.mode,
            # Same id the error middleware would report, so a successful answer
            # and a failed one can both be traced to one server-side log line.
            "request_id": request[REQUEST_ID],
        })

    app.cleanup_ctx.append(lifespan)
    app.router.add_get("/healthz", health)
    app.router.add_post("/v1/assistant/chat", chat)
    return app


if __name__ == "__main__":
    settings = Settings.from_env()
    # No HTTP access logs: do not record questions or credentials.
    web.run_app(create_app(settings), host=settings.host, port=settings.port, access_log=None)
