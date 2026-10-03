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

/// B supplies BLE UI here. Always receives the DEVICE repository, even while
/// the user is browsing demo data. Never write device events to the demo store.
typedef DeviceConnectionBuilder = Widget Function(
    BuildContext, RecordRepository);
typedef ExportRecords = Future<void> Function(
    List<MedicationRecord>, RecordSource, Rect);

class HomePage extends StatefulWidget {
  const HomePage(
      {super.key,
      required this.controller,
      this.connectionBuilder,
      this.exportRecords});
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

  Future<void> _importDemo() async {
    setState(() => _working = true);
    try {
      final count = await data.importDemo();
      _message(count == 0 ? '已载入保存的演示数据，没有重复添加。' : '已载入 $count 条演示记录。');
    } catch (_) {
      _message('演示数据保存失败，请重试。设备记录未受影响。');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _clearDemo() async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('清空演示数据？'),
                content: const Text('只清空合成的演示记录。设备记录会保留。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('清空'))
                ]));
    if (confirmed != true || !mounted) return;
    setState(() => _working = true);
    try {
      await data.resetDemo();
      _message('演示数据已清空，可以重新载入。');
    } catch (_) {
      _message('清空失败，请重试。');
    } finally {
      if (mounted) setState(() => _working = false);
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
        await CsvExportService()
            .share(records: snapshot, source: source, origin: origin);
      }
    } catch (_) {
      _message('无法打开导出分享，请重试。');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _openAssistant() async {
    final repo = data.repository;
    final source = data.source;
    final initial = data.summary;
    if (initial == null) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => AssistantPage(
            assistantContext: initial.toAssistantContext(source),
            contextLoader: () async => RecordSummary.calculate(
                    await repo.readAll(),
                    now: data.clock(),
                    lastSyncAt: await repo.lastSyncAt())
                .toAssistantContext(source))));
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
                start: start, end: DateTime(end.year, end.month, end.day - 1)),
        helpText: '筛选记录日期',
        saveText: '确定');
    if (chosen != null && mounted) {
      data.setFilter(RecordFilter(
          start: chosen.start,
          endExclusive:
              DateTime(chosen.end.year, chosen.end.month, chosen.end.day + 1),
          includeUnknown: data.filter.includeUnknown));
    }
  }

  void _presetDays(int? days) {
    final now = data.clock().toLocal();
    data.setFilter(RecordFilter(
        start: days == null
            ? null
            : DateTime(now.year, now.month, now.day - days + 1),
        endExclusive:
            days == null ? null : DateTime(now.year, now.month, now.day + 1),
        includeUnknown: data.filter.includeUnknown));
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: data,
      builder: (context, _) => Scaffold(
          appBar: AppBar(title: const Text('用药装置'), actions: [
            // 助手是核心入口，不能只藏在滚动区底部的按钮里。
            IconButton(
                onPressed:
                    data.summary == null || data.loading ? null : _openAssistant,
                tooltip: '记录助手',
                icon: const Icon(Icons.chat_bubble_outline)),
            IconButton(
                onPressed: data.loading ? null : data.refresh,
                tooltip: '刷新记录',
                icon: const Icon(Icons.refresh)),
            if (data.source == RecordSource.demo)
              PopupMenuButton<String>(
                  enabled: !_working,
                  tooltip: '演示选项',
                  onSelected: (_) => _clearDemo(),
                  itemBuilder: (_) => [
                        const PopupMenuItem(
                            value: 'clear', child: Text('清空演示数据'))
                      ]),
          ]),
          body: SafeArea(
              top: false,
              child: Center(
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 880),
                      child: Column(children: [
                        Padding(
                            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                            child: SizedBox(
                                width: double.infinity,
                                child: SegmentedButton<RecordSource>(
                                    segments: const [
                                      ButtonSegment(
                                          value: RecordSource.device,
                                          label: Text('设备记录'),
                                          icon: Icon(Icons.bluetooth)),
                                      ButtonSegment(
                                          value: RecordSource.demo,
                                          label: Text('演示数据'),
                                          icon: Icon(Icons.science_outlined)),
                                    ],
                                    selected: {
                                      data.source
                                    },
                                    onSelectionChanged: _working
                                        ? null
                                        : (value) =>
                                            data.selectSource(value.single)))),
                        if (data.source == RecordSource.demo)
                          Container(
                              width: double.infinity,
                              margin:
                                  const EdgeInsets.symmetric(horizontal: 20),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .tertiaryContainer,
                                  borderRadius: BorderRadius.circular(12)),
                              child: Text('当前为演示数据，与设备记录分开保存。',
                                  style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onTertiaryContainer))),
                        if (data.loading)
                          const LinearProgressIndicator(minHeight: 2),
                        Expanded(
                            child: data.error != null
                                ? _errorView()
                                : RefreshIndicator(
                                    onRefresh: data.refresh,
                                    child:
                                        _tab == 0 ? _overview() : _history())),
                      ])))),
          bottomNavigationBar: NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (index) => setState(() => _tab = index),
              destinations: const [
                NavigationDestination(
                    icon: Icon(Icons.dashboard_outlined),
                    selectedIcon: Icon(Icons.dashboard),
                    label: '概览'),
                NavigationDestination(icon: Icon(Icons.history), label: '历史记录'),
              ])));

  /// 与助手共用同一套规则：概览页只负责把 attention 级观察提前告诉用户，
  /// 自己不再实现一份判断逻辑。
  List<AssistantObservation> _attentionObservations() {
    final summary = data.summary;
    if (summary == null) return const [];
    return evaluateObservations(summary.toAssistantContext(data.source),
            now: data.clock())
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
            child:
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.notifications_active_outlined,
                  size: 22, color: scheme.onTertiaryContainer),
              const SizedBox(width: 12),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text('需要留意 ${observations.length} 项',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: scheme.onTertiaryContainer)),
                    const SizedBox(height: 8),
                    for (final observation in observations)
                      Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text('· ${observation.text}',
                              style: TextStyle(
                                  color: scheme.onTertiaryContainer))),
                    Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                            onPressed: _openAssistant,
                            child: const Text('问问记录助手'))),
                  ])),
              IconButton(
                  onPressed: () => setState(() => _alertDismissed = true),
                  tooltip: '本次不再显示',
                  icon: const Icon(Icons.close)),
            ])));
  }

  Widget _errorView() => Center(
      child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.storage_outlined, size: 40),
            const SizedBox(height: 12),
            Text(data.error!),
            TextButton(onPressed: data.refresh, child: const Text('重试'))
          ])));

  Widget _overview() {
    final summary = data.summary;
    final alerts = _attentionObservations();
    final showAlerts = !_alertDismissed && alerts.isNotEmpty;
    return ListView(
        padding: const EdgeInsets.all(20),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Text(data.source == RecordSource.demo ? '先体验，再连接' : '让每次记录更清楚',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          const Text('记录保存在本机 · 无需联网查看'),
          const SizedBox(height: 20),
          if (showAlerts) ...[
            _alertCard(alerts),
            const SizedBox(height: 20)
          ],
          LayoutBuilder(builder: (context, constraints) {
            final columns = constraints.maxWidth >= 650 ? 4 : 2;
            final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
            return Wrap(spacing: 12, runSpacing: 12, children: [
              _metric('今日使用动作', summary?.todayCount, '次', Icons.today_outlined,
                  width),
              _metric('近 7 天使用动作', summary?.last7DaysCount, '次',
                  Icons.calendar_month_outlined, width),
              _metric('近 7 天疑似无效', summary?.invalidEventCount, '条',
                  Icons.info_outline, width),
              _metric(
                  '全部本地记录', summary?.total, '条', Icons.storage_outlined, width)
            ]);
          }),
          const SizedBox(height: 20),
          if (summary != null && summary.total > 0) ...[
            _weekChart(summary),
            const SizedBox(height: 12),
            Text(
                '按本地日期统计使用动作。时间未知 ${summary.unknownTimeCount} 条，未来时间 '
                '${summary.futureTimeCount} 条，均不计入按日统计。',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 20)
          ],
          if (widget.connectionBuilder != null || data.source == RecordSource.device)
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
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                    const Text('暂无设备连接',
                                        style: TextStyle(
                                            fontWeight: FontWeight.bold)),
                                    const SizedBox(height: 6),
                                    const Text('连接并同步设备后，记录会显示在这里。'),
                                    if (summary?.lastSyncAt != null)
                                      Text(
                                          '上次同步：${dateLabel(summary!.lastSyncAt!.toLocal())} '
                                          '${timeLabel(summary.lastSyncAt!.toLocal())}')
                                  ]))
                            ]))),
          const SizedBox(height: 12),
          if ((summary?.total ?? 0) == 0)
            const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text('还没有记录。记录助手需要有记录才有内容可解释，可以先载入演示数据看看。')),
          if (data.source == RecordSource.device || (summary?.total ?? 0) == 0)
            OutlinedButton.icon(
                onPressed: _working ? null : _importDemo,
                icon: const Icon(Icons.play_circle_outline),
                label: const Text('载入演示数据')),
          const SizedBox(height: 12),
          FilledButton.icon(
              onPressed:
                  summary == null || data.loading ? null : _openAssistant,
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('问问记录助手')),
          const SizedBox(height: 12),
          Text('助手使用本地规则解释统计。设备事件不等于确认服药，也不用于计算药量。',
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ]);
  }

  Widget _metric(
          String title, int? count, String unit, IconData icon, double width) =>
      SizedBox(
          width: width,
          child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(icon,
                            size: 20,
                            color: Theme.of(context).colorScheme.primary),
                        const SizedBox(height: 10),
                        Text(title,
                            style: Theme.of(context).textTheme.labelMedium),
                        const SizedBox(height: 8),
                        Text('${count ?? '—'} $unit',
                            style: Theme.of(context)
                                .textTheme
                                .headlineSmall
                                ?.copyWith(fontWeight: FontWeight.bold)),
                      ]))));
  Widget _weekChart(RecordSummary summary) {
    final max =
        summary.days.fold<int>(1, (max, day) => math.max(max, day.count));
    return Card(
        margin: EdgeInsets.zero,
        child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('最近 7 天',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                for (final day in summary.days)
                  Expanded(
                      child: Semantics(
                          label: '${dateLabel(day.day)}，${day.count} 次使用动作',
                          excludeSemantics: true,
                          child: Column(children: [
                            Text('${day.count}'),
                            const SizedBox(height: 6),
                            SizedBox(
                                height: 70,
                                child: Align(
                                    alignment: Alignment.bottomCenter,
                                    child: Container(
                                        width: 18,
                                        height:
                                            math.max(3, day.count / max * 70),
                                        decoration: BoxDecoration(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primary,
                                            borderRadius:
                                                BorderRadius.circular(4))))),
                            const SizedBox(height: 8),
                            Text('${day.day.month}/${day.day.day}',
                                style: const TextStyle(fontSize: 11)),
                          ])))
              ])
            ])));
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
                Text('历史记录', style: Theme.of(context).textTheme.headlineSmall),
                Builder(
                    builder: (buttonContext) => FilledButton.tonalIcon(
                        onPressed: _working || data.loading || visible.isEmpty
                            ? null
                            : () => _export(buttonContext),
                        icon: const Icon(Icons.ios_share),
                        label: const Text('导出 CSV')))
              ]),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 4, children: [
            ActionChip(
                label: const Text('全部日期'), onPressed: () => _presetDays(null)),
            ActionChip(
                label: const Text('今天'), onPressed: () => _presetDays(1)),
            ActionChip(
                label: const Text('近 7 天'), onPressed: () => _presetDays(7)),
            ActionChip(
                avatar: const Icon(Icons.date_range, size: 18),
                label: const Text('选择日期'),
                onPressed: _pickDates)
          ]),
          const SizedBox(height: 8),
          Text(data.filter.description,
              key: const Key('date-filter-description')),
          SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('同时显示时间未知的记录'),
              value: data.filter.includeUnknown,
              onChanged: (value) => data.setFilter(RecordFilter(
                  start: data.filter.start,
                  endExclusive: data.filter.endExclusive,
                  includeUnknown: value))),
          Text('当前显示 ${visible.length} 条 · CSV 导出相同记录',
              key: const Key('visible-count'),
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          if (visible.isEmpty)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Column(children: [
                  const Icon(Icons.inbox_outlined, size: 44),
                  const SizedBox(height: 12),
                  Text(data.records.isEmpty ? '还没有记录' : '这个筛选条件下没有记录'),
                  if (data.source == RecordSource.demo && data.records.isEmpty)
                    TextButton(
                        onPressed: _working ? null : _importDemo,
                        child: const Text('载入演示数据'))
                ]))
          else
            for (final record in visible) _recordTile(record),
        ]);
  }

  Widget _recordTile(MedicationRecord record) {
    final time = record.occurredAt?.toLocal();
    return Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            leading: Icon(
                record.eventType == 2
                    ? Icons.error_outline
                    : Icons.receipt_long_outlined,
                color: record.eventType == 2
                    ? Colors.orange.shade800
                    : Theme.of(context).colorScheme.primary),
            title: Text(record.eventLabel),
            subtitle: Text(
                '${time == null ? '时间未知' : '${dateLabel(time)} ${timeLabel(time)}'}\n${record.deviceId} · #${record.seq}'),
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
                              Text(record.eventLabel,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall),
                              const SizedBox(height: 16),
                              for (final entry in <String, String>{
                                '数据来源': data.source.label,
                                '设备 ID': record.deviceId,
                                '序号': '${record.seq}',
                                '本地时间': time == null
                                    ? '时间未知，未计入按日统计'
                                    : time.toString(),
                                'UTC 时间':
                                    record.occurredAt?.toIso8601String() ??
                                        '未知',
                                '持续时间': '${record.durationMs} ms',
                                '压力特征': '${record.pressurePeakPa} Pa',
                                '置信度': '${record.confidence} / 100',
                                '电池电压': '${record.batteryMv} mV',
                                '协议版本': '${record.protocolVersion}',
                                '算法版本': record.algorithmVersion ?? '设备未提供',
                              }.entries)
                                Padding(
                                    padding: const EdgeInsets.only(bottom: 10),
                                    child: Text('${entry.key}：${entry.value}')),
                            ]))))));
  }
}
