import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/assistant/assistant_page.dart';
import 'package:medication_device_app/assistant/models/assistant_context.dart';
import 'package:medication_device_app/database/record_repository.dart';
import 'package:medication_device_app/main.dart';
import 'package:medication_device_app/models/medication_record.dart';
import 'package:medication_device_app/pages/home_page.dart';
import 'package:medication_device_app/services/record_controller.dart';
import 'support/record_fixtures.dart';

/// UI fixture only. Real SQLite durability/transactions are exercised in
/// record_data_test.dart, rather than inferred from this in-memory fake.
class MemoryRecords implements RecordRepository {
  MemoryRecords(this.source);
  @override
  final RecordSource source;
  final rows = <MedicationRecord>[];
  final events = StreamController<void>.broadcast();
  bool failRead = false;
  @override
  Stream<void> get changes => events.stream;
  @override
  Future<List<MedicationRecord>> readAll() async {
    if (failRead) throw StateError('unavailable');
    return List.of(rows);
  }

  @override
  Future<DateTime?> lastSyncAt() async => null;
  @override
  Future<SaveRecordResult> saveValidatedRecord(MedicationRecord record) async {
    rows.add(record);
    events.add(null);
    return SaveRecordResult.inserted;
  }

  @override
  Future<int?> readSyncCursor(String deviceId) async => null;
  @override
  Future<void> advanceSyncCursor(
    String deviceId,
    int seq, {
    int? firstSequence,
  }) async {}
  @override
  Future<void> markSyncCompleted(DateTime instant) async {}
  @override
  Future<void> close() async => events.close();
}

void main() {
  late MemoryRecords device;
  late RecordController controller;
  setUp(() {
    device = MemoryRecords(RecordSource.device);
    controller = RecordController(
      deviceRepository: device,
      clock: () => DateTime(2026, 9, 12, 12),
    );
  });
  tearDown(() async {
    controller.dispose();
    await device.close();
  });

  testWidgets('empty device view has no generated records or dataset switch', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MedicationDeviceApp(controller: controller));
    await tester.pumpAndSettle();
    expect(controller.summary!.total, 0);
    expect(find.textContaining('演示数据'), findsNothing);
    expect(find.byType(SegmentedButton<RecordSource>), findsNothing);
    expect(find.textContaining('Connect and sync'), findsOneWidget);
    expect(device.rows, isEmpty);
    await tester.tap(find.text('History').last);
    await tester.pumpAndSettle();
    expect(find.text('No records yet'), findsOneWidget);
    expect(controller.records, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'history date filter exports exactly the visible snapshot and source',
    (tester) async {
      await saveTestDeviceRecords(device, controller.clock());
      await controller.refresh();
      List<MedicationRecord>? exported;
      RecordSource? source;
      await tester.pumpWidget(
        MaterialApp(
          home: HomePage(
            controller: controller,
            exportRecords: (records, selectedSource, origin) async {
              exported = records;
              source = selectedSource;
              expect(origin.width, greaterThan(0));
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('History').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Today'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(
        find.text('Showing 2 records · CSV exports the same selection'),
        findsOneWidget,
      );
      await tester.tap(find.text('Export CSV'));
      await tester.pumpAndSettle();
      expect(exported, hasLength(2));
      expect(source, RecordSource.device);
      expect(exported!.every((record) => record.timestamp != 0), isTrue);
    },
  );

  testWidgets(
    'assistant reloads context on each question instead of using a stale snapshot',
    (tester) async {
      var loads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: AssistantPage(
            contextLoader: () async {
              loads++;
              return AssistantContext(
                todayCount: loads + 3,
                last7DaysCount: loads + 8,
              );
            },
          ),
        ),
      );
      await tester.tap(find.widgetWithText(ActionChip, 'How many uses today?'));
      await tester.pumpAndSettle();
      expect(find.textContaining('4 uses today'), findsOneWidget);
      await tester.tap(find.widgetWithText(ActionChip, 'How many uses today?'));
      await tester.pumpAndSettle();
      expect(find.textContaining('5 uses today'), findsOneWidget);
      expect(loads, 2);
    },
  );

  testWidgets('read errors offer retry and hide stale statistics', (
    tester,
  ) async {
    device.failRead = true;
    await tester.pumpWidget(MedicationDeviceApp(controller: controller));
    await tester.pumpAndSettle();
    expect(
      find.text('Cannot read local records. Please try again.'),
      findsOneWidget,
    );
    expect(controller.summary, isNull);
    device.failRead = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(controller.summary!.total, 0);
    expect(find.text('Your medication diary'), findsOneWidget);
  });

  testWidgets('compact and large-text layouts keep core controls usable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await saveTestDeviceRecords(device, controller.clock());
    await controller.refresh();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: HomePage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('History').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
