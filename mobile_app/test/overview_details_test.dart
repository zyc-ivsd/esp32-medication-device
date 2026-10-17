import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/database/record_repository.dart';
import 'package:medication_device_app/models/medication_record.dart';
import 'package:medication_device_app/pages/home_page.dart';
import 'package:medication_device_app/services/record_controller.dart';

import 'widget_test.dart' show MemoryRecords;

MedicationRecord use(
  DateTime local, {
  required int seq,
  int type = 1,
  String deviceId = 'C3-A',
}) => MedicationRecord(
  deviceId: deviceId,
  seq: seq,
  timestamp: local.millisecondsSinceEpoch ~/ 1000,
  eventType: type,
  durationMs: 1200,
  pressurePeakPa: -84,
  confidence: 90,
  batteryMv: 3700,
);

void main() {
  final now = DateTime(2026, 9, 12, 12);

  late MemoryRecords device;
  late RecordController controller;

  setUp(() {
    device = MemoryRecords(RecordSource.device);
    controller = RecordController(deviceRepository: device, clock: () => now);
  });

  tearDown(() async {
    controller.dispose();
    await device.close();
  });

  Future<void> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(home: HomePage(controller: controller)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('all saved records mark invalid entries grey with a hint', (
    tester,
  ) async {
    device.rows.addAll([
      use(DateTime(2026, 9, 12, 8, 0, 0), seq: 1, type: 2),
      use(DateTime(2026, 9, 12, 9, 30, 0), seq: 2),
    ]);
    await controller.refresh();
    await pumpHome(tester);

    await tester.ensureVisible(find.text('All saved records').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('All saved records').last);
    await tester.pumpAndSettle();

    expect(find.text('(invalid)'), findsOneWidget);
    final hint = tester.widget<Text>(find.text('(invalid)'));
    final stamp = tester.widget<Text>(find.textContaining('09-12-2026 08:00'));
    expect(
      hint.style!.fontSize,
      stamp.style!.fontSize! - 2,
      reason: 'the hint must be two font sizes smaller than the timestamp',
    );
    expect(hint.style!.color, stamp.style!.color);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a bar in invalid uses shows that day times', (
    tester,
  ) async {
    device.rows.addAll([
      use(DateTime(2026, 9, 12, 8, 0, 5), seq: 1, type: 2),
      use(DateTime(2026, 9, 12, 9, 30, 0), seq: 2),
    ]);
    await controller.refresh();
    await pumpHome(tester);

    await tester.ensureVisible(find.text('Invalid uses (7 days)').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Invalid uses (7 days)').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('daily-bar-6')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('daily-bar-6')));
    await tester.pumpAndSettle();

    expect(find.textContaining('invalid uses'), findsWidgets);
    expect(find.text('08:00:05'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a bar in uses in 7 days shows valid times only', (
    tester,
  ) async {
    device.rows.addAll([
      use(DateTime(2026, 9, 12, 8, 0, 5), seq: 1, type: 2),
      use(DateTime(2026, 9, 12, 9, 30, 0), seq: 2),
    ]);
    await controller.refresh();
    await pumpHome(tester);

    await tester.ensureVisible(find.text('Uses in 7 days').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Uses in 7 days').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('daily-bar-6')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('daily-bar-6')));
    await tester.pumpAndSettle();

    expect(find.text('09:30:00'), findsOneWidget);
    expect(find.text('08:00:05'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
