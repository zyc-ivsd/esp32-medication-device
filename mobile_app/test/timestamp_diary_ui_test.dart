import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/main.dart';
import 'package:medication_device_app/models/medication_record.dart';
import 'package:medication_device_app/services/record_controller.dart';

import 'support/preview_settings.dart';
import 'widget_test.dart' show MemoryRecords;

void main() {
  testWidgets(
    'timestamp diary shows counts, dates and original evidence in English',
    (tester) async {
      initializePreviewSettings();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fontDirectory = Platform.environment['PARCEL_PREVIEW_FONTS'];
      if (fontDirectory != null) {
        for (final entry in {
          'Roboto': 'roboto-regular.ttf',
          'MaterialIcons': 'MaterialIcons-Regular.otf',
        }.entries) {
          final bytes = File('$fontDirectory/${entry.value}').readAsBytesSync();
          final loader = FontLoader(entry.key)
            ..addFont(Future.value(ByteData.sublistView(bytes)));
          await tester.runAsync(loader.load);
        }
      }
      final repository = MemoryRecords(RecordSource.device);
      final now = DateTime(2026, 10, 4, 12);
      for (final entry in {
        '1.txt': '2026-10-04_08-30-00',
        '2.txt': '2026-10-04_10-15-00',
        '3.txt': '2026-10-03_08-30-00',
      }.entries) {
        repository.rows.add(
          MedicationRecord.deviceTimestamp(
            deviceId: 'AABBCCDDEEFF',
            fileId: entry.key,
            rawText: entry.value,
            receivedAt: now,
          ),
        );
      }
      final controller = RecordController(
        deviceRepository: repository,
        clock: () => now,
      );
      addTearDown(() async {
        controller.dispose();
        await repository.close();
      });
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MedicationDeviceApp(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.summary!.todayCount, 2);
      expect(controller.summary!.last7DaysCount, 3);
      expect(find.text('2 uses'), findsOneWidget);
      expect(find.text('Your medication diary'), findsOneWidget);
      expect(tester.takeException(), isNull);

      Future<void> capture(String name) async {
        final directory = Platform.environment['PARCEL_PREVIEW_OUTPUT'];
        if (directory == null) return;
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await render.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(directory).create(recursive: true);
          await File(
            '$directory/$name.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await capture('android-overview');
      await tester.tap(find.text('History').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('2026-10-04 08:30'), findsOneWidget);
      expect(find.text('Medication use'), findsNWidgets(3));
      expect(tester.takeException(), isNull);
      await capture('android-history');
      await tester.tap(find.text('Medication use').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('2026-10-04_08-30-00'), findsOneWidget);
      expect(
        find.textContaining('Not supplied by timestamp-only firmware'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await capture('android-record-detail');
    },
  );
}
