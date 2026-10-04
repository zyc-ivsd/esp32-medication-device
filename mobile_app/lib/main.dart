import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'database/sqlite_record_repository.dart';
import 'models/medication_record.dart';
import 'pages/home_page.dart';
import 'services/record_controller.dart';
import 'theme/app_theme.dart';
import 'ble/ble_service.dart';
import 'ble/ble_status_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _ConnectedApp());
}

class _ConnectedApp extends StatefulWidget {
  const _ConnectedApp();
  @override
  State<_ConnectedApp> createState() => _ConnectedAppState();
}

class _ConnectedAppState extends State<_ConnectedApp>
    with WidgetsBindingObserver {
  final _ble = BleService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ble.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      unawaited(_ble.setForeground(false));
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_ble.setForeground(true));
    }
  }

  @override
  Widget build(BuildContext context) => MedicationDeviceApp(
    onRepositoryReady: (repository) async {
      await _ble.attachRecordSink(
        save: repository.saveDeviceTimestamp,
        markSyncCompleted: repository.markSyncCompleted,
      );
      unawaited(_ble.initializeAutoScan());
    },
    connectionBuilder: (context, deviceRepository) =>
        BleConnectionCard(service: _ble),
  );
}

class MedicationDeviceApp extends StatelessWidget {
  const MedicationDeviceApp({
    super.key,
    this.controller,
    this.connectionBuilder,
    this.onRepositoryReady,
  });
  final RecordController? controller;
  final DeviceConnectionBuilder? connectionBuilder;
  final Future<void> Function(SqliteRecordRepository)? onRepositoryReady;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'parcel · Medication diary',
    debugShowCheckedModeBanner: false,
    locale: const Locale('en'),
    supportedLocales: const [Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    // 只有一套主题（浅色）：外观切换已移除，见 theme/app_theme.dart。
    theme: buildAppTheme(),
    home: controller == null
        ? _DatabaseLoader(
            connectionBuilder: connectionBuilder,
            onRepositoryReady: onRepositoryReady,
          )
        : HomePage(
            controller: controller!,
            connectionBuilder: connectionBuilder,
          ),
  );
}

class _DatabaseLoader extends StatefulWidget {
  const _DatabaseLoader({this.connectionBuilder, this.onRepositoryReady});
  final DeviceConnectionBuilder? connectionBuilder;
  final Future<void> Function(SqliteRecordRepository)? onRepositoryReady;
  @override
  State<_DatabaseLoader> createState() => _DatabaseLoaderState();
}

class _DatabaseLoaderState extends State<_DatabaseLoader> {
  RecordController? _controller;
  bool _failed = false;
  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    setState(() => _failed = false);
    SqliteRecordRepository? device;
    try {
      device = await SqliteRecordRepository.open(source: RecordSource.device);
      await widget.onRepositoryReady?.call(device);
      if (!mounted) {
        await device.close();
        return;
      }
      setState(() => _controller = RecordController(deviceRepository: device!));
    } catch (_) {
      await device?.close();
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    final controller = _controller;
    if (controller != null) {
      controller.dispose();
      unawaited(controller.deviceRepository.close());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller != null) {
      return HomePage(
        controller: _controller!,
        connectionBuilder: widget.connectionBuilder,
      );
    }
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _failed
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.storage_outlined, size: 40),
                    const SizedBox(height: 16),
                    const Text(
                      'Cannot open local records. Check available storage and try again.',
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _open,
                      child: const Text('Try again'),
                    ),
                  ],
                )
              : const CircularProgressIndicator(),
        ),
      ),
    );
  }
}
