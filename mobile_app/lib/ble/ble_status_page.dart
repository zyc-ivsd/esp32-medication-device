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
        title: Text('Device connection · ${service.statusLabel}'),
        subtitle: Text(
          '${service.savedRecords.length} recent device timestamps\nConnect, sync or inspect saved records',
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
      const SnackBar(
        content: Text(
          'Open system settings, find parcel, enable Bluetooth permission and scan again.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _service,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Device connection')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Sync your medication diary',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Each unique button timestamp becomes one medication-use entry. Invalid or uncalibrated placeholder times are kept for review and excluded from daily counts. Old timestamps are not changed by calibration.',
            ),
            const SizedBox(height: 8),
            const Text(
              'The device sleeps after 30 seconds of disconnected inactivity. Press its button to wake it before scanning.',
            ),
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
                      SelectableText(
                        'Connection: ${_service.connectedDeviceId}',
                      ),
                    if (_service.stableDeviceId != null)
                      SelectableText('Device ID: ${_service.stableDeviceId}'),
                    Text(_service.clockStatusLabel),
                    if (_service.lastClockCalibrationAt != null)
                      Text(
                        'Clock calibrated: ${_service.lastClockCalibrationAt!.toLocal().toString().split('.').first}',
                      ),
                    Text(
                      'Received ${_service.receivedBytes} bytes · Saved ${_service.syncedCount} this sync',
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
                        label: const Text('Open app settings'),
                      ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Reconnect automatically (up to 3 attempts)',
                      ),
                      value: _service.autoReconnectEnabled,
                      onChanged: _service.setAutoReconnect,
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Scan automatically when the app opens',
                      ),
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
                  label: const Text('Scan devices'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _service.canSync ? _service.requestSync : null,
                  icon: const Icon(Icons.sync),
                  label: const Text('Re-sync'),
                ),
                OutlinedButton.icon(
                  onPressed: _service.canCalibrateClock
                      ? () => _service.requestClockCalibration(syncAfter: true)
                      : null,
                  icon: const Icon(Icons.schedule),
                  label: const Text('Calibrate clock'),
                ),
                OutlinedButton(
                  onPressed: _service.hasConnection
                      ? _service.disconnect
                      : _service.cancelScan,
                  child: Text(
                    _service.hasConnection ? 'Disconnect' : 'Cancel scan',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'Discovered devices',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            if (_service.devices.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'Power on or wake the device, tap Scan devices and select ESP32-C3.',
                ),
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
              'Saved device timestamps',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const Text(
              'Showing the latest 100. Records persist after closing the app; resending a file does not add another use.',
            ),
            if (_service.savedRecords.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('No saved timestamps yet.'),
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
              title: const Text('Diagnostics: received bytes and text'),
              children: [
                SelectableText(
                  'Last packet HEX: ${_service.lastHex.isEmpty ? 'None' : _service.lastHex}',
                ),
                for (final line in _service.rawLines.reversed)
                  Padding(
                    padding: const EdgeInsets.all(6),
                    child: SelectableText(line),
                  ),
              ],
            ),
            ExpansionTile(
              title: const Text('Connection and sync log'),
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
