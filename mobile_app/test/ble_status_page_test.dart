import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/ble/ble_service.dart';
import 'package:medication_device_app/ble/ble_status_page.dart';

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
}
