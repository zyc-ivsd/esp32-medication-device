import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../assistant/assistant_page.dart';
import '../assistant/rules/observation_rules.dart';
import '../database/record_repository.dart';
import '../models/invalid_use_rule.dart';
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

/// 概览页四张统计卡中，当前被展开成详情的那一张。
/// 目前只有 [today] 实现了详情视图；其余几项留作后续扩展。
enum _ExpandedMetric { none, today, last7Days, invalidUses, allSavedRecords }

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
  _ExpandedMetric _expanded = _ExpandedMetric.none;

  /// 卡片之间的间距。
  static const double _metricSpacing = 12;

  /// 未展开时单张统计卡的实际高度，随字体缩放变化，由隐藏探针测量得到。
  final GlobalKey _metricProbeKey = GlobalKey();
  double? _measuredMetricHeight;

  /// 「Uses today」详情卡当前展示的日期（本地日历日，无时分秒）。
  late DateTime _selectedDay;

  /// 用户在本次会话里关掉提醒卡片后不再显示；重新打开 App 会重新评估。
  bool _alertDismissed = false;
  RecordController get data => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selectedDay = _todayLocalDate();
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
            applySuspectedInvalidUseRule(await repo.readAll()),
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
        title: const Text('AeroEase'),
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureMetricHeight());
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
        // 隐藏探针：测量「未展开的整个 metric 区域」的实际总高度（两行/一行各自等高、
        // 行间可能不同高），随字体缩放自适应，不占布局空间。
        SizedBox(
          height: 0,
          child: OverflowBox(
            alignment: Alignment.topLeft,
            maxHeight: double.infinity,
            child: Opacity(
              opacity: 0,
              child: IgnorePointer(
                child: _collapsedMetrics(summary, probeKey: _metricProbeKey),
              ),
            ),
          ),
        ),
        if (_expanded != _ExpandedMetric.none)
          _expandedLayout(summary)
        else ...[
          _collapsedMetrics(summary),
          const SizedBox(height: 12),
          if (summary != null && summary.total > 0) ...[
            // 「Last 7 days」周柱状图已改为点击卡片展开查看，此处暂时隐藏。
            // _weekChart(summary),
            _notes(summary),
            const SizedBox(height: 12),
          ],
          _deviceConnection(summary),
        ],
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

  /// 「日历 + 矢量数字 7」组合图标。
  /// Material Icons 既无「日历+7」现成图标，也无纯「7」数字图标，
  /// 故用 CustomPaint 画一个矢量 7（无字体依赖），叠加在日历上。
  Widget _calendarSevenIcon(double size, Color color) => SizedBox(
    width: size,
    height: size,
    child: Stack(
      alignment: Alignment.center,
      children: [
        Icon(Icons.calendar_today_outlined, size: size, color: color),
        Positioned(
          top: size * 0.40 + 2,
          child: CustomPaint(
            size: Size(size * 0.30, size * 0.34),
            painter: _SevenDigitPainter(color),
          ),
        ),
      ],
    ),
  );

  /// 未展开的 metric 区域：按列数分成若干行，行内等高、行间 12 间距。
  /// [probeKey] 用于隐藏探针测量整个区域的实际总高度。
  Widget _collapsedMetrics(RecordSummary? summary, {Key? probeKey}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 650 ? 4 : 2;
        final metrics = <Widget>[
          _metric(
            'Uses today',
            summary?.todayCount,
            'uses',
            Icons.today_outlined,
            onTap: () => _switchTo(_ExpandedMetric.today),
          ),
          _metric(
            'Uses in 7 days',
            summary?.last7DaysCount,
            'uses',
            Icons.calendar_month_outlined,
            onTap: () => _switchTo(_ExpandedMetric.last7Days),
            iconBuilder: _calendarSevenIcon,
          ),
          _metric(
            'Invalid uses (7 days)',
            summary?.invalidEventCount,
            'records',
            Icons.info_outline,
            onTap: () => _switchTo(_ExpandedMetric.invalidUses),
          ),
          _metric(
            'All saved records',
            summary?.total,
            'records',
            Icons.storage_outlined,
            onTap: () => _switchTo(_ExpandedMetric.allSavedRecords),
          ),
        ];
        final rows = <Widget>[];
        for (var i = 0; i < metrics.length; i += columns) {
          final rowItems = <Widget>[];
          for (var j = i; j < i + columns && j < metrics.length; j++) {
            if (j > i) rowItems.add(const SizedBox(width: 12));
            rowItems.add(Expanded(child: metrics[j]));
          }
          rows.add(
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: rowItems,
              ),
            ),
          );
          if (i + columns < metrics.length) {
            rows.add(const SizedBox(height: _metricSpacing));
          }
        }
        return Column(
          key: probeKey,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        );
      },
    );
  }

  Widget _metric(
    String title,
    int? count,
    String unit,
    IconData icon, {
    Key? key,
    VoidCallback? onTap,
    Widget Function(double size, Color color)? iconBuilder,
  }) => Card(
    key: key,
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            iconBuilder?.call(20, Theme.of(context).colorScheme.primary) ??
                Icon(
                  icon,
                  size: 20,
                  color: Theme.of(context).colorScheme.primary,
                ),
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

  /// 本地「今天」的日历日（去时分秒）。
  DateTime _todayLocalDate() {
    final now = data.clock().toLocal();
    return DateTime(now.year, now.month, now.day);
  }

  /// 测量隐藏探针（未展开统计卡）的实际高度，随字体缩放自适应。
  void _measureMetricHeight() {
    final renderObject = _metricProbeKey.currentContext?.findRenderObject();
    if (renderObject is RenderBox && renderObject.hasSize) {
      final height = renderObject.size.height;
      if (mounted && height != _measuredMetricHeight) {
        setState(() => _measuredMetricHeight = height);
      }
    }
  }

  List<MedicationRecord> _todayUses() => _usesOnDay(_selectedDay);

  /// 某一天（本地日历日）的有效用药记录，按时间升序。
  List<MedicationRecord> _usesOnDay(DateTime day) {
    final tomorrow = DateTime(day.year, day.month, day.day + 1);
    final uses = <MedicationRecord>[];
    for (final record in data.records) {
      if (record.eventType != 1) continue;
      final time = record.localOccurredAt;
      if (time == null) continue;
      if (time.isBefore(day) || !time.isBefore(tomorrow)) continue;
      uses.add(record);
    }
    uses.sort((a, b) => a.localOccurredAt!.compareTo(b.localOccurredAt!));
    return uses;
  }

  Future<void> _pickDay() async {
    final chosen = await showDatePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2106, 2, 7),
      initialDate: _selectedDay,
      helpText: 'Choose date',
    );
    if (chosen != null && mounted) {
      setState(() => _selectedDay = chosen);
    }
  }

  /// 近 7 天（含今天）逐日疑似无效记录数，口径与 summary.invalidEventCount 一致。
  List<DailyCount> _invalidUsesByDay() {
    final now = data.clock().toLocal();
    final today = DateTime(now.year, now.month, now.day);
    final start = DateTime(today.year, today.month, today.day - 6);
    final days = List.generate(
      7,
      (i) => DateTime(start.year, start.month, start.day + i),
    );
    final counts = List.filled(7, 0);
    for (final record in data.records) {
      if (record.eventType != 2) continue;
      final time = record.localOccurredAt;
      if (time == null || time.isAfter(now)) continue;
      final index = days.indexWhere(
        (d) =>
            d.year == time.year && d.month == time.month && d.day == time.day,
      );
      if (index >= 0) counts[index]++;
    }
    return [for (var i = 0; i < 7; i++) DailyCount(days[i], counts[i])];
  }

  /// 近 7 天（含今天）逐日记录时间，口径与 [RecordSummary] 的逐日计数一致：
  /// [invalid] 为 true 时取疑似无效记录，否则取有效用药记录；未知时间、
  /// 未来时间和窗口外的记录都不进入柱子，也不进入点击后的时间列表。
  List<List<DateTime>> _timesByDay({required bool invalid}) {
    final now = data.clock().toLocal();
    final today = DateTime(now.year, now.month, now.day);
    final start = DateTime(today.year, today.month, today.day - 6);
    final days = List.generate(
      7,
      (i) => DateTime(start.year, start.month, start.day + i),
    );
    final buckets = List.generate(7, (_) => <DateTime>[]);
    for (final record in data.records) {
      if (invalid ? record.eventType != 2 : record.eventType != 1) continue;
      final time = record.localOccurredAt;
      if (time == null || time.isAfter(now)) continue;
      final index = days.indexWhere(
        (day) =>
            day.year == time.year &&
            day.month == time.month &&
            day.day == time.day,
      );
      if (index >= 0) buckets[index].add(time);
    }
    return buckets;
  }

  /// 卡片下方的文字说明（合并为单个 Text，换行分隔），展开前后均保留。
  Widget _notes(RecordSummary summary) => Text(
    'Tap a card to see details.\n'
    'Counts use the recorded calendar date. ${summary.unknownTimeCount} unknown-time and '
    '${summary.futureTimeCount} future-time records are excluded from daily counts.',
    style: Theme.of(context).textTheme.bodySmall,
  );

  /// 根据 [_expanded] 分发到对应统计卡的详情视图。
  Widget _expandedLayout(RecordSummary? summary) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 650 ? 4 : 2;
        final compact = columns == 2;
        final detail = switch (_expanded) {
          _ExpandedMetric.today => _todayDetailCard(
            _todayUses(),
            compact: compact,
          ),
          _ExpandedMetric.last7Days => _last7DaysDetailCard(
            summary,
            compact: compact,
          ),
          _ExpandedMetric.invalidUses => _invalidDetailCard(
            summary,
            compact: compact,
          ),
          _ExpandedMetric.allSavedRecords => _allRecordsDetailCard(
            summary,
            compact: compact,
          ),
          _ExpandedMetric.none => null,
        };
        if (detail == null) return const SizedBox.shrink();
        // 展开高度 = 未展开整个 metric 区域的实际总高度（探针实测，含两行各自高度与行间距）。
        final targetHeight = _measuredMetricHeight ?? 118;
        final row = compact
            ? SizedBox(
                height: targetHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: detail),
                    const SizedBox(width: 12),
                    _metricsSidebar(summary, compact: true),
                  ],
                ),
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: detail),
                  const SizedBox(width: 12),
                  _metricsSidebar(summary),
                ],
              );
        return Column(
          children: [
            row,
            const SizedBox(height: 12),
            if (summary != null && summary.total > 0) ...[
              _notes(summary),
              const SizedBox(height: 12),
            ],
            _deviceConnection(summary),
          ],
        );
      },
    );
  }

  /// 详情卡片头部：图标 + 标题 + 可选右侧计数 + 可选额外按钮 + 关闭按钮 + 可选副标题。
  Widget _detailCardHeader({
    required IconData icon,
    required String title,
    String? trailing,
    String? subtitle,
    Widget? action,
    Widget Function(double size, Color color)? iconBuilder,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            iconBuilder?.call(22, scheme.primary) ??
                Icon(icon, size: 22, color: scheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            if (trailing != null)
              Text(trailing, style: Theme.of(context).textTheme.labelMedium),
            if (action != null) action,
            IconButton(
              onPressed: () => setState(() => _expanded = _ExpandedMetric.none),
              tooltip: 'Close detail',
              icon: const Icon(Icons.close),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    );
  }

  Widget _todayDetailCard(List<MedicationRecord> uses, {bool compact = false}) {
    final isToday =
        _selectedDay.year == _todayLocalDate().year &&
        _selectedDay.month == _todayLocalDate().month &&
        _selectedDay.day == _todayLocalDate().day;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _detailCardHeader(
              icon: Icons.today_outlined,
              title: isToday ? 'Uses today' : dateLabel(_selectedDay),
              trailing: '${uses.length} uses',
              subtitle:
                  'Tap the calendar button to choose a date · scroll to see all hours · tap a bar to see times',
              action: IconButton(
                onPressed: _pickDay,
                tooltip: 'Choose date',
                icon: const Icon(Icons.calendar_today_outlined),
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(height: 12),
            if (compact)
              Expanded(child: _todayBarChart(uses, compact: true))
            else
              _todayBarChart(uses),
          ],
        ),
      ),
    );
  }

  Widget _last7DaysDetailCard(RecordSummary? summary, {bool compact = false}) {
    final days = summary?.days ?? const <DailyCount>[];
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _detailCardHeader(
              icon: Icons.calendar_month_outlined,
              title: 'Uses in 7 days',
              trailing: '${summary?.last7DaysCount ?? '—'} uses',
              subtitle:
                  'Daily counts for the last 7 days · tap a bar to see times',
              iconBuilder: _calendarSevenIcon,
            ),
            const SizedBox(height: 12),
            if (compact)
              Expanded(
                child: _dailyBarChart(
                  days,
                  compact: true,
                  timesByDay: _timesByDay(invalid: false),
                ),
              )
            else
              _dailyBarChart(days, timesByDay: _timesByDay(invalid: false)),
          ],
        ),
      ),
    );
  }

  Widget _invalidDetailCard(RecordSummary? summary, {bool compact = false}) {
    final days = _invalidUsesByDay();
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _detailCardHeader(
              icon: Icons.info_outline,
              title: 'Invalid uses (7 days)',
              trailing: '${summary?.invalidEventCount ?? '—'} records',
              subtitle:
                  'Daily counts for the last 7 days · tap a bar to see times',
            ),
            const SizedBox(height: 12),
            if (compact)
              Expanded(
                child: _dailyBarChart(
                  days,
                  compact: true,
                  timesByDay: _timesByDay(invalid: true),
                  timeSheetLabel: 'invalid uses',
                ),
              )
            else
              _dailyBarChart(
                days,
                timesByDay: _timesByDay(invalid: true),
                timeSheetLabel: 'invalid uses',
              ),
          ],
        ),
      ),
    );
  }

  Widget _allRecordsDetailCard(RecordSummary? summary, {bool compact = false}) {
    final recent = data.records
        .where((record) => record.localOccurredAt != null)
        .toList(growable: false);
    recent.sort((a, b) => b.localOccurredAt!.compareTo(a.localOccurredAt!));
    final visible = recent.take(100).toList(growable: false);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _detailCardHeader(
              icon: Icons.storage_outlined,
              title: 'All saved records',
              trailing: '${summary?.total ?? '—'} records',
            ),
            const SizedBox(height: 12),
            if (compact)
              Expanded(child: _recordsList(visible, compact: true))
            else
              _recordsList(visible, compact: false),
          ],
        ),
      ),
    );
  }

  Widget _recordsList(List<MedicationRecord> recent, {required bool compact}) {
    if (recent.isEmpty) {
      return const Center(child: Text('No records with a known time'));
    }
    final scheme = Theme.of(context).colorScheme;
    final list = ListView.separated(
      itemCount: recent.length,
      separatorBuilder: (_, index) {
        final isNewDay =
            recent[index].localOccurredAt!.year !=
                recent[index + 1].localOccurredAt!.year ||
            recent[index].localOccurredAt!.month !=
                recent[index + 1].localOccurredAt!.month ||
            recent[index].localOccurredAt!.day !=
                recent[index + 1].localOccurredAt!.day;
        if (isNewDay) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Divider(height: 1, thickness: 1, color: scheme.outline),
              const SizedBox(height: 2),
              Divider(height: 1, thickness: 1, color: scheme.outline),
            ],
          );
        }
        return Divider(height: 1, thickness: 1, color: scheme.outlineVariant);
      },
      itemBuilder: (context, index) {
        final record = recent[index];
        final time = record.localOccurredAt!;
        final invalid = record.eventType == 2;
        final body = Theme.of(context).textTheme.bodyMedium;
        final subtle = Theme.of(context).textTheme.bodySmall?.copyWith(
          // Two steps smaller than the timestamp, as a lightweight hint.
          fontSize: (body?.fontSize ?? 14) - 2,
          color: scheme.outline,
        );
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  '${dateLabel(time)} ${timeLabel(time)}',
                  style: body?.copyWith(color: invalid ? scheme.outline : null),
                ),
              ),
              if (invalid) ...[
                const SizedBox(width: 6),
                Text('(invalid)', style: subtle),
              ],
            ],
          ),
        );
      },
    );
    return compact ? list : SizedBox(height: 240, child: list);
  }

  Widget _todayBarChart(List<MedicationRecord> uses, {bool compact = false}) {
    final buckets = List<List<DateTime>>.generate(24, (_) => <DateTime>[]);
    for (final record in uses) {
      final time = record.localOccurredAt!;
      buckets[time.hour].add(time);
    }
    final max = buckets.fold<int>(
      1,
      (current, bucket) => math.max(current, bucket.length),
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < buckets.length; i++)
            _barColumn(i, buckets[i], max, compact: compact),
        ],
      ),
    );
  }

  Widget _barColumn(
    int index,
    List<DateTime> times,
    int max, {
    bool compact = false,
  }) {
    final count = times.length;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: '${_bucketRange(index)}, $count uses',
      button: true,
      child: InkWell(
        onTap: count == 0 ? null : () => _showBucketTimes(index, times),
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 25,
          child: Column(
            children: [
              Text(
                '$count',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 4),
              _barArea(count, max, compact, 14),
              const SizedBox(height: 6),
              Text(
                '$index',
                style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 柱体区：compact 时用 Expanded 自适应剩余高度（柱体按比例压缩），
  /// 非 compact 时固定 120 高。
  Widget _barArea(
    int count,
    int max,
    bool compact,
    double barWidth, {
    double minBarHeight = 8,
  }) {
    final scheme = Theme.of(context).colorScheme;
    Widget bar(double area) => Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        width: barWidth,
        height: count == 0 ? 3.0 : math.max(minBarHeight, count / max * area),
        decoration: BoxDecoration(
          color: count == 0 ? scheme.surfaceContainerHighest : scheme.primary,
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
    if (compact) {
      return Expanded(
        child: LayoutBuilder(
          builder: (context, constraints) =>
              bar(math.max(1, constraints.maxHeight)),
        ),
      );
    }
    return SizedBox(height: 120, child: bar(120));
  }

  String _bucketRange(int index) => '$index–${index + 1}';

  void _showBucketTimes(int index, List<DateTime> times) {
    final sorted = List<DateTime>.of(times)..sort();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          children: [
            Text(
              '${_bucketRange(index)} · ${sorted.length} uses',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            for (final time in sorted)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.schedule),
                title: Text(timeLabel(time)),
              ),
          ],
        ),
      ),
    );
  }

  /// 按日柱状图：每根柱代表一天，柱顶次数、柱底月/日。
  /// [timesByDay] 与 [days] 一一对应；有数据时点击柱子可查看当天具体时间。
  Widget _dailyBarChart(
    List<DailyCount> days, {
    bool compact = false,
    List<List<DateTime>>? timesByDay,
    String timeSheetLabel = 'medication uses',
  }) {
    final max = days.fold<int>(1, (m, d) => math.max(m, d.count));
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < days.length; i++)
          Expanded(
            child: Semantics(
              label:
                  '${dateLabel(days[i].day)}, ${days[i].count} $timeSheetLabel',
              button: days[i].count > 0 && timesByDay != null,
              excludeSemantics: true,
              child: InkWell(
                key: ValueKey('daily-bar-$i'),
                onTap: days[i].count == 0 || timesByDay == null
                    ? null
                    : () => _showDayTimes(
                        days[i].day,
                        timesByDay[i],
                        timeSheetLabel,
                      ),
                borderRadius: BorderRadius.circular(4),
                child: Column(
                  children: [
                    Text('${days[i].count}'),
                    const SizedBox(height: 6),
                    _barArea(days[i].count, max, compact, 18, minBarHeight: 3),
                    const SizedBox(height: 8),
                    Text(
                      '${days[i].day.month}/${days[i].day.day}',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 点击某一天的柱子后，按时间顺序列出当天的具体记录时间。
  void _showDayTimes(DateTime day, List<DateTime> times, String label) {
    final sorted = List<DateTime>.of(times)..sort();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          children: [
            Text(
              '${dateLabel(day)} · ${sorted.length} $label',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            if (sorted.isEmpty)
              const Text('No records on this day')
            else
              for (final time in sorted)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.schedule),
                  title: Text(timeLabelWithSeconds(time)),
                ),
          ],
        ),
      ),
    );
  }

  Widget _metricsSidebar(RecordSummary? summary, {bool compact = false}) {
    final items = <Widget>[];
    void add(
      _ExpandedMetric metric,
      IconData icon,
      String label, {
      Widget Function(double size, Color color)? iconBuilder,
    }) {
      final isActive = _expanded == metric;
      final item = _sidebarItem(
        icon,
        label,
        iconBuilder: iconBuilder,
        compact: compact,
        active: isActive,
        onTap: isActive ? null : () => _switchTo(metric),
      );
      items.add(compact ? Expanded(child: item) : item);
      items.add(const SizedBox(height: 12));
    }

    add(
      _ExpandedMetric.today,
      Icons.today_outlined,
      'Uses today: ${summary?.todayCount ?? '—'} uses',
    );
    add(
      _ExpandedMetric.last7Days,
      Icons.calendar_month_outlined,
      'Uses in 7 days: ${summary?.last7DaysCount ?? '—'} uses',
      iconBuilder: _calendarSevenIcon,
    );
    add(
      _ExpandedMetric.invalidUses,
      Icons.info_outline,
      'Invalid uses (7 days): ${summary?.invalidEventCount ?? '—'} records',
    );
    add(
      _ExpandedMetric.allSavedRecords,
      Icons.storage_outlined,
      'All saved records: ${summary?.total ?? '—'} records',
    );
    if (items.isNotEmpty) items.removeLast();
    return Column(
      mainAxisSize: compact ? MainAxisSize.max : MainAxisSize.min,
      children: items,
    );
  }

  void _switchTo(_ExpandedMetric metric) {
    setState(() {
      _expanded = metric;
      if (metric == _ExpandedMetric.today) _selectedDay = _todayLocalDate();
    });
  }

  Widget _sidebarItem(
    IconData icon,
    String tooltip, {
    Widget Function(double size, Color color)? iconBuilder,
    bool compact = false,
    bool active = false,
    VoidCallback? onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final color = scheme.primary;
    final background = active
        ? scheme.tertiaryContainer
        : scheme.surfaceContainerHighest;
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 64,
        height: compact ? null : 56,
        child: Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          color: background,
          child: InkWell(
            onTap: onTap,
            child: Center(
              child:
                  iconBuilder?.call(24, color) ??
                  Icon(icon, size: 24, color: color),
            ),
          ),
        ),
      ),
    );
  }

  Widget _deviceConnection(RecordSummary? summary) {
    final built = widget.connectionBuilder?.call(
      context,
      data.deviceRepository,
    );
    if (built != null) return built;
    return Card(
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
    );
  }

  // 「Last 7 days」周柱状图已隐藏（改为点击卡片展开查看），保留方法以备后续恢复。
  // ignore: unused_element
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
                          'Device UTC seconds (64-bit hex); shown in your phone timezone',
                      'Received on phone': record.receivedAt!
                          .toLocal()
                          .toString(),
                    } else
                      'Sequence': '${record.seq}',
                    'Local time': time == null
                        ? 'Unknown time; excluded from daily counts'
                        : '${dateLabel(time)} ${timeLabel(time)}',
                    'UTC time':
                        (record.isTimestampRecord
                                ? parseDeviceTimestamp(record.rawTimestampText!)
                                : record.occurredAt)
                            ?.toIso8601String() ??
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
                      child: Text('${entry.key}: ${entry.value}'),
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

/// 矢量数字「7」：一条横线 + 一条斜线，圆角笔画，避免字体渲染差异。
class _SevenDigitPainter extends CustomPainter {
  const _SevenDigitPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final strokeWidth = size.height * 0.22;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = strokeWidth;

    final w = size.width;
    final h = size.height;
    final half = strokeWidth / 2;
    final path = Path()
      ..moveTo(half, half)
      ..lineTo(w - half, half)
      ..quadraticBezierTo(w * 0.5, h * 0.50, w * 0.30, h - half);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SevenDigitPainter oldDelegate) =>
      oldDelegate.color != color;
}
