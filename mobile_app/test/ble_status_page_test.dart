import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/ble/ble_service.dart';
import 'package:medication_device_app/ble/ble_status_page.dart';
import 'package:medication_device_app/ble/prototype_protocol.dart';

void main() {
  testWidgets(
    'BLE status page renders prototype title and disconnected state',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: BleStatusPage(service: BleService.test())),
      );

      expect(find.text('Sync your medication diary'), findsOneWidget);
      expect(find.text('Disconnected'), findsOneWidget);
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('Saved device timestamps'),
        150,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('saved device timestamps show date with second precision', (
    tester,
  ) async {
    final service = BleService.test();
    addTearDown(service.dispose);
    final local = DateTime(2026, 10, 4, 8, 30, 45);
    final rawText = (local.toUtc().millisecondsSinceEpoch ~/ 1000)
        .toRadixString(16)
        .padLeft(16, '0');
    service.savedRecords = [
      PrototypeRecord(
        deviceId: 'AABBCCDDEEFF',
        fileId: '1.txt',
        rawText: rawText,
        receivedAt: local,
      ),
    ];
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(home: BleStatusPage(service: service)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('10-04-2026 08:30:45'), 150);
    expect(find.text('10-04-2026 08:30:45'), findsOneWidget);
    expect(find.text(rawText), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
