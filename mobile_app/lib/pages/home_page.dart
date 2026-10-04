import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../assistant/assistant_page.dart';
import '../assistant/rules/observation_rules.dart';
import '../database/record_repository.dart';
import '../models/medication_record.dart';
import '../models/record_filter.dart';
import '../models/record_summary.dart';
import '../services/csv_export_service.dart';
import '../services/record_controller.dart';

/// B supplies BLE UI here. It receives the device record repository.
typedef DeviceConnectionBuilder =
    Widget Function(BuildContext, RecordRepository);
typedef ExportRecords =
    Future<void> Function(List<MedicationRecord>, RecordSource, Rect);

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.controller,
    this.connectionBuilder,
    this.exportRecords,
  });
  final RecordController controller;
  final DeviceConnectionBuilder? connectionBuilder;
  final ExportRecords? exportRecords;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  int _tab = 0;
  bool _working = false;

  /// 用户在本次会话里关掉提醒卡片后不再显示；重新打开 App 会重新评估。
  bool _alertDismissed = false;
  RecordController get data => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(data.refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(data.refresh());
  }

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _export(BuildContext buttonContext) async {
    final snapshot = List<MedicationRecord>.of(data.visibleRecords);
    final source = data.source;
    final box = buttonContext.findRenderObject()! as RenderBox;
    final origin = box.localToGlobal(Offset.zero) & box.size;
    setState(() => _working = true);
    try {
      if (widget.exportRecords != null) {
        await widget.exportRecords!(snapshot, source, origin);
      } else {
        await CsvExportService().share(
          records: snapshot,
          source: source,
          origin: origin,
        );
      }
    } catch (_) {
      _message('Cannot open the share sheet. Please try again.');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _openAssistant() async {
    final repo = data.repository;
    final initial = data.summary;
    if (initial == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AssistantPage(
          assistantContext: initial.toAssistantContext(),
          contextLoader: () async => RecordSummary.calculate(
            await repo.readAll(),
            now: data.clock(),
            lastSyncAt: await repo.lastSyncAt(),
          ).toAssistantContext(),
        ),
      ),
    );
    if (mounted) await data.refresh();
  }

  Future<void> _pickDates() async {
    final now = data.clock().toLocal();
    final start = data.filter.start;
    final end = data.filter.endExclusive;
    final chosen = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2106, 2, 7),
      currentDate: now,
      initialDateRange: start == null || end == null
          ? null
          : DateTimeRange(
              start: start,
              end: DateTime(end.year, end.month, end.day - 1),
            ),
      helpText: 'Filter record dates',
      saveText: 'Apply',
    );
    if (chosen != null && mounted) {
      data.setFilter(
        RecordFilter(
          start: chosen.start,
          endExclusive: DateTime(
            chosen.end.year,
            chosen.end.month,
            chosen.end.day + 1,
          ),
          includeUnknown: data.filter.includeUnknown,
        ),
      );
    }
  }

  void _presetDays(int? days) {
    final now = data.clock().toLocal();
    data.setFilter(
      RecordFilter(
        start: days == null
            ? null
            : DateTime(now.year, now.month, now.day - days + 1),
        endExclusive: days == null
            ? null
            : DateTime(now.year, now.month, now.day + 1),
        includeUnknown: data.filter.includeUnknown,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: data,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('parcel'),
        actions: [
          // 助手是核心入口，不能只藏在滚动区底部的按钮里。
          IconButton(
            onPressed: data.summary == null || data.loading
                ? null
                : _openAssistant,
            tooltip: 'Record assistant',
            icon: const Icon(Icons.chat_bubble_outline),
          ),
          IconButton(
            onPressed: data.loading ? null : data.refresh,
            tooltip: 'Refresh records',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 880),
            child: Column(
              children: [
                if (data.loading) const LinearProgressIndicator(minHeight: 2),
                Expanded(
                  child: data.error != null
                      ? _errorView()
                      : RefreshIndicator(
                          onRefresh: data.refresh,
                          child: _tab == 0 ? _overview() : _history(),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'Overview',
          ),
          NavigationDestination(icon: Icon(Icons.history), label: 'History'),
        ],
      ),
    ),
  );

  /// 与助手共用同一套规则：概览页只负责把 attention 级观察提前告诉用户，
  /// 自己不再实现一份判断逻辑。
  List<AssistantObservation> _attentionObservations() {
    final summary = data.summary;
    if (summary == null) return const [];
    return evaluateObservations(summary.toAssistantContext(), now: data.clock())
        .where((observation) => observation.level == ObservationLevel.attention)
        .toList(growable: false);
  }

  Widget _alertCard(List<AssistantObservation> observations) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.notifications_active_outlined,
              size: 22,
              color: scheme.onTertiaryContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    observations.length == 1
                        ? '1 item needs attention'
                        : '${observations.length} items need attention',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: scheme.onTertiaryContainer,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final observation in observations)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        '· ${observation.text}',
                        style: TextStyle(color: scheme.onTertiaryContainer),
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: _openAssistant,
                      child: const Text('Ask the assistant'),
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () => setState(() => _alertDismissed = true),
              tooltip: 'Dismiss for this session',
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorView() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.storage_outlined, size: 40),
          const SizedBox(height: 12),
          Text(data.error!),
          TextButton(onPressed: data.refresh, child: const Text('Retry')),
        ],
      ),
    ),
  );

  Widget _overview() {
    final summary = data.summary;
    final alerts = _attentionObservations();
    final showAlerts = !_alertDismissed && alerts.isNotEmpty;
    return ListView(
      padding: const EdgeInsets.all(20),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        Text(
          'Your medication diary',
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        const Text('Saved on your phone · Available offline'),
        const SizedBox(height: 20),
        if (showAlerts) ...[_alertCard(alerts), const SizedBox(height: 20)],
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 650 ? 4 : 2;
            final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _metric(
                  'Uses today',
                  summary?.todayCount,
                  'uses',
                  Icons.today_outlined,
                  width,
                ),
                _metric(
                  'Uses in 7 days',
                  summary?.last7DaysCount,
                  'uses',
                  Icons.calendar_month_outlined,
                  width,
                ),
                _metric(
                  'Invalid uses (7 days)',
                  summary?.invalidEventCount,
                  'records',
                  Icons.info_outline,
                  width,
                ),
                _metric(
                  'All saved records',
                  summary?.total,
                  'records',
                  Icons.storage_outlined,
                  width,
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 20),
        if (summary != null && summary.total > 0) ...[
          _weekChart(summary),
          const SizedBox(height: 12),
          Text(
            'Counts use the recorded calendar date. ${summary.unknownTimeCount} unknown-time and '
            '${summary.futureTimeCount} future-time records are excluded from daily counts.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
        ],
        widget.connectionBuilder?.call(context, data.deviceRepository) ??
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.bluetooth_searching, size: 28),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'No device connected',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Connect and sync to turn device timestamps into medication-use records.',
                          ),
                          if (summary?.lastSyncAt != null)
                            Text(
                              'Last sync: ${dateLabel(summary!.lastSyncAt!.toLocal())} '
                              '${timeLabel(summary.lastSyncAt!.toLocal())}',
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        const SizedBox(height: 12),
        if ((summary?.total ?? 0) == 0)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'No medication records yet. Connect your device and sync to get started.',
            ),
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: summary == null || data.loading ? null : _openAssistant,
          icon: const Icon(Icons.chat_bubble_outline),
          label: const Text('Ask the assistant'),
        ),
        const SizedBox(height: 12),
        Text(
          'Each valid device timestamp records one use. The app does not measure dose or verify ingestion.',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _metric(
    String title,
    int? count,
    String unit,
    IconData icon,
    double width,
  ) => SizedBox(
    width: width,
    child: Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 10),
            Text(title, style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 8),
            Text(
              '${count ?? '—'} $unit',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    ),
  );
  Widget _weekChart(RecordSummary summary) {
    final max = summary.days.fold<int>(
      1,
      (max, day) => math.max(max, day.count),
    );
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Last 7 days',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final day in summary.days)
                  Expanded(
                    child: Semantics(
                      label:
                          '${dateLabel(day.day)}, ${day.count} medication uses',
                      excludeSemantics: true,
                      child: Column(
                        children: [
                          Text('${day.count}'),
                          const SizedBox(height: 6),
                          SizedBox(
                            height: 70,
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              child: Container(
                                width: 18,
                                height: math.max(3, day.count / max * 70),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.primary,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${day.day.month}/${day.day.day}',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _history() {
    final visible = data.visibleRecords;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(20),
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 16,
          children: [
            Text('History', style: Theme.of(context).textTheme.headlineSmall),
            Builder(
              builder: (buttonContext) => FilledButton.tonalIcon(
                onPressed: _working || data.loading || visible.isEmpty
                    ? null
                    : () => _export(buttonContext),
                icon: const Icon(Icons.ios_share),
                label: const Text('Export CSV'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            ActionChip(
              label: const Text('All dates'),
              onPressed: () => _presetDays(null),
            ),
            ActionChip(
              label: const Text('Today'),
              onPressed: () => _presetDays(1),
            ),
            ActionChip(
              label: const Text('Last 7 days'),
              onPressed: () => _presetDays(7),
            ),
            ActionChip(
              avatar: const Icon(Icons.date_range, size: 18),
              label: const Text('Choose dates'),
              onPressed: _pickDates,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          data.filter.description,
          key: const Key('date-filter-description'),
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Include records with unknown time'),
          value: data.filter.includeUnknown,
          onChanged: (value) => data.setFilter(
            RecordFilter(
              start: data.filter.start,
              endExclusive: data.filter.endExclusive,
              includeUnknown: value,
            ),
          ),
        ),
        Text(
          'Showing ${visible.length} records · CSV exports the same selection',
          key: const Key('visible-count'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        if (visible.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: Column(
              children: [
                const Icon(Icons.inbox_outlined, size: 44),
                const SizedBox(height: 12),
                Text(
                  data.records.isEmpty
                      ? 'No records yet'
                      : 'No records match these filters',
                ),
              ],
            ),
          )
        else
          for (final record in visible) _recordTile(record),
      ],
    );
  }

  Widget _recordTile(MedicationRecord record) {
    final time = record.localOccurredAt;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: Icon(
          record.eventType == 2
              ? Icons.error_outline
              : Icons.receipt_long_outlined,
          color: record.eventType == 2
              ? Theme.of(context).colorScheme.tertiary
              : Theme.of(context).colorScheme.primary,
        ),
        title: Text(record.eventLabel),
        subtitle: Text(
          '${time == null ? 'Unknown time' : '${dateLabel(time)} ${timeLabel(time)}'}\n${record.deviceId} · ${record.deviceFileId ?? '#${record.seq}'}',
        ),
        isThreeLine: true,
        trailing: const Icon(Icons.chevron_right),
        onTap: () => showModalBottomSheet<void>(
          context: context,
          showDragHandle: true,
          isScrollControlled: true,
          builder: (context) => SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    record.eventLabel,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 16),
                  for (final entry in <String, String>{
                    'Source': data.source.label,
                    'Device ID': record.deviceId,
                    if (record.isTimestampRecord) ...{
                      'Device file': record.deviceFileId!,
                      'Original timestamp': record.rawTimestampText!,
                      'Time basis':
                          'Device calendar time; original timezone not supplied',
                      'Received on phone': record.receivedAt!
                          .toLocal()
                          .toString(),
                    } else
                      'Sequence': '${record.seq}',
                    'Local time': time == null
                        ? 'Unknown time; excluded from daily counts'
                        : '${dateLabel(time)} ${timeLabel(time)}',
                    'UTC time':
                        record.occurredAt?.toIso8601String() ??
                        'Not supplied by device',
                    if (!record.isTimestampRecord) ...{
                      'Duration': '${record.durationMs} ms',
                      'Pressure': '${record.pressurePeakPa} Pa',
                      'Confidence': '${record.confidence} / 100',
                      'Battery voltage': '${record.batteryMv} mV',
                    } else
                      'Measurements': 'Not supplied by timestamp-only firmware',
                    'Protocol': record.isTimestampRecord
                        ? 'P01 / TIME1'
                        : '${record.protocolVersion}',
                    'Algorithm':
                        record.algorithmVersion ?? 'Not provided by device',
                  }.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text('${entry.key}：${entry.value}'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
