import '../assistant_provider.dart';
import '../models/assistant_context.dart';
import '../rules/observation_rules.dart';
import '../question_routing.dart';

/// App 侧的本地规则助手：不依赖网络和 API Key 的确定性回答器。
///
/// 它按固定规则解释统计摘要，并给出设备侧的维护提醒；
/// 不做诊断、不给剂量建议，也不把“没有设备记录”表述为“漏服”。
class MockAssistantProvider implements AssistantProvider {
  MockAssistantProvider({this.now});

  /// 注入固定时间便于测试；为空时每次提问读取当前本地时间。
  final DateTime? now;

  /// 直接问「该不该吃药」的问法。
  ///
  /// 这些必须在**所有数据分支之前**拦下：问「我今天漏服了吗」如果先命中「今天」
  /// 分支去报次数，就等于用设备动作回答了服药问题——次数不证明服药，
  /// 那样回答会让用户把“有记录”读成“吃过了”。
  static const _medicalKeywords = {
    '漏服',
    '漏吃',
    '忘吃',
    '忘记吃',
    '该不该',
    '要不要吃',
    '补服',
    '补吃',
    '加量',
    '减量',
    '停药',
    '换药',
    '副作用',
    '诊断',
  };

  /// 连接与同步故障的触发词。要放在「最新/同步/多久」之前：
  /// 「同步失败」含「同步」，若先撞到「同步」分支就会去报最后同步时间，
  /// 用户要的却是排查步骤。
  static const _connectionKeywords = {
    '连不上',
    '连接不上',
    '连不上蓝牙',
    '蓝牙连不上',
    '同步失败',
    '同步不了',
    '同步不上',
    '同步出错',
    '扫描不到',
    '配对',
    '蓝牙',
    'BLE',
  };

  static const _medicalBoundaryAnswer =
      'Device records cannot establish this.\n'
      'A logged use does not verify ingestion, so questions about missed doses '
      'need confirmation from you or a clinician.\n'
      'For diagnosis, dose changes or a treatment plan, consult a clinician or pharmacist.\n'
      'I can explain the saved records: uses today, sync status or days without entries.';

  /// 「连不上 / 同步失败」这类维护问题，放在数据分支之前回答：
  /// 用户要的是排查步骤，不是一句「最后一次同步是……」。同步失败不会删记录，
  /// 所以结尾补一句安心，避免让人以为设备上的数据没了。
  static const _connectionAnswer =
      'Check the battery, wake the device with its button and make sure Bluetooth is available. '
      'Then scan again inside the app.\n'
      'If you see an error code, ask Online what it means. '
      'A failed sync does not delete device files.';

  @override
  Future<String> reply({
    required String question,
    required AssistantContext context,
    List<String> references = const [],
  }) async {
    // 本地规则不检索知识库，references 忽略。
    await Future<void>.delayed(const Duration(milliseconds: 250));

    final normalizedQuestion = normalizeAssistantQuestion(question);
    if (normalizedQuestion.isEmpty) {
      return 'Enter a question first.';
    }

    const sourceText = 'device records';
    final observations = evaluateObservations(
      context,
      now: now ?? DateTime.now(),
    );
    final attention = _attentionNotes(observations);

    if (_matchesAny(normalizedQuestion, _medicalKeywords)) {
      return _medicalBoundaryAnswer;
    }

    if (_matchesAny(normalizedQuestion, _connectionKeywords)) {
      return _connectionAnswer;
    }

    if (normalizedQuestion.contains('今天') ||
        normalizedQuestion.contains('次数')) {
      return 'Your $sourceText show ${context.todayCount} uses today and '
          '${context.last7DaysCount} uses in the last 7 days. Logged uses do not verify ingestion.'
          '$attention';
    }

    if (normalizedQuestion.contains('异常') ||
        normalizedQuestion.contains('无效')) {
      final base = context.invalidEventCount == 0
          ? 'Your $sourceText show no suspected invalid uses in the last 7 days. This describes only saved records.'
          : 'Your $sourceText show ${context.invalidEventCount} suspected invalid uses in the last 7 days. Inspect their details in History.';
      return '$base$attention';
    }

    if (normalizedQuestion.contains('最近') ||
        normalizedQuestion.contains('一周') ||
        normalizedQuestion.contains('规律') ||
        normalizedQuestion.contains('波动') ||
        normalizedQuestion.contains('趋势')) {
      return 'Daily uses in your $sourceText (oldest to today): '
          '${context.dailyCounts.join(', ')}, a total of ${context.last7DaysCount} uses. '
          'Unknown and future times are excluded from daily counts.$attention';
    }

    if (_matchesAny(normalizedQuestion, const {'最新', '同步', '多久'})) {
      final base =
          _firstNote(observations, 'never_synced') ??
          (context.lastSyncAt == null
              ? 'No completed sync time is recorded, so data freshness is unknown.'
              : 'Last completed sync: ${context.lastSyncAt!.toLocal()}. '
                    'Newer device records may not have reached this phone.');
      return '$base${_notesFor(observations, const {'stale_sync', 'future_sync'})}'
          'Sync time describes freshness, not ingestion.';
    }

    if (_matchesAny(normalizedQuestion, const {'时间', '校时', '日期'})) {
      const advice =
          'Calibrate the device clock in Device connection and sync again. Older files are not rewritten.';
      return 'Your $sourceText include ${context.unknownTimeCount} unknown-time and '
          '${context.futureTimeCount} future-time entries, excluded from daily counts.'
          '${_notesFor(observations, const {'unknown_time', 'future_time'})}'
          '$advice';
    }

    if (_matchesAny(normalizedQuestion, const {
      '总共',
      '一共',
      '多少条',
      '总量',
      '全部',
    })) {
      return 'Your $sourceText contain ${context.totalCount} records: ${context.todayCount} uses today and '
          '${context.last7DaysCount} uses in the last 7 days. '
          '${context.unknownTimeCount} records have unknown times and '
          '${context.futureTimeCount} have future times; both are excluded from daily counts.$attention';
    }

    if (_matchesAny(normalizedQuestion, const {'空白', '空着', '没记录', '漏记'})) {
      // 一条记录都没有时，逐日全是 0，不能说「这 7 天都有记录」。
      if (context.totalCount == 0) {
        return 'There are no saved records or device uses in the last 7 days. '
            'A missing record does not establish a missed dose.';
      }
      final blanks = _notesFor(observations, const {
        'blank_days',
        'uneven_days',
        'recent_gap',
      });
      return 'Daily uses in your $sourceText: ${context.dailyCounts.join(', ')}. '
          '${blanks.isEmpty ? 'Each of the last 7 days has records. ' : blanks}'
          'A missing record does not establish a missed dose.';
    }

    // 「大字模式」这条必须排在通用「怎么办 / 建议」之前：用户会问
    // 「字太小了怎么办」，而「怎么办」会被下面那个通用分支抢先命中，
    // 答案就变成了统计观察（实测踩过）。
    if (_matchesAny(normalizedQuestion, const {
      '大字',
      '字号',
      '字体',
      '字太小',
      '看不清',
    })) {
      return 'Open More → Larger text on the assistant page.';
    }

    if (normalizedQuestion.contains('建议') ||
        normalizedQuestion.contains('注意') ||
        normalizedQuestion.contains('怎么办')) {
      return 'These observations use fixed rules and describe your saved records:\n'
          '${_observationList(observations)}'
          'Logged uses do not verify ingestion.';
    }

    if (_matchesAny(normalizedQuestion, const {'数据来源', '记录来源', '数据从哪', '导入'})) {
      return 'Open Device connection from Overview to connect and sync. '
          'Each unique device timestamp becomes one use entry for Overview, History, CSV and assistant statistics.';
    }

    if (_matchesAny(normalizedQuestion, const {
      '导出',
      'CSV',
      'csv',
      'Excel',
      'excel',
      '表格',
      '分享',
    })) {
      return 'Export the currently filtered records as CSV from History. '
          'The file includes device timestamp entries and their original text. Unknown measurements remain blank; no credentials are included.';
    }

    // —— App 功能求助：本地就能答，不联网。放在通用「帮助」之前，
    //    否则「怎么清空对话」这类具体问法会被兜底答案吞掉。 ——

    if (_matchesAny(normalizedQuestion, const {
      '清空',
      '删对话',
      '删除对话',
      '删聊天',
      '删除聊天',
    })) {
      return 'Open More → Clear chat on the assistant page and confirm. '
          'Only chat messages are deleted; medication records are kept.';
    }

    if (_matchesAny(normalizedQuestion, const {'搜索', '查找对话', '找对话', '搜对话'})) {
      return 'Tap the search icon on the assistant page to filter saved messages. Search runs on this phone.';
    }

    if (_matchesAny(normalizedQuestion, const {
      '朗读',
      '读出来',
      '读回答',
      '语音',
      '语速',
      '音调',
    })) {
      return 'Tap Read aloud beside an answer to use Android text-to-speech. '
          'Offline playback depends on an installed English voice and its engine. '
          'Tap Stop to end playback. '
          'More → Read-aloud settings controls automatic playback, speed and pitch.';
    }

    if (_matchesAny(normalizedQuestion, const {
      '加 api',
      '添加 api',
      '接入',
      '自己的模型',
      '模型服务',
      '怎么联网',
      '怎么用在线',
      '在线设置',
      'api key',
    })) {
      return 'Tap Online and add your own model service '
          '(URL, API key and model name). The key is encrypted on your phone and sent directly to that service. '
          'Local works without a model configuration or network.';
    }

    if (_matchesAny(normalizedQuestion, const {
      '帮助',
      '怎么用',
      '能做什么',
      '能问什么',
      '能答什么',
      '功能',
      '你是谁',
      '是什么',
      '用途',
    })) {
      return 'I use fixed local rules to explain today and weekly counts, daily patterns, totals, '
          'sync status, unknown and future times, invalid events and items needing attention.\n'
          'I can also explain connecting, CSV export, clearing or searching chat, '
          'read aloud, larger text and Online mode.\n'
          'A logged use does not verify ingestion; I do not diagnose or advise on medication doses.\n'
          'Switch to Online for general health information. Local needs no network or account.';
    }

    // 兜底不再只丢一句摘要：先说清本地模式能答什么、答不了什么，
    // 免得用户问什么都只看到一串统计数字，以为助手在复读。
    return 'Local uses fixed rules to explain saved records. It has no general-purpose language model.\n'
        'Ask about uses today, sync status, device time, totals, '
        'invalid events, days without records or things needing attention.\n'
        'I can also explain connecting, CSV export, clearing or searching chat, '
        'read aloud, larger text and Online mode.\n'
        'Switch to Online for general questions.\n'
        'Current summary: ${context.toPromptSummary()}';
  }

  bool _matchesAny(String question, Set<String> keywords) =>
      keywords.any(question.contains);

  /// 取指定代码的第一条观察文本，没有就返回 null。
  String? _firstNote(List<AssistantObservation> observations, String code) {
    for (final item in observations) {
      if (item.code == code) return item.text;
    }
    return null;
  }

  /// 把指定代码的观察文本串成一段（每条之后换行），没有就返回空串。
  ///
  /// 复用规则层的原话，而不是在这里另写一套：概览页的「需要留意」卡片和助手
  /// 说的必须是同一句，否则两处措辞会慢慢漂开。
  String _notesFor(List<AssistantObservation> observations, Set<String> codes) {
    final notes = observations
        .where((item) => codes.contains(item.code))
        .map((item) => item.text)
        .toList();
    return notes.isEmpty ? '' : '${notes.join(' ')}\n';
  }

  /// 只把需要用户采取动作的观察追加到具体回答之后。
  String _attentionNotes(List<AssistantObservation> observations) {
    final notes = observations
        .where((item) => item.level == ObservationLevel.attention)
        .map((item) => item.text)
        .toList();
    return notes.isEmpty ? '' : '\nNeeds attention: ${notes.join(' ')}';
  }

  String _observationList(List<AssistantObservation> observations) {
    if (observations.isEmpty) {
      return '· No items need attention right now.\n';
    }
    return '${observations.map((item) => '· ${item.text}').join('\n')}\n';
  }
}
