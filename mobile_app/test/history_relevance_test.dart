import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/assistant/history_relevance.dart';

void main() {
  const bluetoothQ = (role: 'user', text: '怎么连接蓝牙设备');
  const bluetoothA = (role: 'assistant', text: '在 App 里扫描广播窗口，不要系统配对。');
  const todayQ = (role: 'user', text: '今天用了几次');
  const todayA = (role: 'assistant', text: '今天使用 2 次。');
  const syncQ = (role: 'user', text: '数据是最新的吗');
  const syncA = (role: 'assistant', text: '最后一次同步是昨天。');
  const followQ = (role: 'user', text: '还有别的吗');
  const followA = (role: 'assistant', text: '没有了。');

  test('回合数不超过上限时原样返回、顺序不变', () {
    final turns = [bluetoothQ, bluetoothA, todayQ, todayA];
    expect(relevantTurns(turns, '今天用了几次', maxTurns: 8), turns);
  });

  test('超过上限时裁掉无关早期回合，保留相关早期回合和最近回合', () {
    final turns = [
      bluetoothQ,
      bluetoothA,
      todayQ,
      todayA,
      syncQ,
      syncA,
      followQ,
      followA,
    ];
    final result = relevantTurns(turns, '今天用了几次', maxTurns: 4);

    // 与「今天」相关的更早问答留下；蓝牙、同步主题被裁掉。
    expect(result, contains(todayQ));
    expect(result, contains(todayA));
    expect(result, isNot(contains(bluetoothQ)));
    expect(result, isNot(contains(bluetoothA)));
    expect(result, isNot(contains(syncQ)));
    expect(result, isNot(contains(syncA)));
    // 最近一回合是「还有别的吗」这种零重叠的追问，也必须保留，否则追问就断了。
    expect(result, contains(followQ));
    expect(result, contains(followA));
    // 时间序保持：相关早期回合在前，最近回合在后。
    expect(result, [todayQ, todayA, followQ, followA]);
  });

  test('无关历史再多，也不会把整段聊天都发出去', () {
    // 只有最后一条「今天」相关，其余全是无关主题——相关性裁剪后不超上限，
    // 也不会把蓝牙/同步/闲聊全部带上。
    final turns = [
      bluetoothQ,
      bluetoothA,
      syncQ,
      syncA,
      followQ,
      followA,
      todayQ,
      todayA,
    ];
    final result = relevantTurns(turns, '今天用了几次', maxTurns: 4);
    expect(result, [todayQ, todayA]);
  });
}
