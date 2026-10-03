# Android 文字助手网关

> **已废弃（2026-09-30），仅作历史保留，不再推荐部署。** 在线助手的 forward 路线改为 **App 直连用户自己的模型（BYOK）**：API Key 只能是用户自己的、存 `flutter_secure_storage`、绝不出手机。本网关的 `xiaozhi` / `llm` 上游都要求服务端持有团队 Key（或透传用户 Key），与这条规则冲突，因此不再使用；`mock` 模式也只作历史联调参考。要了解现行规则，见 [`docs/assistant-model-access.md`](../../docs/assistant-model-access.md)。

下面是历史说明，保留给需要复现上一阶段联调的成员。

可运行的 Python 服务：Android HTTPS JSON → 上游。三种上游模式：`mock`（不调用模型）、`xiaozhi`（自建 `xiaozhi-esp32-server` 的 WebSocket）、`llm`（任意 OpenAI 兼容 API）。当前为受控原型，尚未接入团队的真实服务器。

## 1. 先运行本机 mock

需要 Python **3.11+**，建议 3.12。Windows PowerShell，从仓库根目录执行：

```powershell
cd server/assistant-gateway
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe -m unittest discover -s tests -v
$env:GATEWAY_MODE = 'mock'
.\.venv\Scripts\python.exe gateway.py
```

Linux / macOS 对应命令：

```bash
cd server/assistant-gateway
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python -m unittest discover -s tests -v
GATEWAY_MODE=mock .venv/bin/python gateway.py
```

服务默认只监听 `127.0.0.1:8787`。另开终端访问 `http://127.0.0.1:8787/healthz`，应看到 `status=ok`、`mode=mock`。`upstream_verified=false` 是固定的诚实状态，健康接口不验证模型或上游。

`config.example.env` 是配置清单；程序**不自动读取 .env**，请通过进程环境变量或部署平台注入。上面的直接命令不依赖激活 venv。

## 2. Android 手机连接本机

先安装 [Android debug APK](../../mobile_app/README.md)，打开 USB 调试并授权电脑，再在装有 Android SDK 的终端执行：

```bash
adb devices
adb reverse tcp:8787 tcp:8787
```

App → 概览 → 导入演示数据 → 问问记录助手 → 右上菜单 → 在线助手设置：

- 服务地址：`http://127.0.0.1:8787/v1/assistant/chat`。
- 默认本机 mock 没有访问码；若设置了 `GATEWAY_TOKEN`，这里填写同一值。
- 勾选摘要发送确认，提问“最近的记录如何？”。
- 应出现“网关演示，尚未调用小智”。这一步只证明手机能到达网关。

Android 模拟器可使用 `http://10.0.2.2:8787/v1/assistant/chat`。断开 USB / 重启手机后可能需要重做 `adb reverse`。局域网 `http://192.168.x.x` 不被 App 接受；使用 HTTPS 部署，或继续通过 USB 调试。

## 3. 服务端切到真实小智

由负责服务器的成员准备以下信息，**不要把小智 Token 或模型密钥发进 APK 或提交到 GitHub**：

| 配置 | 从哪里获得 |
|---|---|
| `XIAOZHI_WS_URL` | 自建服务的 WebSocket 地址，常见 `ws://127.0.0.1:8000/xiaozhi/v1/`；不是智控台 URL |
| `XIAOZHI_DEVICE_ID` | 专门为本网关注册 / 绑定的测试设备身份 |
| `XIAOZHI_CLIENT_ID` | 与鉴权对应的固定客户端身份 |
| `XIAOZHI_TOKEN` | 启用上游鉴权时使用的 Bearer Token，须与上述身份匹配；未启用时可留空 |
| `GATEWAY_TOKEN` | 另外生成的网关访问码；App 只拿到这个，不拿上游 Token |

先在自建小智确认：设备绑定成功、LLM 与 TTS 可用、用于记录解释的角色已配置，并关闭该测试身份的长期记忆、对话持久报告及服务端外部工具。客户端声明不启用 MCP，不会自动禁用服务器自带工具。此实现按设备身份串行处理，暂不支持不同用户共享同一个有记忆的助手身份。

### 想让 App 用上智控台里配的知识库（RAG）

网关发送的是 `state=detect` 的文字消息，服务端会走 `startToChat` —— **与语音问答是同一条管线**。所以智控台里配好的角色设定、知识库、记忆都会作用于 App 的文字提问。

RAGFlow 知识库需要智控台 **0.8.7 或以上**，并在服务端做这四步：

1. `参数字典` → `系统功能配置` → 勾选 **知识库** → 保存配置；
2. `模型配置` → 左侧 `知识库` → 编辑 `RAG_RAGFlow`，填入 RAGFlow 的 `base_url` 与 `api_key`；
3. `智能体` → 找到网关绑定的那个智能体 → `配置角色` → 在**意图识别**左侧点 `编辑功能` → 添加要用的知识库 → 保存；
4. **意图识别不要设成 `nointent`** —— 模型要靠函数调用（`function_call` / `intent_llm`）才能触发 `search_from_ragflow` 去检索，`nointent` 下知识库不会生效。

验证方法：问一个只有知识库里才有答案的问题，对比开启/关闭知识库时的回答。

**声纹识别对文字路径无效** —— 声纹需要麦克风音频，而 App 只发文字，不要把它列为本次验收项。

停止 mock 进程。设置真实值后启动（以下为 PowerShell 模板，尖括号内容必须替换；不把真实值保存进仓库）：

```powershell
$env:GATEWAY_MODE = 'xiaozhi'
$env:XIAOZHI_WS_URL = 'ws://127.0.0.1:8000/xiaozhi/v1/'
$env:XIAOZHI_DEVICE_ID = '<专用测试设备身份>'
$env:XIAOZHI_CLIENT_ID = '<与鉴权匹配的客户端身份>'
$env:XIAOZHI_TOKEN = '<上游Token；未启用鉴权时设为空字符串>'
$env:GATEWAY_TOKEN = '<至少24位的随机网关访问码>'
.\.venv\Scripts\python.exe gateway.py
```

上游运行在另一台机器时改成实际可达地址；跨不可信网络用 `wss://` 和有效证书。为团队手机部署时，在网关前配置可信证书 HTTPS 反向代理（例如 Nginx/Caddy），将请求转发到本机 8787，代理等待时间至少 60 秒，限制请求体并设置访问频率。即便网关监听回环地址，**只要通过代理对外提供服务，就必须设置访问码**。公网不能只依赖本机绑定保护。

Linux 用同名 `export NAME='value'`，再执行 `.venv/bin/python gateway.py`。公开访问时保持单进程、一个专用上游身份；生产化多人服务需另做账号、身份与记忆隔离，不能通过直接多开进程实现。

## 4. 另一种方式：直连模型 API，不需要小智服务端

如果只是想让在线助手用上大模型，**不必部署 `xiaozhi-esp32-server`**。`GATEWAY_MODE=llm` 直接调用 **OpenAI 兼容**的 `/chat/completions`，任何兼容接口都可以（DeepSeek、阿里百炼、火山、智谱、本地 Ollama 等）。

**模型 API Key 只配在这里，不要写进 App、APK、构建参数或仓库。** App 永远只拿网关访问码。

| 配置 | 说明 |
|---|---|
| `GATEWAY_MODE` | 设为 `llm` |
| `LLM_BASE_URL` | 写到 `/chat/completions` **之前**，例如 `https://api.deepseek.com/v1`、本地 Ollama `http://127.0.0.1:11434/v1` |
| `LLM_API_KEY` | 模型平台签发的 Key |
| `LLM_MODEL` | 模型名，例如 `deepseek-chat`、`qwen-plus`、`llama3.1` |
| `GATEWAY_TOKEN` | 另外生成的网关访问码；**App 里填的是这个，不是模型 Key** |

```powershell
$env:GATEWAY_MODE = 'llm'
$env:LLM_BASE_URL = 'https://api.deepseek.com/v1'
$env:LLM_API_KEY = '<模型平台密钥>'
$env:LLM_MODEL = 'deepseek-chat'
$env:GATEWAY_TOKEN = '<至少24位的随机网关访问码>'
.\.venv\Scripts\python.exe gateway.py
```

约束：

- `LLM_BASE_URL` 必须是 `https`；**只有**指向 `127.0.0.1` / `localhost` 时才允许 `http`（本地模型服务）。非回环用 http 会在启动时直接报错。
- 请求无状态：每次提问都是独立会话，不发送历史对话。system 提示词写在 `gateway.py` 的 `SYSTEM_PROMPT`：**摘要是参考资料而不是必答题**——问题与记录有关才用它，问通用健康知识就直接答，但要在最后一行标出 `【来源】记录统计` 或 `【来源】AI知识`（App 侧解析该标记，给通用知识回答补一句「不是你的设备记录」）。禁止诊断、剂量建议和工具调用，这一条没有放宽。
- 上游失败（401/429/非 JSON/空回复/超长）一律返回 `502`，**不会退回 mock 伪造成功**。
- 返回给 App 的 `provider` 是 `llm`。

## 5. 联调验收

| 操作 | 预期 |
|---|---|
| 本地规则模式、断网 | 原有摘要仍可用 |
| 网关 mock | 回复明确提示未调用小智 |
| 真实小智 + 演示摘要 | 收到完整文字回答，不能把演示说成真实服药；响应 provider 为 `xiaozhi` |
| 真实小智 + 知识库问题 | 问一个只有知识库里才有答案的问题，能引用知识库内容；意图识别不能用 `nointent` |
| 直连模型（`llm`）| 响应 provider 为 `llm`；模型 Key 不出现在 App 或响应里 |
| 访问码错误 | 提示访问码无效，不回显密钥 |
| 关闭上游或让其超时 | 显示失败；不能悄悄用 mock 或半截回答代替 |
| 两个问题同时提交 | 后来的请求返回 429，请稍后重试 |
| 真机设备数据 | 必须先完成正式事件入库；原型时间文本不计入摘要 |

验收留存：App 版本、仓库提交、上游提交、Android 机型/版本、脱敏截图与每项结果。不要保存真实问题、个人记录或密钥作为公开证据。

`python -m unittest discover -s tests -v` 会在本机启动模拟 WebSocket 服务，验证握手、鉴权转发、文字聚合、二进制丢弃、错误、超时与并发；**它不证明真实小智服务器或模型已通过**。

## 6. 实现范围

协议、字段及核对的上游提交见 [xiaozhi-bridge.md](../../protocol/xiaozhi-bridge.md)。默认上游总超时 45 秒，只上传单次问题与摘要，无历史对话重发；每次请求新建上游连接，但上游是否持久记忆仍由部署配置决定。

本轮没有语音输入/播放、MCP 工具调用、多人账户、持久网关会话或正式运维平台。日志默认不记录 HTTP 访问详情；反向代理和上游自身日志需要部署成员另外检查。
