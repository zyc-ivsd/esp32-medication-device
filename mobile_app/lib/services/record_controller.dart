import 'dart:async';

import 'package:flutter/foundation.dart';

import '../database/record_repository.dart';
import '../models/medication_record.dart';
import '../models/record_filter.dart';
import '../models/record_summary.dart';

class RecordController extends ChangeNotifier {
  RecordController({required this.deviceRepository, DateTime Function()? clock})
    : clock = clock ?? DateTime.now {
    _subscriptions.add(
      deviceRepository.changes.listen((_) => unawaited(refresh())),
    );
  }

  final RecordRepository deviceRepository;
  final DateTime Function() clock;
  final List<StreamSubscription<void>> _subscriptions = [];
  RecordSource get source => RecordSource.device;
  RecordFilter filter = const RecordFilter();
  List<MedicationRecord> records = const [];
  RecordSummary? summary;
  bool loading = false;
  String? error;
  var _revision = 0;
  var _disposed = false;
  Future<void>? _latestRefresh;

  RecordRepository get repository => deviceRepository;
  List<MedicationRecord> get visibleRecords => records
      .where((record) => filter.accepts(record.timestamp))
      .toList(growable: false);

  void setFilter(RecordFilter value) {
    filter = value;
    notifyListeners();
  }

  Future<void> refresh() {
    if (_disposed) return Future.value();
    final revision = ++_revision;
    // The Future returned to callers also waits for a newer refresh triggered
    // by a repository event; awaiting refresh must mean the latest data is ready.
    final pending = Future<void>.microtask(() => _readSnapshot(revision));
    _latestRefresh = pending;
    return _waitForLatest(pending);
  }

  Future<void> _waitForLatest(Future<void> pending) async {
    while (true) {
      await pending;
      if (_disposed || identical(pending, _latestRefresh)) return;
      pending = _latestRefresh!;
    }
  }

  Future<void> _readSnapshot(int revision) async {
    if (_disposed || revision != _revision) return;
    final repo = repository;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final data = await repo.readAll();
      final lastSync = await repo.lastSyncAt();
      if (_disposed || revision != _revision) return;
      records = List.unmodifiable(data);
      summary =
          RecordSummary.calculate(data, now: clock(), lastSyncAt: lastSync);
    } catch (_) {
      if (_disposed || revision != _revision) return;
      // Do not display/export stale data as a successful refresh.
      records = const [];
      summary = null;
      error = '暂时无法读取本地记录，请重试。';
    } finally {
      if (!_disposed && revision == _revision) {
        loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }
}
