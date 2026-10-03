/// 追问建议：按**用户问句**路由到同主题/邻近的快捷问题。
///
/// 靠问句而不是靠回答分类——问句是本地可控的，在线模型的回答是自由文本不好分类，
/// 所以本地和在线两种模式都能用同一套。返回的问题只落在「本地可答」的主题集内，
/// 绝不诱导医疗判断（不吃药/剂量/诊断那类问法）。
List<String> followUpsFor(String question) {
  for (final topic in _topics) {
    if (topic.keywords.any(question.contains)) {
      return topic.followUps;
    }
  }
  return const ['今天用了几次？', '数据是最新的吗？', '有什么建议？'];
}

/// 主题顺序即优先级：先命中的先给（与本地规则的分派顺序保持一致，
/// 例如「最近有异常吗」同时含「最近」和「异常」，本地按「异常」分支回答，
/// 这里也把「异常」主题放前面）。
const _topics = <_Topic>[
  _Topic(
    keywords: {'今天', '次数', '一共', '多少条', '总共', '总量'},
    followUps: ['查看最近一周', '数据是最新的吗？', '设备时间对吗？'],
  ),
  _Topic(
    keywords: {'异常', '无效'},
    followUps: ['空白那几天怎么看？', '数据是最新的吗？', '有什么建议？'],
  ),
  _Topic(
    keywords: {'最近', '一周', '规律', '波动', '趋势'},
    followUps: ['今天用了几次？', '一共有多少条记录？', '空白那几天怎么看？'],
  ),
  _Topic(
    keywords: {'同步', '最新', '多久'},
    followUps: ['设备时间对吗？', '最近有异常吗？', '一共有多少条记录？'],
  ),
  _Topic(
    keywords: {'时间', '校时', '日期'},
    followUps: ['数据是最新的吗？', '空白那几天怎么看？', '一共有多少条记录？'],
  ),
  _Topic(
    keywords: {'空白', '空着', '没记录', '漏记'},
    followUps: ['设备时间对吗？', '最近有异常吗？', '有什么建议？'],
  ),
];

class _Topic {
  const _Topic({required this.keywords, required this.followUps});

  final Set<String> keywords;
  final List<String> followUps;
}
