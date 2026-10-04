import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/assistant/answer_verification.dart';
import 'package:medication_device_app/assistant/assistant_knowledge.dart';
import 'package:medication_device_app/assistant/models/assistant_context.dart';

/// 知识库 `knowledge/README.md` 里的验收表，逐条对着检索结果验证。
void main() {
  test('空问题或无关问题检索不到任何一篇', () {
    expect(retrieveKnowledge(''), isEmpty);
    expect(retrieveKnowledge('   '), isEmpty);
    expect(retrieveKnowledge('今天天气怎么样'), isEmpty);
  });

  test('「设备能测出我吃了多少药吗」命中设备边界', () {
    final hits = retrieveKnowledge(
      'Can the device measure my medication dose?',
    );
    expect(hits.map((c) => c.id), contains('boundary.dose'));
  });

  test('「我上个月吃药规律吗」命中记录不代表服药', () {
    final hits = retrieveKnowledge('我上个月吃药规律吗');
    expect(hits.map((c) => c.id), contains('boundary.adherence'));
  });

  test('「同步提示 STORAGE_UNAVAILABLE 怎么办」命中对应错误码', () {
    final hits = retrieveKnowledge('同步提示 STORAGE_UNAVAILABLE 怎么办');
    expect(hits.map((c) => c.id), contains('sync.storage_unavailable'));
  });

  test('「我应该吃几片」只命中设备边界，不命中剂量建议', () {
    // 命中的是「设备不能测剂量」这条边界事实，不是剂量表；给剂量建议的硬拒绝
    // 在 system 提示词里，语料里没有「拒绝」文案，也没有任何服药指导。
    final hits = retrieveKnowledge('我应该吃几片');
    expect(hits, hasLength(1));
    expect(hits.single.id, 'boundary.dose');
    expect(hits.single.body, contains('does not measure dose'));
  });

  test('topK 截断且按相关度降序', () {
    final hits = retrieveKnowledge(
      'Can the device measure my medication dose?',
      topK: 1,
    );
    expect(hits, hasLength(1));
    expect(hits.first.id, 'boundary.dose');
  });

  test('toReference 拼成「标题：正文」的一行', () {
    final chunk = assistantKnowledge.firstWhere((c) => c.id == 'boundary.dose');
    expect(chunk.toReference(), '${chunk.title}: ${chunk.body}');
  });

  test('知识里出现的数字放行进回验，不被误判成编造', () {
    final chunks = retrieveKnowledge('同步提示 TOO_MANY_FILES 怎么办');
    final extra = <int>{
      for (final chunk in chunks) ...[
        ...numbersInText(chunk.title),
        ...numbersInText(chunk.body),
      ],
    };
    const context = AssistantContext();
    // 回验只认「N 次 / 条 / 天 / 日」这种统计口径的数字，所以这里要把 256
    // 说成一条统计结论（「256 个」是闲聊口径，根本不会进回验，测不出 extra）。
    const answer = '设备最多保存 256 条记录，超过后需要先同步并回收。';

    // 不带知识里的数字：256 不在摘要允许集合里，会被提醒「对不上」。
    expect(verifyRemoteAnswer(answer, context), contains('does not match'));
    // 带上检索到知识里的数字：256 是权威事实，不再误报。
    expect(
      verifyRemoteAnswer(answer, context, extra: extra),
      isNot(contains('does not match')),
    );
  });

  test('归一化后「近7天」也能命中带空格的「近 7 天」', () {
    final hits = retrieveKnowledge('近7天逐日怎么算');
    expect(hits.map((c) => c.id), contains('term.daily'));
  });

  test('同义组：说「服用」也能命中关键词是「吃药」的篇章', () {
    final hits = retrieveKnowledge('怎么判断用药情况');
    expect(hits.map((c) => c.id), contains('boundary.adherence'));
  });

  test('错一个字的关键词按近形模糊命中', () {
    // 「同步失败」写错成「同步失贝」：4 字关键词有 3 个二元组，错末字还剩 2 个，
    // 达到 0.6 阈值，仍能带回「同步失败怎么办」。
    final hits = retrieveKnowledge('同步失贝怎么办');
    expect(hits.map((c) => c.id), contains('sync.general'));
  });

  test('语料扩充后的新篇都能被问到', () {
    expect(
      retrieveKnowledge(
        'Does Local mode connect to the internet?',
      ).map((c) => c.id),
      contains('privacy.local'),
    );
    expect(
      retrieveKnowledge(
        'How is the total record count calculated?',
      ).map((c) => c.id),
      contains('term.total'),
    );
    expect(
      retrieveKnowledge('What is a suspected invalid use?').map((c) => c.id),
      contains('term.invalid'),
    );
    expect(
      retrieveKnowledge('带上本轮对话会发送什么').map((c) => c.id),
      contains('history.toggle'),
    );
  });

  test('App 功能片段都能被问到', () {
    expect(
      retrieveKnowledge('设备数据从哪里来').map((c) => c.id),
      contains('app.data_source'),
    );
    expect(
      retrieveKnowledge('怎么导出记录').map((c) => c.id),
      contains('app.export'),
    );
    expect(
      retrieveKnowledge('清空对话会删记录吗').map((c) => c.id),
      contains('app.clear'),
    );
    expect(
      retrieveKnowledge('怎么搜索对话').map((c) => c.id),
      contains('app.search'),
    );
    expect(
      retrieveKnowledge('Can answers be read aloud?').map((c) => c.id),
      contains('app.tts'),
    );
    expect(
      retrieveKnowledge('字太小看不清').map((c) => c.id),
      contains('app.large_text'),
    );
    expect(
      retrieveKnowledge('怎么启用在线').map((c) => c.id),
      contains('app.online'),
    );
  });

  test('App 功能语料不放任何医学内容', () {
    // 语料只讲设备和 App 用法，不出现剂量/诊断/服药指导这类诱导医疗建议的词。
    final appChunks = assistantKnowledge.where((c) => c.id.startsWith('app.'));
    for (final chunk in appChunks) {
      for (final forbidden in ['剂量', '诊断', '几片', '用法用量', '处方']) {
        expect(chunk.body, isNot(contains(forbidden)), reason: chunk.id);
      }
    }
  });
}
