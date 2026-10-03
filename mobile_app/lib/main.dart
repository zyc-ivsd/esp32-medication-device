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
    unawaited(_ble.initializeAutoScan());
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
    connectionBuilder: (context, deviceRepository) =>
        BleConnectionCard(service: _ble),
  );
}

class MedicationDeviceApp extends StatelessWidget {
  const MedicationDeviceApp({super.key, this.controller, this.connectionBuilder});
  final RecordController? controller;
  final DeviceConnectionBuilder? connectionBuilder;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '用药装置 · 记录',
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    // 只有一套主题（浅色）：外观切换已移除，见 theme/app_theme.dart。
    theme: buildAppTheme(),
    home: controller == null
        ? _DatabaseLoader(connectionBuilder: connectionBuilder)
        : HomePage(
            controller: controller!,
            connectionBuilder: connectionBuilder,
          ),
  );
}

class _DatabaseLoader extends StatefulWidget {
  const _DatabaseLoader({this.connectionBuilder});
  final DeviceConnectionBuilder? connectionBuilder;
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
    SqliteRecordRepository? demo;
    try {
      device = await SqliteRecordRepository.open(source: RecordSource.device);
      demo = await SqliteRecordRepository.open(source: RecordSource.demo);
      if (!mounted) {
        await device.close();
        await demo.close();
        return;
      }
      setState(
        () => _controller = RecordController(
          deviceRepository: device!,
          demoRepository: demo!,
        ),
      );
    } catch (_) {
      await device?.close();
      await demo?.close();
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    final controller = _controller;
    if (controller != null) {
      controller.dispose();
      unawaited(controller.deviceRepository.close());
      unawaited(controller.demoRepository.close());
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
                    const Text('本地记录暂时无法打开，请检查可用存储空间后重试。'),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: _open, child: const Text('重新打开')),
                  ],
                )
              : const CircularProgressIndicator(),
        ),
      ),
    );
  }
}
