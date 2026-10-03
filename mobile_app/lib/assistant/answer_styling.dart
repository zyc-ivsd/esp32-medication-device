import 'models/assistant_context.dart';

/// 回答正文里的一种强调样式。页面据此上色/加粗/斜体，这里只存数据、不碰 Flutter。
///
/// - [plain]：正文（黑色）。
/// - [data]：个人数据（来自摘要、且后面紧跟「次 / 条」的次数或条数，蓝色）。
/// - [alert]：需要留意的问题（回验提醒、本地「需要留意」观察，红色）。
/// - [notice]：AI 声明（「这是通用健康知识、不是你的设备记录」，浅色斜体）。
enum AnswerSpanKind { plain, data, alert, notice }

/// 一个带样式的文本片段。
class AnswerSpan {
  const AnswerSpan(this.text, [this.kind = AnswerSpanKind.plain]);

  final String text;
  final AnswerSpanKind kind;
}

/// 开头声明（在线通用知识回答会把这句放在最前面）。
final RegExp _leadNotice = RegExp(r'^（[^（）]*不是你的设备记录[^（）]*）');

/// 结尾的「提醒：…」（在线回答数字回验不通过时追加）。
final RegExp _trailingAlert = RegExp(r'（提醒：[^（）]*）\s*$');

/// 把一条回答拆成带样式的片段。
///
/// **只拆渲染、不动原文**：朗读、搜索、落盘仍用原始字符串，所以这里永远不会
/// 丢失信息，只会决定哪段字是什么颜色。
///
/// 顺序：开头声明（notice）→ 正文与数字（plain/data）→ 需要留意（alert）→
/// 回验提醒（alert）。
List<AnswerSpan> styleAnswer(String text, {Set<int> dataNumbers = const {}}) {
  final spans = <AnswerSpan>[];
  var rest = text;

  final lead = _leadNotice.firstMatch(rest);
  if (lead != null) {
    spans.add(AnswerSpan(lead.group(0)!, AnswerSpanKind.notice));
    rest = rest.substring(lead.end);
  }

  // 回验提醒在最后，先把它的内容摘出来，正文里就不重复扫数字了。
  final trailingAlert = _trailingAlert.firstMatch(rest);
  if (trailingAlert != null) {
    rest = rest.substring(0, trailingAlert.start);
  }

  // 本地规则会把「需要留意：…」追加在回答末尾。
  final caret = rest.lastIndexOf('需要留意：');
  final body = caret >= 0 ? rest.substring(0, caret) : rest;

  spans.addAll(_highlightNumbers(body, dataNumbers));

  if (caret >= 0) {
    spans.add(AnswerSpan(rest.substring(caret), AnswerSpanKind.alert));
  }
  if (trailingAlert != null) {
    spans.add(AnswerSpan(trailingAlert.group(0)!, AnswerSpanKind.alert));
  }
  return spans;
}

/// 数字后面是否紧跟「次 / 条」这类次数单位。
///
/// 只把「X 次 / X 条」当成用户的次数/条数；闲聊里的「50 岁」「8 小时」「3 亿」
/// 这些数字即使数值撞上摘要，也不是个人数据，不标蓝。
bool _followedByCountUnit(String text, int from) {
  var i = from;
  while (i < text.length && (text[i] == ' ' || text[i] == '　')) {
    i++;
  }
  return i < text.length && (text[i] == '次' || text[i] == '条');
}

/// 正文里的整数，命中 [dataNumbers] 且后面紧跟「次 / 条」的标成个人数据（蓝色）。
List<AnswerSpan> _highlightNumbers(String text, Set<int> dataNumbers) {
  if (dataNumbers.isEmpty || text.isEmpty) {
    return [if (text.isNotEmpty) AnswerSpan(text)];
  }
  final spans = <AnswerSpan>[];
  final numbers = RegExp(r'\d+');
  var index = 0;
  for (final match in numbers.allMatches(text)) {
    if (match.start > index) {
      spans.add(AnswerSpan(text.substring(index, match.start)));
    }
    final value = int.tryParse(match.group(0)!);
    final isData = value != null &&
        dataNumbers.contains(value) &&
        _followedByCountUnit(text, match.end);
    spans.add(
      AnswerSpan(
        match.group(0)!,
        isData ? AnswerSpanKind.data : AnswerSpanKind.plain,
      ),
    );
    index = match.end;
  }
  if (index < text.length) {
    spans.add(AnswerSpan(text.substring(index)));
  }
  return spans;
}

/// 摘要里「属于这个用户」的数字：原始计数 + 逐日序列 + 窗口长度。
///
/// 回答里出现这些数字时标成个人数据；通用知识里的数字（例如「全球约 3 亿人」）
/// 不在这里，所以不会被误标成用户的记录。页面在渲染 `ChatSource.knowledge`
/// 的回答时本来就不传这套数字，双保险。
Set<int> personalDataNumbers(AssistantContext context) => {
  context.todayCount,
  context.last7DaysCount,
  context.totalCount,
  context.invalidEventCount,
  context.unknownTimeCount,
  context.futureTimeCount,
  context.dailyCounts.length,
  ...context.dailyCounts,
};
