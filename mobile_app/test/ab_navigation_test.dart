import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/ble/ble_service.dart';
import 'package:medication_device_app/ble/ble_status_page.dart';
import 'package:medication_device_app/main.dart';
import 'package:medication_device_app/models/medication_record.dart';
import 'package:medication_device_app/services/record_controller.dart';
import 'widget_test.dart' show MemoryRecords;
import 'support/record_fixtures.dart';

void main() {
  testWidgets(
    'device navigation keeps BLE accessible and uses the same record repository',
    (tester) async {
      final device = MemoryRecords(RecordSource.device);
      final controller = RecordController(deviceRepository: device);
      final ble = BleService.test();
      addTearDown(() async {
        ble.dispose();
        controller.dispose();
        await device.close();
      });
      await saveTestDeviceRecords(device, controller.clock());
      await controller.refresh();
      await tester.pumpWidget(
        MedicationDeviceApp(
          controller: controller,
          connectionBuilder: (_, repository) {
            expect(identical(repository, device), true);
            return BleConnectionCard(service: ble);
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byType(BleConnectionCard),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byType(BleConnectionCard));
      await tester.pumpAndSettle();
      expect(find.text('Device connection'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('History').last);
      await tester.pumpAndSettle();
      expect(controller.source, RecordSource.device);
      expect(controller.records, hasLength(11));
      expect(await device.readAll(), hasLength(11));
      expect(tester.takeException(), isNull);
    },
  );
}
