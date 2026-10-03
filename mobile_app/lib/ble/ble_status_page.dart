import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'ble_service.dart';

class BleConnectionCard extends StatelessWidget {
  const BleConnectionCard({super.key, required this.service});
  final BleService service;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: service,
    builder: (context, _) => Card(
      child: ListTile(
        leading: const Icon(Icons.bluetooth),
        title: Text('设备连接 · ${service.statusLabel}'),
        subtitle: Text(
          '原型文本 ${service.savedRecords.length} 条（最近 100 条）\n点击连接设备、同步或查看已保存文本',
        ),
        isThreeLine: true,
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => BleStatusPage(service: service),
          ),
        ),
      ),
    ),
  );
}

class BleStatusPage extends StatefulWidget {
  const BleStatusPage({super.key, this.service});
  final BleService? service;
  @override
  State<BleStatusPage> createState() => _BleStatusPageState();
}

class _BleStatusPageState extends State<BleStatusPage> {
  late final _service = widget.service ?? BleService();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_service.initializeAutoScan());
    });
  }

  @override
  void dispose() {
    if (widget.service == null) _service.dispose();
    super.dispose();
  }

  Future<void> _openPermissionSettings() async {
    try {
      if (await openAppSettings()) return;
    } catch (_) {
      /* Show manual recovery instructions below. */
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('请手动打开系统设置，找到“用药装置”，开启蓝牙权限后返回扫描')),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _service,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('设备连接与原型数据')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Prototype v0.1',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text('这里保存硬件按键产生的时间文本。配套固件连接后自动校时；已有文件保持原文，这些文本不计入正式事件统计。'),
            const SizedBox(height: 8),
            const Text('设备断开且空闲 30 秒后进入浅睡眠；扫描不到时先按硬件按钮唤醒，再点击扫描。'),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _service.statusLabel,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (_service.connectedDeviceId != null)
                      SelectableText('连接：${_service.connectedDeviceId}'),
                    if (_service.stableDeviceId != null)
                      SelectableText('设备 ID：${_service.stableDeviceId}'),
                    Text(_service.clockStatusLabel),
                    if (_service.lastClockCalibrationAt != null)
                      Text(
                        '本次校时：${_service.lastClockCalibrationAt!.toLocal().toString().split('.').first}',
                      ),
                    Text(
                      '累计收到 ${_service.receivedBytes} 字节 · 本轮保存 ${_service.syncedCount} 条',
                    ),
                    if (_service.lastError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: SelectableText(
                          _service.lastError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    if (_service.lastError != null &&
                        _service.needsPermissionSettings)
                      TextButton.icon(
                        onPressed: _openPermissionSettings,
                        icon: const Icon(Icons.settings),
                        label: const Text('打开应用设置'),
                      ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('断线后自动重连（最多 3 次）'),
                      value: _service.autoReconnectEnabled,
                      onChanged: _service.setAutoReconnect,
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('下次打开 App 时自动扫描'),
                      value: _service.autoScanEnabled,
                      onChanged: _service.setAutoScan,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed:
                      _service.hasConnection ||
                          _service.status == BleConnectionStatus.scanning
                      ? null
                      : _service.startScan,
                  icon: const Icon(Icons.bluetooth_searching),
                  label: const Text('扫描设备'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _service.canSync ? _service.requestSync : null,
                  icon: const Icon(Icons.sync),
                  label: const Text('重新同步'),
                ),
                OutlinedButton.icon(
                  onPressed: _service.canCalibrateClock
                      ? () => _service.requestClockCalibration(syncAfter: true)
                      : null,
                  icon: const Icon(Icons.schedule),
                  label: const Text('校准设备时间'),
                ),
                OutlinedButton(
                  onPressed: _service.hasConnection
                      ? _service.disconnect
                      : _service.cancelScan,
                  child: Text(_service.hasConnection ? '断开连接' : '取消扫描'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              '已发现设备',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            if (_service.devices.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('设备上电后点击扫描，在这里选择 ESP32-C3。'),
              ),
            for (final device in _service.devices)
              Card(
                child: ListTile(
                  title: Text(device.name),
                  subtitle: Text(device.id),
                  trailing: Text('${device.rssi} dBm'),
                  onTap: _service.hasConnection
                      ? null
                      : () => _service.connectToDevice(device.id),
                ),
              ),
            const SizedBox(height: 16),
            const Text(
              '已保存的原型文本',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const Text('显示最近 100 条；关闭 App 后保留，重传相同文件不会重复添加。'),
            if (_service.savedRecords.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('尚无已保存文本。'),
              ),
            for (final record in _service.savedRecords)
              Card(
                child: ListTile(
                  title: SelectableText(record.rawText),
                  subtitle: Text('${record.deviceId}\n${record.fileId}'),
                ),
              ),
            const SizedBox(height: 12),
            ExpansionTile(
              title: const Text('接收诊断：原始字节与文本'),
              children: [
                SelectableText(
                  '最近一包 HEX：${_service.lastHex.isEmpty ? '暂无' : _service.lastHex}',
                ),
                for (final line in _service.rawLines.reversed)
                  Padding(
                    padding: const EdgeInsets.all(6),
                    child: SelectableText(line),
                  ),
              ],
            ),
            ExpansionTile(
              title: const Text('连接与同步日志'),
              children: [
                for (final line in _service.logs.reversed)
                  Padding(
                    padding: const EdgeInsets.all(6),
                    child: SelectableText(line),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
