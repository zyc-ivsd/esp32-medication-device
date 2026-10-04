import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/ble/ble_service.dart';
import 'package:medication_device_app/ble/ble_status_page.dart';
import 'package:medication_device_app/models/medication_record.dart';
import 'package:medication_device_app/pages/home_page.dart';
import 'package:medication_device_app/services/record_controller.dart';
import 'widget_test.dart' show MemoryRecords;
import 'support/record_fixtures.dart';

void main() {
  for (final size in [
    const Size(375, 667),
    const Size(844, 390),
    const Size(1024, 768),
  ]) {
    testWidgets(
      'iOS BLE layout supports $size with large text and safe areas',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final service = BleService.test();
        addTearDown(service.dispose);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(1.5),
                padding: const EdgeInsets.fromLTRB(44, 24, 44, 34),
              ),
              child: child!,
            ),
            home: BleStatusPage(service: service),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(find.text('Scan devices'), 150);
        final bounds = tester.getRect(
          find.widgetWithText(FilledButton, 'Scan devices'),
        );
        expect(bounds.left, greaterThanOrEqualTo(44));
        expect(bounds.right, lessThanOrEqualTo(size.width - 44));
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({TargetPlatform.iOS}),
    );
  }
  testWidgets(
    'iPad CSV share receives a visible nonzero anchor and the current filtered records',
    (tester) async {
      tester.view.physicalSize = const Size(1024, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final device = MemoryRecords(RecordSource.device);
      final data = RecordController(deviceRepository: device);
      addTearDown(() async {
        data.dispose();
        await device.close();
      });
      await saveTestDeviceRecords(device, data.clock());
      await data.refresh();
      Rect? anchor;
      await tester.pumpWidget(
        MaterialApp(
          home: HomePage(
            controller: data,
            exportRecords: (records, source, origin) async {
              anchor = origin;
              expect(records.length, data.visibleRecords.length);
              expect(source, RecordSource.device);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('History').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export CSV'));
      await tester.pumpAndSettle();
      expect(anchor, isNotNull);
      expect(anchor!.width, greaterThan(0));
      expect(anchor!.height, greaterThan(0));
      expect(
        (const Rect.fromLTWH(0, 0, 1024, 768)).contains(anchor!.center),
        true,
      );
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.iOS}),
  );
}
