import 'package:flutter/material.dart';

void main() {
  runApp(const MedicationDeviceApp());
}

class MedicationDeviceApp extends StatelessWidget {
  const MedicationDeviceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESP32 Medication Device',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ESP32 用药装置')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.bluetooth_searching, size: 64),
            const SizedBox(height: 16),
            const Text('Flutter App 初始骨架'),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () {
                // TODO: 在 ble/ 中接入扫描、连接和同步服务。
              },
              child: const Text('扫描设备'),
            ),
          ],
        ),
      ),
    );
  }
}
