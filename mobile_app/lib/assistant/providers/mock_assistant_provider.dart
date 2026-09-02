import '../assistant_provider.dart';
import '../models/assistant_context.dart';

/// 不依赖网络和 API Key 的确定性回答器，用于开发、演示和自动化测试。
class MockAssistantProvider implements AssistantProvider {
  @override
  Future<String> reply({
    required String question,
    required AssistantContext context,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));

    final normalizedQuestion = question.trim();
    if (normalizedQuestion.isEmpty) {
      return '请先输入问题。';
    }

    if (normalizedQuestion.contains('今天') ||
        normalizedQuestion.contains('次数')) {
      return '根据当前本地记录，今天使用 ${context.todayCount} 次，'
          '近 7 天共 ${context.last7DaysCount} 次。';
    }

    if (normalizedQuestion.contains('最近') ||
        normalizedQuestion.contains('一周')) {
      return '近 7 天记录为 ${context.last7DaysCount} 次，'
          '其中疑似无效记录 ${context.invalidEventCount} 条。';
    }

    if (normalizedQuestion.contains('异常') ||
        normalizedQuestion.contains('无效')) {
      return context.invalidEventCount == 0
          ? '当前没有发现疑似无效记录。这个结果仅基于设备记录，不能替代专业判断。'
          : '当前有 ${context.invalidEventCount} 条疑似无效记录，建议查看原始记录并结合实际情况判断。';
    }

    return '这是第一阶段 Mock 模式回答。当前记录摘要：${context.toPromptSummary()} '
        '后续接入 AI 网关后，将由真实 Provider 生成回答。';
  }
}
