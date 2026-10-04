/// 助手可检索的设备知识库（RAG 的检索端），**运行时语料的唯一来源**。
///
/// 语料就是这里。早期另有 `server/assistant-gateway/knowledge/` 下的一份 markdown 副本，
/// 两份靠人肉同步、已经漂移过，所以取消了副本：那个目录现在只写「写什么、怎么写、
/// 怎么验」（收录原则、安全边界、术语、验收），要改助手实际检索到的知识就改本文件。
///
/// 错误码（`STORAGE_UNAVAILABLE` / `READ_FAILED` / `BAD_FILE` / `TOO_MANY_FILES` /
/// `ACK_TIMEOUT`）来自 ESP32 固件同步流程返回的状态码（`flash.ino` 的 `syncError`）。
/// **固件升级后必须复核这些片段**，别让语料停在旧固件的行为上。
///
/// 收录原则（安全边界，改动前先读 `knowledge/README.md`）：
/// - 只放「这个设备和这个 App 自己才知道、通用模型答不了」的权威事实：
///   设备边界、错误码、时间与同步、维护、隐私、术语，以及 **App 功能**
///   （怎么导入/导出、清空对话、搜索、朗读、大字、切换在线等）；
/// - **不放** 药品说明书、剂量表、用药指导、疾病说明 —— 那些会诱导医疗建议，
///   也是最危险的一类。通用健康问答由模型自己的知识 + 来源标记处理，不走这里。
///
/// 检索是设备端关键词匹配，不引入 embedding / 向量模型：语料只有二十几篇，
/// 关键词匹配已经够用，且能保持「全离线、零新依赖、文本不出手机」。
class KnowledgeChunk {
  const KnowledgeChunk({
    required this.id,
    required this.title,
    required this.body,
    required this.keywords,
  });

  /// 稳定 id，测试和日志用它指代某一篇，不要随意改。
  final String id;

  /// 一句话标题，尽量写成用户会问的问题。
  final String title;

  /// 自包含的一段权威解释，检索命中后整段作为「参考资料」喂给模型。
  final String body;

  /// 命中词：问题里出现任一词就倾向于命中这一篇。
  final List<String> keywords;

  /// 拼成给模型看的「参考资料」一行。
  String toReference() => '$title：$body';
}

/// 全量语料。顺序无关，检索按得分排序。
const List<KnowledgeChunk> assistantKnowledge = [
  KnowledgeChunk(
    id: 'boundary.dose',
    title: '设备能测出我吃了多少药吗',
    body: '设备只记录用药动作次数，不测量剂量，也不能确认药是否真的被服用。'
        '它不能告诉你吃了多少药。',
    keywords: [
      '测出',
      '吃多少',
      '多少药',
      '剂量',
      '药量',
      '吃几片',
      '用量',
      '一次吃多少',
    ],
  ),
  KnowledgeChunk(
    id: 'boundary.adherence',
    title: '记录能证明我吃药了吗',
    body: '动作次数只代表装置被使用过，不证明实际服药；没有记录也不等于漏服。'
        '设备数据只有近 7 天逐日统计，更早的规律无法判断。',
    keywords: ['服药', '吃药', '规律', '证明', '上个月', '漏服', '补服', '忘吃'],
  ),
  KnowledgeChunk(
    id: 'sync.storage_unavailable',
    title: '同步提示 STORAGE_UNAVAILABLE',
    body: '设备文件系统不可用（尚未初始化或挂载失败）。已经保存的记录不会因此被删除。'
        '由硬件组确认板上无须保留数据后初始化文件系统，'
        '不要在 App 里尝试修复或格式化设备。',
    keywords: [
      'STORAGE_UNAVAILABLE',
      '存储不可用',
      '文件系统',
      '存储',
      '格式化',
    ],
  ),
  KnowledgeChunk(
    id: 'sync.read_failed',
    title: '同步提示 READ_FAILED',
    body: '读取某条记录的文件失败。该文件被保留，不会被当作已同步删除。'
        '重新同步通常可以重试；若持续失败，交给硬件组检查存储。',
    keywords: ['READ_FAILED', '读取失败', '读不出来'],
  ),
  KnowledgeChunk(
    id: 'sync.bad_file',
    title: '同步提示 BAD_FILE',
    body: '某个文件的大小或内容不符合记录格式（例如文件被截断，'
        '或时间字段不是有效时间戳）。该文件被跳过并保留。',
    keywords: ['BAD_FILE', '坏文件', '文件损坏', '格式不对'],
  ),
  KnowledgeChunk(
    id: 'sync.too_many_files',
    title: '同步提示 TOO_MANY_FILES',
    body: '设备上的记录文件数量超过上限（当前固件 256 个）。'
        '需要先完成同步并提交回收，再继续记录。',
    keywords: ['TOO_MANY_FILES', '文件太多', '文件数量', '满了', '256'],
  ),
  KnowledgeChunk(
    id: 'sync.ack_timeout',
    title: '同步提示 ACK_TIMEOUT',
    body: '设备在等待手机确认（ACK）时超时。记录不会被删除，重新同步可以继续。',
    keywords: ['ACK_TIMEOUT', '确认超时', '等待确认'],
  ),
  KnowledgeChunk(
    id: 'sync.general',
    title: '同步失败怎么办',
    body: '先重试一次同步；若仍失败，检查蓝牙是否连上、设备电量是否充足，'
        '必要时在设备上重新校时后再次同步。具体错误码会显示在提示里，'
        '可按错误码进一步排查；不要在 App 里尝试修复或格式化设备。',
    keywords: [
      '同步失败',
      '同步不了',
      '同步不成功',
      '同步出错',
      '同步错误',
      '连不上',
    ],
  ),
  KnowledgeChunk(
    id: 'time.unknown',
    title: '为什么有条记录显示时间未知',
    body: '记录的时间戳为 0 时视为时间未知，常见原因是设备尚未通过校时。'
        '这类记录不计入按日统计。',
    keywords: ['时间未知', '未知时间', '没时间', '时间戳'],
  ),
  KnowledgeChunk(
    id: 'time.future',
    title: '为什么有条记录的时间是未来',
    body: '记录时间晚于手机当前时间时，会先被排除在按日统计之外。'
        '通常是设备时间不准，建议核对设备的时间设置。',
    keywords: ['未来时间', '时间不对', '时间错', '校时', '时间晚了'],
  ),
  KnowledgeChunk(
    id: 'privacy.upload',
    title: '在线提问会发送什么',
    body: '在线只发送本次问题与当前统计摘要（几个计数和近 7 天逐日次数），'
        '不上传原始记录、设备标识或历史对话。',
    keywords: ['上传', '隐私', '发送什么', '会发送', '联网'],
  ),
  KnowledgeChunk(
    id: 'privacy.local',
    title: '本地模式会联网吗',
    body: '本地规则助手完全在手机本地计算，不联网、不需要账号，也不上传任何记录。',
    keywords: ['本地', '离线', '不联网', '断网'],
  ),
  KnowledgeChunk(
    id: 'maintain.bluetooth',
    title: '蓝牙连不上装置',
    body: '检查设备电量与充电、确认同步按键位置、必要时重新扫描广播窗口；'
        '要在 App 里主动扫描，而不是系统蓝牙配对。',
    keywords: ['蓝牙', '连不上', '连接不上', '扫描', '配对', 'ble'],
  ),
  KnowledgeChunk(
    id: 'term.daily',
    title: '近 7 天逐日次数怎么算',
    body: '近 7 天逐日次数只统计使用动作，未知与未来时间不计入。'
        '总和等于近 7 天总数。',
    keywords: ['逐日', '每天', '口径', '近 7 天', '近7天', '每日'],
  ),
  KnowledgeChunk(
    id: 'term.total',
    title: '总条数是怎么算的',
    body: '总条数是本地保存的全部记录条数，包含时间未知和未来时间的记录；'
        '今日与近 7 天只统计使用动作。',
    keywords: ['总条数', '一共', '多少条', '总量', '全部记录'],
  ),
  KnowledgeChunk(
    id: 'term.invalid',
    title: '疑似无效事件是什么意思',
    body: '疑似无效事件是设备上报为 event_type=2 的记录，通常表示该次动作可能无效；'
        '可在历史记录里查看原始信息。',
    keywords: ['疑似无效', '无效事件', '无效记录', '异常记录'],
  ),
  KnowledgeChunk(
    id: 'time.last_sync',
    title: '最后一次同步时间是什么意思',
    body: '最后一次同步时间只反映本机数据的新旧，不影响记录本身。'
        '距上次同步超过 3 天时，统计可能不含最新记录。',
    keywords: ['同步时间', '最后同步', 'last_sync', '多久没同步'],
  ),
  KnowledgeChunk(
    id: 'history.toggle',
    title: '「带上本轮对话」会发送什么',
    body: '默认不发送历史对话。开启后，只有使用「我自己的模型」时，'
        '才会把本轮更早的问答一起发给模型，帮助理解追问；'
        '仍不发送原始记录、设备标识，也不会把历史发给团队服务器。',
    keywords: ['带上本轮', '多轮', '历史对话', '上下文', '追问'],
  ),
  KnowledgeChunk(
    id: 'app.data_source',
    title: '设备记录从哪里来',
    body:
        'App 使用设备同步后保存在手机中的记录。概览、历史、CSV 和助手统计都读取设备事件。'
        '请在概览页打开设备连接页进行蓝牙连接和同步；连接页单独展示收到的原始时间文本。',
    keywords: ['数据来源', '记录来源', '数据从哪', '导入记录', '接收数据'],
  ),
  KnowledgeChunk(
    id: 'app.export',
    title: '怎么把记录导出来',
    body: '在历史记录页可以把当前筛选结果导出成 CSV 文件；'
        '导出的是已保存的正式记录，不含原型时间文本，也不含任何凭据。',
    keywords: ['导出', 'CSV', 'csv', '表格', '分享', 'Excel', 'excel'],
  ),
  KnowledgeChunk(
    id: 'app.clear',
    title: '清空对话会删除用药记录吗',
    body: '助手页右上角「更多」→「清空对话」只删除本机保存的聊天记录（会先确认一次），'
        '不影响用药记录本身。',
    keywords: ['清空对话', '清空', '删对话', '删除对话', '删聊天', '删除聊天', '聊天记录'],
  ),
  KnowledgeChunk(
    id: 'app.search',
    title: '怎么搜索历史对话',
    body: '点助手页右上角的放大镜图标，按关键词筛选历史对话；'
        '搜索只在本地进行，不发任何网络请求。',
    keywords: ['搜索', '查找对话', '找对话', '搜对话', '筛选'],
  ),
  KnowledgeChunk(
    id: 'app.tts',
    title: '回答能朗读吗',
    body: '每条助手回答右下角有「朗读」按钮，用手机的 Android 系统语音朗读；'
        '能否离线取决于手机安装的语音引擎和中文语音包；'
        '朗读时那个按钮会变成「停止」，再点一次就停，没读到的部分会显示成灰色；'
        '「更多」→「朗读设置」可开自动朗读、调语速和音调。',
    keywords: ['朗读', '读出来', '读回答', '语音', '语速', '音调'],
  ),
  KnowledgeChunk(
    id: 'app.large_text',
    title: '字太小看不清怎么办',
    body: '助手页「更多」→「大字模式」把整页文字放大一档，方便阅读。',
    keywords: ['大字', '字号', '字体', '字太小', '看不清'],
  ),
  KnowledgeChunk(
    id: 'app.online',
    title: '怎么启用在线助手',
    body: '在助手页顶部点「在线」即可联网问答；第一次会引导添加自己的模型服务'
        '（地址 + 你自己的 API Key + 模型名）。Key 加密保存在手机、调用时直接发给所选模型服务，'
        '不经过团队服务器；没配置过也可以先用「本地」。',
    keywords: ['在线', '联网', '加 api', '添加 api', '接入', '自己的模型', '模型服务', 'api key'],
  ),
];

/// 匹配前先归一化：小写化，去掉空白与常见中英文标点。
///
/// 这样「近7天」「近 7 天」都能命中「近 7 天」，「BLE 连不上」也能命中
/// 小写的 `ble`，错误码的大小写与下划线也不再敏感。
String _canonical(String text) {
  final lower = text.toLowerCase();
  final buffer = StringBuffer();
  for (final rune in lower.runes) {
    final ch = String.fromCharCode(rune);
    if (_ignoredInMatch.contains(ch)) continue;
    buffer.write(ch);
  }
  return buffer.toString();
}

const Set<String> _ignoredInMatch = {
  ' ',
  '\t',
  '\r',
  '\n',
  '，',
  '。',
  '？',
  '！',
  '：',
  '；',
  '、',
  '（',
  '）',
  '(',
  ')',
  '「',
  '」',
  '『',
  '』',
  '·',
  '—',
  '–',
  '…',
  '“',
  '”',
  '‘',
  '’',
  ',',
  '.',
  '?',
  '!',
  ':',
  ';',
  '\'',
  '"',
  '-',
  '_',
  '/',
  '\\',
};

/// 同义组：组内任意一种说法出现在问题里，都算命中这一组。
///
/// 只放不会串话题的等价说法。「同步 / 连接」这种容易误伤的**不放**——
/// 用户说「连接失败」不等于「同步失败」，硬并在一起会把错误码问答污染掉。
const List<List<String>> _synonymGroups = [
  ['蓝牙', 'ble'],
  ['吃药', '服药', '用药', '服用'],
  ['校时', '对时', '校准', '调时间'],
  ['设备', '装置'],
  ['逐日', '每天', '每日'],
];

/// 按关键词做轻量检索，返回按相关度降序的前 [topK] 篇。
///
/// 中文没有天然分词，这里在归一化之后做三种匹配：
/// - 同义组命中（「服用」也能命中关键词是「吃药」的篇章）得 3 分；
/// - 字面子串命中得 3 分；
/// - 够长的关键词做字符二元组重叠的「近形」匹配，容忍一两个错别字，得 1 分；
/// 命中标题再得 2 分。问题为空或一篇都没命中时返回空列表。
List<KnowledgeChunk> retrieveKnowledge(String question, {int topK = 3}) {
  final q = _canonical(question);
  if (q.isEmpty) return const [];
  final scored = <({int score, KnowledgeChunk chunk})>[];
  for (final chunk in assistantKnowledge) {
    var score = 0;
    for (final keyword in chunk.keywords) {
      score += _keywordScore(q, keyword);
    }
    if (q.contains(_canonical(chunk.title))) score += 2;
    if (score > 0) scored.add((score: score, chunk: chunk));
  }
  scored.sort((a, b) => b.score.compareTo(a.score));
  return [for (final entry in scored.take(topK)) entry.chunk];
}

/// 单个关键词对问题的得分。
int _keywordScore(String q, String keyword) {
  final k = _canonical(keyword);
  if (k.isEmpty) return 0;
  // 1) 同义组：关键词属于某组，组内任一说法出现在问题里都算命中。
  for (final group in _synonymGroups) {
    if (group.contains(k)) {
      if (group.any((w) => q.contains(w))) return 3;
      break;
    }
  }
  // 2) 字面子串。
  if (q.contains(k)) return 3;
  // 3) 近形（错别字）模糊：够长的关键词按字符二元组重叠给弱分。
  if (k.length >= 4 && _bigramOverlap(q, k) >= 0.6) return 1;
  return 0;
}

/// 关键词的字符二元组有多少比例出现在问题里。
///
/// 用于容忍单个错别字/同音字：4 个字的关键词有 3 个二元组，错一个字还剩 2 个，
/// 达到 0.6 的阈值。长度太短的关键词不进这一步，避免把常见词误命中。
double _bigramOverlap(String q, String k) {
  final kBigrams = _bigrams(k);
  if (kBigrams.isEmpty) return 0;
  final qBigrams = _bigrams(q);
  final overlap = kBigrams.where(qBigrams.contains).length;
  return overlap / kBigrams.length;
}

Set<String> _bigrams(String text) {
  final runes = text.runes.toList();
  final result = <String>{};
  for (var i = 0; i + 1 < runes.length; i++) {
    result.add(
      '${String.fromCharCode(runes[i])}${String.fromCharCode(runes[i + 1])}',
    );
  }
  return result;
}
