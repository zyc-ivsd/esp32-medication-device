import 'assistant_provider.dart';

/// 多轮上下文的相关性裁剪。
///
/// 直连模型时，开启「带上本轮对话」会把本轮更早的问答带出去帮助理解追问。无脑取
/// 「最近 N 条」有两个问题：一是无关的旧聊天也会一起离开手机（能少发就少发），
/// 二是模型会被不相关的上下文带偏。所以这里只保留**与当前问题有内容交集**的更早
/// 回合，再并上最近一回合问答——追问常是「还有呢」「上次那个」这类零重叠的短句，
/// 它们必须留下来，否则多轮追问就断了。
///
/// 规则：
/// - 回合数不超过 [maxTurns] 时原样返回，不裁；
/// - 否则总是保留最后两条（最近一轮 user/assistant，若有），更早的只留与问题
///   共享任意字符二元组的，最后按时间序截到 [maxTurns]。
///
/// 用字符二元组而不是分词：中文没有天然空格，二元组是不引入任何依赖的最轻做法，
/// 与知识库检索（`assistant_knowledge.dart`）同一口径，好理解也好测。
List<ChatTurn> relevantTurns(
  List<ChatTurn> turns,
  String question, {
  int maxTurns = 8,
}) {
  if (turns.length <= maxTurns) return List.of(turns);
  final qBigrams = _bigrams(_canonical(question));
  final recentCount = turns.length >= 2 ? 2 : turns.length;
  final recent = turns.sublist(turns.length - recentCount);
  final earlier = turns.sublist(0, turns.length - recentCount);
  final keptEarlier = <ChatTurn>[
    for (final turn in earlier)
      if (_sharesAny(qBigrams, turn.text)) turn,
  ];
  final merged = [...keptEarlier, ...recent];
  return merged.length > maxTurns
      ? merged.sublist(merged.length - maxTurns)
      : merged;
}

/// 归一化：小写化并去掉空白与常见中英文标点，让「近 7 天」「近7天」等价。
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
  '　',
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

/// 文本的字符二元组集合。
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

/// 两个文本是否有内容交集：共享任意一个字符二元组。
bool _sharesAny(Set<String> qBigrams, String turnText) {
  final turnBigrams = _bigrams(_canonical(turnText));
  return qBigrams.any(turnBigrams.contains);
}
