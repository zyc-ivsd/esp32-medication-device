import '../assistant_provider.dart';
import '../models/assistant_context.dart';
import '../rules/observation_rules.dart';

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
      '这个问题不该由设备记录来回答。\n'
      '设备记录只能说明装置被使用过，不能确认是否服药，所以「有没有漏服」'
      '这类判断需要你或医生按实际情况来确认。\n'
      '我也不做诊断、不推荐剂量、不调整用药方案，这些请以医生或药师的意见为准。\n'
      '如果你问的是记录本身，可以直接问：今天用了几次、数据是不是最新的、空白那几天怎么看。';

  /// 「连不上 / 同步失败」这类维护问题，放在数据分支之前回答：
  /// 用户要的是排查步骤，不是一句「最后一次同步是……」。同步失败不会删记录，
  /// 所以结尾补一句安心，避免让人以为设备上的数据没了。
  static const _connectionAnswer =
      '先检查设备电量与充电，确认设备在广播窗口内、蓝牙没被别的应用占用，'
      '再在 App 里重新扫描（不是系统蓝牙配对）。\n'
      '若提示了具体错误码，切到「在线」问那个错误码是什么意思；'
      '同步失败不会删除设备上的记录。';

  @override
  Future<String> reply({
    required String question,
    required AssistantContext context,
    List<String> references = const [],
  }) async {
    // 本地规则不检索知识库，references 忽略。
    await Future<void>.delayed(const Duration(milliseconds: 250));

    final normalizedQuestion = question.trim();
    if (normalizedQuestion.isEmpty) {
      return '请先输入问题。';
    }

    final sourceText = context.isDemo ? '演示数据' : '设备记录';
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
      return '根据当前$sourceText，今天使用 ${context.todayCount} 次，'
          '近 7 天共 ${context.last7DaysCount} 次。这里只统计设备记录的使用动作，不能据此确认实际服药。'
          '$attention';
    }

    if (normalizedQuestion.contains('异常') ||
        normalizedQuestion.contains('无效')) {
      final base = context.invalidEventCount == 0
          ? '$sourceText近 7 天没有疑似无效记录。这个结果仅基于已有记录。'
          : '$sourceText近 7 天有 ${context.invalidEventCount} 条疑似无效记录，可在历史中查看原始信息。';
      return '$base$attention';
    }

    if (normalizedQuestion.contains('最近') ||
        normalizedQuestion.contains('一周') ||
        normalizedQuestion.contains('规律') ||
        normalizedQuestion.contains('波动') ||
        normalizedQuestion.contains('趋势')) {
      return '$sourceText近 7 天逐日使用动作（最早一天在前，今天在最后）：'
          '${context.dailyCounts.join('、')}，共 ${context.last7DaysCount} 次。'
          '时间未知或晚于当前时间的记录不计入按日统计。$attention';
    }

    if (_matchesAny(normalizedQuestion, const {'最新', '同步', '多久'})) {
      // `never_synced` 只在设备数据下产生；演示数据没有设备，自己说清楚就好。
      final base =
          _firstNote(observations, 'never_synced') ??
          (context.lastSyncAt == null
              ? '演示数据没有设备同步时间。'
              : '最后一次同步是 ${context.lastSyncAt!.toLocal()}，'
                    '之后的新记录可能还没同步到手机。');
      return '$base${_notesFor(observations, const {'stale_sync', 'future_sync'})}'
          '同步时间只反映本机数据的新旧，不影响记录本身。';
    }

    if (_matchesAny(normalizedQuestion, const {'时间', '校时', '日期'})) {
      // 演示数据没有设备可维护，所以不给校时建议（同规则层的取舍）。
      final advice = context.isDemo ? '' : '如果设备时间不对，可以在设备上校时后重新同步。';
      return '$sourceText里有 ${context.unknownTimeCount} 条时间未知、'
          '${context.futureTimeCount} 条时间晚于当前时间的记录，这些不计入按日统计。'
          '${_notesFor(observations, const {'unknown_time', 'future_time'})}'
          '$advice';
    }

    if (_matchesAny(normalizedQuestion, const {'总共', '一共', '多少条', '总量', '全部'})) {
      return '$sourceText共 ${context.totalCount} 条：今天 ${context.todayCount} 次，'
          '近 7 天 ${context.last7DaysCount} 次。'
          '其中 ${context.unknownTimeCount} 条时间未知、'
          '${context.futureTimeCount} 条时间晚于当前时间，这些不计入按日统计。$attention';
    }

    if (_matchesAny(normalizedQuestion, const {'空白', '空着', '没记录', '漏记'})) {
      // 一条记录都没有时，逐日全是 0，不能说「这 7 天都有记录」。
      if (context.totalCount == 0) {
        return '目前没有记录，近 7 天也没有设备动作。'
            '没有记录只说明当天没有设备动作，不能确认是否服药。';
      }
      final blanks = _notesFor(
        observations,
        const {'blank_days', 'uneven_days', 'recent_gap'},
      );
      return '$sourceText近 7 天逐日为 ${context.dailyCounts.join('、')}。'
          '${blanks.isEmpty ? '这 7 天都有记录。' : blanks}'
          '没有记录只说明当天没有设备动作，不能确认是否服药。';
    }

    // 「大字模式」这条必须排在通用「怎么办 / 建议」之前：用户会问
    // 「字太小了怎么办」，而「怎么办」会被下面那个通用分支抢先命中，
    // 答案就变成了统计观察（实测踩过）。
    if (_matchesAny(normalizedQuestion, const {'大字', '字号', '字体', '字太小', '看不清'})) {
      return '「更多」→「大字模式」把整页文字放大一档，方便阅读。';
    }

    if (normalizedQuestion.contains('建议') ||
        normalizedQuestion.contains('注意') ||
        normalizedQuestion.contains('怎么办')) {
      return '下面是按固定规则得出的观察，只陈述事实，不是医疗建议：\n'
          '${_observationList(observations)}'
          '设备动作次数只代表装置被使用，不能确认实际服药。';
    }

    if (_matchesAny(normalizedQuestion, const {'导入'})) {
      return '概览页有「导入演示数据」入口：没有硬件时生成一段示例记录用于体验功能；'
          '连接硬件同步后会用正式记录替换。演示数据单独存放，清除演示数据不影响设备数据。';
    }

    if (_matchesAny(normalizedQuestion, const {'演示', '示例', '假数据', '测试数据', '模拟数据'})) {
      return context.isDemo
          ? '当前看到的是演示数据：导入时生成的一段示例记录，用于没有硬件时体验功能，'
                '不代表真实用药；连接硬件同步后会换成正式记录。'
          : '当前数据来自设备同步，不是演示数据。';
    }

    if (_matchesAny(normalizedQuestion, const {'导出', 'CSV', 'csv', 'Excel', 'excel', '表格', '分享'})) {
      return '可以在历史记录页把当前筛选结果导出成 CSV 文件；'
          '导出的是已保存的正式记录，不含原型时间文本，也不含任何凭据。';
    }

    // —— App 功能求助：本地就能答，不联网。放在通用「帮助」之前，
    //    否则「怎么清空对话」这类具体问法会被兜底答案吞掉。 ——

    if (_matchesAny(normalizedQuestion, const {'清空', '删对话', '删除对话', '删聊天', '删除聊天'})) {
      return '在助手页右上角「更多」→「清空对话」可删除本机保存的聊天记录（会先确认一次）。'
          '这只删对话，不影响用药记录本身。';
    }

    if (_matchesAny(normalizedQuestion, const {'搜索', '查找对话', '找对话', '搜对话'})) {
      return '点助手页右上角的放大镜图标，按关键词筛选历史对话；搜索只在本地进行，不发任何网络请求。';
    }

    if (_matchesAny(normalizedQuestion, const {'朗读', '读出来', '读回答', '语音', '语速', '音调'})) {
      return '每条助手回答右下角有「朗读」按钮，用手机的 Android 系统语音朗读；'
          '能否离线取决于手机安装的语音引擎和中文语音包；'
          '朗读时那个按钮会变成「停止」，再点一次就停，没读到的部分会显示成灰色；'
          '「更多」→「朗读设置」可开自动朗读、调语速和音调。';
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
      return '在助手页顶部点「在线」即可联网问答；第一次会引导添加自己的模型服务'
          '（地址 + 你自己的 API Key + 模型名）。Key 加密保存在手机、调用时直接发给所选模型服务，'
          '不经过团队服务器；没配置过也可以先用「本地」。';
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
      return '我可以按固定规则解释你的记录：今天/近 7 天的次数、逐日规律、总条数、'
          '同步时间、时间未知与未来时间、疑似无效事件，以及需要留意的事项。\n'
          '也能答 App 怎么用：导入演示数据、连接设备、导出 CSV、清空对话、搜索、'
          '朗读、大字模式、切换在线等。\n'
          '我只讲记录和 App 用法，不做医疗判断、不给用药建议，也不把设备动作当成服药证明。\n'
          '想问通用健康知识，切到上面的「在线」；本地模式不联网、不需要账号。';
    }

    // 兜底不再只丢一句摘要：先说清本地模式能答什么、答不了什么，
    // 免得用户问什么都只看到一串统计数字，以为助手在复读。
    return '本地模式只按固定规则解释你的记录，不联网、也没有通用知识。\n'
        '我能直接回答这些：今天用了几次、数据是不是最新的、设备时间、总条数、'
        '异常记录、逐日空档、需要留意的事。\n'
        '也能答 App 怎么用：导入演示数据、连接设备、导出 CSV、清空对话、搜索、'
        '朗读、大字、切换在线。\n'
        '想问健康常识（例如某种疾病的科普），切到上面的「在线」就能问。\n'
        '当前记录摘要：${context.toPromptSummary()}';
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
    return notes.isEmpty ? '' : '\n需要留意：${notes.join(' ')}';
  }

  String _observationList(List<AssistantObservation> observations) {
    if (observations.isEmpty) {
      return '· 当前没有需要提醒的项目。\n';
    }
    return '${observations.map((item) => '· ${item.text}').join('\n')}\n';
  }
}
