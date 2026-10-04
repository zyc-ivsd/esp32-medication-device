import 'question_routing.dart';

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
  String toReference() => '$title: $body';
}

/// 全量语料。顺序无关，检索按得分排序。
const List<KnowledgeChunk> assistantKnowledge = [
  KnowledgeChunk(
    id: 'boundary.dose',
    title: 'Can the device measure my medication dose?',
    body:
        'The device logs use times and counts; it does not measure dose or verify ingestion. '
        'It cannot determine how much medication you took.',
    keywords: ['测出', '吃多少', '多少药', '剂量', '药量', '吃几片', '用量', '一次吃多少'],
  ),
  KnowledgeChunk(
    id: 'boundary.adherence',
    title: 'Do records prove that I took medication?',
    body:
        'A recorded use means the device was triggered; it does not verify ingestion. A missing record does not establish a missed dose. '
        'The assistant receives daily totals for the last 7 days, not a complete long-term timeline.',
    keywords: ['服药', '吃药', '规律', '证明', '上个月', '漏服', '补服', '忘吃'],
  ),
  KnowledgeChunk(
    id: 'sync.storage_unavailable',
    title: 'Sync reports STORAGE_UNAVAILABLE',
    body:
        'The device filesystem is unavailable. Saved records are retained. '
        'Ask the hardware team to inspect the filesystem after securing any data. '
        'The app cannot repair or format the device.',
    keywords: ['STORAGE_UNAVAILABLE', '存储不可用', '文件系统', '存储', '格式化'],
  ),
  KnowledgeChunk(
    id: 'sync.read_failed',
    title: 'Sync reports READ_FAILED',
    body:
        'The device could not read a record file. The file is retained. '
        'Try Re-sync. If it continues failing, ask the hardware team to inspect storage.',
    keywords: ['READ_FAILED', '读取失败', '读不出来'],
  ),
  KnowledgeChunk(
    id: 'sync.bad_file',
    title: 'Sync reports BAD_FILE',
    body:
        'A file has an invalid size or format, such as a truncated file '
        'or malformed timestamp. It is retained for inspection.',
    keywords: ['BAD_FILE', '坏文件', '文件损坏', '格式不对'],
  ),
  KnowledgeChunk(
    id: 'sync.too_many_files',
    title: 'Sync reports TOO_MANY_FILES',
    body:
        'The device has more than the current limit of 256 record files. '
        'The current firmware retains files even after COMMIT; ask the hardware team to add paging or safe retention after backing up the records.',
    keywords: ['TOO_MANY_FILES', '文件太多', '文件数量', '满了', '256'],
  ),
  KnowledgeChunk(
    id: 'sync.ack_timeout',
    title: 'Sync reports ACK_TIMEOUT',
    body:
        'The phone did not acknowledge a frame before the retry limit. Files are retained; try Re-sync.',
    keywords: ['ACK_TIMEOUT', '确认超时', '等待确认'],
  ),
  KnowledgeChunk(
    id: 'sync.general',
    title: 'What should I do when sync fails?',
    body:
        'Try Re-sync, check Bluetooth and battery, '
        'and calibrate the device clock if needed. The error code can help identify the cause. '
        'Do not format device storage from the app.',
    keywords: ['同步失败', '同步不了', '同步不成功', '同步出错', '同步错误', '连不上'],
  ),
  KnowledgeChunk(
    id: 'time.unknown',
    title: 'Why does a record have an unknown time?',
    body:
        'A missing timestamp, malformed value or the firmware clock placeholder is treated as unknown. '
        'It is kept for review and excluded from daily use counts.',
    keywords: ['时间未知', '未知时间', '没时间', '时间戳'],
  ),
  KnowledgeChunk(
    id: 'time.future',
    title: 'Why is a record dated in the future?',
    body:
        'Records later than the current phone time are excluded from daily counts. '
        'Check the device clock. Calibration does not rewrite older files.',
    keywords: ['未来时间', '时间不对', '时间错', '校时', '时间晚了'],
  ),
  KnowledgeChunk(
    id: 'privacy.upload',
    title: 'What does an online question send?',
    body:
        'Online sends your current question, a record summary and matching app-use references. '
        'Raw records and device identifiers are excluded. Relevant session history is sent only if you enable that option for your own model.',
    keywords: ['上传', '隐私', '发送什么', '会发送', '联网'],
  ),
  KnowledgeChunk(
    id: 'privacy.local',
    title: 'Does Local mode connect to the internet?',
    body:
        'Local uses fixed rules on this phone. It needs no network or account and uploads no records.',
    keywords: ['本地', '离线', '不联网', '断网'],
  ),
  KnowledgeChunk(
    id: 'maintain.bluetooth',
    title: 'Why can I not connect over Bluetooth?',
    body:
        'Check power, wake the device with its button and scan in the app. '
        'Connect inside the app, rather than pairing in system Bluetooth settings.',
    keywords: ['蓝牙', '连不上', '连接不上', '扫描', '配对', 'ble'],
  ),
  KnowledgeChunk(
    id: 'term.daily',
    title: 'How are daily use counts calculated?',
    body:
        'Each unique device timestamp with a valid time records one use; valid structured use events are also counted. Unknown and future times are excluded. '
        'The seven daily counts add up to the weekly total. Device records are UTC and shown in your phone timezone.',
    keywords: ['逐日', '每天', '口径', '近 7 天', '近7天', '每日'],
  ),
  KnowledgeChunk(
    id: 'term.total',
    title: 'How is the total record count calculated?',
    body:
        'The total includes all saved entries, including records with unknown or future times. '
        'Today and Last 7 days count only use entries with an eligible time.',
    keywords: ['总条数', '一共', '多少条', '总量', '全部记录'],
  ),
  KnowledgeChunk(
    id: 'term.invalid',
    title: 'What is a suspected invalid use?',
    body:
        'Only structured event_type=2 records are marked as suspected invalid uses. Timestamp-only records have no pressure or confidence measurements. '
        'Open History to inspect the original details.',
    keywords: ['疑似无效', '无效事件', '无效记录', '异常记录'],
  ),
  KnowledgeChunk(
    id: 'time.last_sync',
    title: 'What does the last sync time mean?',
    body:
        'It is updated only after the device sends DONE for a fully saved sync. '
        'If the last sync was more than 3 days ago, newer device entries may be missing.',
    keywords: ['同步时间', '最后同步', 'last_sync', '多久没同步'],
  ),
  KnowledgeChunk(
    id: 'history.toggle',
    title: 'What does Include this session send?',
    body:
        'Chat history is excluded by default. If enabled, your own model receives '
        'relevant earlier turns from the current session to understand follow-ups. '
        'Raw records and device identifiers are still excluded; history is not sent to the team gateway.',
    keywords: ['带上本轮', '多轮', '历史对话', '上下文', '追问'],
  ),
  KnowledgeChunk(
    id: 'app.data_source',
    title: 'Where do device records come from?',
    body:
        'The app converts each unique button timestamp into a medication-use entry saved on this phone. Overview, History, CSV and the assistant use the same saved records. '
        'Device connection also retains the original device text for inspection.',
    keywords: ['数据来源', '记录来源', '数据从哪', '导入记录', '接收数据'],
  ),
  KnowledgeChunk(
    id: 'app.export',
    title: 'How do I export records?',
    body:
        'Open History and export the currently filtered records as CSV. '
        'Timestamp entries include the original text and file identity; unavailable measurements and UTC fields are left blank. Credentials are excluded.',
    keywords: ['导出', 'CSV', 'csv', '表格', '分享', 'Excel', 'excel'],
  ),
  KnowledgeChunk(
    id: 'app.clear',
    title: 'Does clearing chat delete medication records?',
    body:
        'More → Clear chat deletes only saved chat messages after confirmation. '
        'Medication records are kept.',
    keywords: ['清空对话', '清空', '删对话', '删除对话', '删聊天', '删除聊天', '聊天记录'],
  ),
  KnowledgeChunk(
    id: 'app.search',
    title: 'How do I search chat history?',
    body:
        'Tap the search icon at the top of the assistant to filter saved chat messages by keyword. '
        'Search runs only on your phone and does not send network requests.',
    keywords: ['搜索', '查找对话', '找对话', '搜对话', '筛选'],
  ),
  KnowledgeChunk(
    id: 'app.tts',
    title: 'Can answers be read aloud?',
    body:
        'Tap Read aloud beside an answer to use Android text-to-speech. '
        'Offline playback depends on an installed English voice and its engine. '
        'Tap Stop to end playback. '
        'More → Read-aloud settings controls automatic playback, speed and pitch.',
    keywords: ['朗读', '读出来', '读回答', '语音', '语速', '音调'],
  ),
  KnowledgeChunk(
    id: 'app.large_text',
    title: 'How do I make the text larger?',
    body: 'On the assistant page, open More → Larger text.',
    keywords: [
      'Tap the search icon on the assistant page to filter saved messages by keyword. ',
      'Search runs locally without a network request.',
      '字体',
      '字太小',
      '看不清',
    ],
  ),
  KnowledgeChunk(
    id: 'app.online',
    title: 'How do I enable the online assistant?',
    body:
        'Tap Online and add your model service '
        '(URL, your own API key and model name). The key is encrypted on this phone and sent directly to your chosen service. '
        'You can use Local without configuring a model.',
    keywords: ['在线', '联网', '加 api', '添加 api', '接入', '自己的模型', '模型服务', 'api key'],
  ),
];

/// 匹配前先归一化：小写化，去掉空白与常见中英文标点。
///
/// 这样「近7天」「近 7 天」都能命中「近 7 天」，「BLE 连不上」也能命中
/// 小写的 `ble`，错误码的大小写与下划线也不再敏感。
String _canonical(String text) {
  final lower = normalizeAssistantQuestion(text);
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
