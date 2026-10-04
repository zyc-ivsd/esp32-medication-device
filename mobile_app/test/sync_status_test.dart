import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/assistant/models/assistant_context.dart';
import 'package:medication_device_app/assistant/sync_status.dart';

void main() {
  final now = DateTime(2026, 9, 30, 12);

  test('无同步时间 → never', () {
    const context = AssistantContext();
    expect(syncStatus(context, now), SyncStatus.never);
  });

  test('超过三天未同步 → stale', () {
    final context = AssistantContext(lastSyncAt: DateTime(2026, 9, 20));
    expect(syncStatus(context, now), SyncStatus.stale);
  });

  test('最近同步 → fresh', () {
    final context = AssistantContext(lastSyncAt: DateTime(2026, 9, 29));
    expect(syncStatus(context, now), SyncStatus.fresh);
  });

  test('同步时间在未来 → stale（设备时间设错）', () {
    final context = AssistantContext(lastSyncAt: DateTime(2026, 10, 5));
    expect(syncStatus(context, now), SyncStatus.stale);
  });
}
