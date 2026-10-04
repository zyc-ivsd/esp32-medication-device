// Optional local preview rendering; not an Android/iOS device test.
// flutter test tool/preview_app_test.dart --dart-define=PREVIEW_DIR=...
//   --dart-define=PREVIEW_FONT=C:/Windows/Fonts/msyh.ttc
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/main.dart';
import 'package:medication_device_app/models/medication_record.dart';
import 'package:medication_device_app/services/record_controller.dart';
import 'package:medication_device_app/ble/ble_service.dart';
import 'package:medication_device_app/ble/ble_status_page.dart';
import '../test/support/preview_settings.dart';
import '../test/widget_test.dart' show MemoryRecords;

void main() {
  const output = String.fromEnvironment('PREVIEW_DIR');
  const fontPath = String.fromEnvironment('PREVIEW_FONT');
  testWidgets('render app empty device screens', (tester) async {
    initializePreviewSettings();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    if (fontPath.isNotEmpty) {
      final bytes = ByteData.sublistView(File(fontPath).readAsBytesSync());
      for (final family in ['Ahem', 'Roboto']) {
        final loader = FontLoader(family)..addFont(Future.value(bytes));
        await tester.runAsync(loader.load);
      }
    }
    final iconsFile = File(
      'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
    );
    if (iconsFile.existsSync()) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(ByteData.sublistView(iconsFile.readAsBytesSync())),
        );
      await tester.runAsync(loader.load);
    }
    final device = MemoryRecords(RecordSource.device);
    final controller = RecordController(
      deviceRepository: device,
      clock: () => DateTime(2026, 9, 12, 12),
    );
    addTearDown(() async {
      controller.dispose();
      await device.close();
    });
    await controller.refresh();
    final ble = BleService.test();
    addTearDown(ble.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MedicationDeviceApp(
          controller: controller,
          connectionBuilder: (_, repository) => BleConnectionCard(service: ble),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> capture(String name) async {
      expect(tester.takeException(), isNull);
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(output).create(recursive: true);
        await File(
          '$output/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await capture('app-overview');
    await tester.scrollUntilVisible(
      find.byType(BleConnectionCard),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byType(BleConnectionCard));
    await tester.pumpAndSettle();
    await capture('app-ble');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('历史记录').last);
    await tester.pumpAndSettle();
    await capture('app-history');
    await tester.tap(find.text('概览'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('问问记录助手'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('问问记录助手'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ActionChip, '今天用了几次？'));
    await tester.pumpAndSettle();
    await capture('app-assistant');
    await tester.tap(find.byTooltip('管理 API'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加新的 API'));
    await tester.pumpAndSettle();
    await capture('app-assistant-settings');
  }, skip: output.isEmpty);
}
