import 'package:flutter/material.dart';

import 'assistant/assistant_page.dart';

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
            const Text('Flutter App 第一阶段骨架'),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('BLE 扫描模块待接入硬件联调。')),
                );
              },
              icon: const Icon(Icons.bluetooth_searching),
              label: const Text('扫描设备'),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const AssistantPage(),
                  ),
                );
              },
              icon: const Icon(Icons.chat),
              label: const Text('打开 AI 助手'),
            ),
          ],
        ),
      ),
    );
  }
}
