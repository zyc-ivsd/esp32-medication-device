import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ble_transport.dart';
import 'prototype_protocol.dart';
import 'prototype_store.dart';
import 'prototype_sync.dart';
import 'ble_access.dart';

class BleDeviceInfo {
  const BleDeviceInfo({
    required this.id,
    required this.name,
    required this.rssi,
  });
  final String id;
  final String name;
  final int rssi;
}

enum BleConnectionStatus {
  disconnected,
  scanning,
  connecting,
  subscribing,
  calibrating,
  ready,
  syncing,
  complete,
  error,
}

enum ClockCalibrationStatus {
  unavailable,
  unsupported,
  pending,
  synced,
  failed,
}

/// B's scan/reconnect flow with durable text sync. Owned above navigation, so
/// browsing A's history does not cancel Bluetooth or switch its storage target.
class BleService extends ChangeNotifier {
  BleService({
    BleTransport? transport,
    PrototypeStore? store,
    this.usePreferences = true,
    this.handshakeInterval = const Duration(seconds: 1),
    this.reconnectDelay = const Duration(seconds: 2),
    this.clockRetryInterval = const Duration(seconds: 2),
    DateTime Function()? clock,
  }) : _transportOverride = transport,
       _clock = clock ?? DateTime.now,
       _store = store; // ignore: prefer_initializing_formals
  factory BleService.test() => BleService(usePreferences: false);
  final BleTransport? _transportOverride;
  BleTransport? _defaultTransport;
  BleTransport get _transport =>
      _transportOverride ?? (_defaultTransport ??= ReactiveBleTransport());
  PrototypeStore? _store;
  Future<PrototypeStore>? _openingStore;
  Future<PrototypeStore> _getStore() => _store != null
      ? Future.value(_store!)
      : (_openingStore ??= SqlitePrototypeStore.open()
            .then((store) {
              _store = store;
              return store;
            })
            .catchError((Object error) {
              _openingStore = null;
              throw error;
            }));
  final bool usePreferences;
  final Duration handshakeInterval;
  final Duration reconnectDelay;
  final Duration clockRetryInterval;
  final DateTime Function() _clock;
  static const maxReconnectAttempts = 3;
  static const serviceUuid = prototypeServiceUuid;
  static const notifyCharacteristicUuid = prototypeCharacteristicUuid;
  BleConnectionStatus status = BleConnectionStatus.disconnected;
  final List<BleDeviceInfo> _devices = [];
  final List<String> _logs = [];
  final List<String> _rawLines = [];
  List<PrototypeRecord> savedRecords = [];
  List<BleDeviceInfo> get devices => List.unmodifiable(_devices);
  List<String> get logs => List.unmodifiable(_logs);
  List<String> get rawLines => List.unmodifiable(_rawLines);
  String? connectedDeviceId;
  String? _lastDeviceId;
  String? stableDeviceId;
  bool autoReconnectEnabled = true;
  bool autoScanEnabled = false;
  bool _suppressed = false;
  bool _disposed = false;
  bool _foreground = true;
  String? _resumeDeviceId;
  bool _resumeScan = false;
  Future<void> _lifecycle = Future.value();
  bool get foreground => _foreground;
  bool needsPermissionSettings = false;
  bool _initialized = false;
  bool _linkConnected = false;
  int _epoch = 0;
  int _scanEpoch = 0;
  int _retryCount = 0;
  int receivedBytes = 0;
  String lastHex = '';
  String? lastError;
  int syncedCount = 0;
  int _commitRetries = 0;
  PrototypeSync? _sync;
  bool supportsClockCalibration = false;
  ClockCalibrationStatus clockStatus = ClockCalibrationStatus.unavailable;
  DateTime? lastClockCalibrationAt;
  String? _clockCommand;
  int _clockAttempts = 0;
  bool _syncAfterClock = false;
  bool get canCalibrateClock =>
      _linkConnected &&
      stableDeviceId != null &&
      supportsClockCalibration &&
      _sync == null &&
      clockStatus != ClockCalibrationStatus.pending &&
      status != BleConnectionStatus.syncing;
  String get clockStatusLabel => switch (clockStatus) {
    ClockCalibrationStatus.unavailable => '设备时间：连接后检查',
    ClockCalibrationStatus.unsupported => '设备时间：旧固件不支持手机校时',
    ClockCalibrationStatus.pending => '设备时间：正在使用手机时间校准',
    ClockCalibrationStatus.synced => '设备时间：已按手机时间与时区校准',
    ClockCalibrationStatus.failed => '设备时间：校准失败，请重试校时',
  };
  bool get hasConnection => connectedDeviceId != null;
  bool get canSync =>
      _linkConnected &&
      stableDeviceId != null &&
      clockStatus != ClockCalibrationStatus.pending &&
      (!supportsClockCalibration ||
          clockStatus == ClockCalibrationStatus.synced) &&
      _sync == null &&
      status != BleConnectionStatus.syncing;
  String get statusLabel => switch (status) {
    BleConnectionStatus.disconnected => '未连接',
    BleConnectionStatus.scanning => '扫描中',
    BleConnectionStatus.connecting => '连接中',
    BleConnectionStatus.subscribing => '已连接，等待订阅握手',
    BleConnectionStatus.calibrating => '正在校准设备时间',
    BleConnectionStatus.ready => '订阅已确认',
    BleConnectionStatus.syncing => '正在接收并保存',
    BleConnectionStatus.complete => '原型文本已保存',
    BleConnectionStatus.error => '需要处理',
  };
  StreamSubscription<DiscoveredDevice>? _scan;
  StreamSubscription<ConnectionStateUpdate>? _connection;
  StreamSubscription<List<int>>? _notify;
  Timer? _reconnectTimer;
  Timer? _scanTimer;
  Timer? _handshakeTimer;
  Timer? _syncTimer;
  Timer? _clockTimer;
  DateTime? _lastScanStopped;
  final _buffer = PrototypeLineBuffer();
  Future<void> _incoming = Future.value();
  Future<void> _outgoing = Future.value();

  bool _active(int epoch) => !_disposed && epoch == _epoch;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _log(String message) {
    if (_disposed) return;
    _logs.add('${DateTime.now().toIso8601String().substring(11, 19)} $message');
    if (_logs.length > 80) _logs.removeAt(0);
    _changed();
  }

  void _state(BleConnectionStatus value) {
    status = value;
    _changed();
  }

  void _fail(Object error) {
    if (_disposed) return;
    _handshakeTimer?.cancel();
    _syncTimer?.cancel();
    _clockTimer?.cancel();
    _clockCommand = null;
    _syncAfterClock = false;
    if (clockStatus == ClockCalibrationStatus.pending) {
      clockStatus = ClockCalibrationStatus.failed;
    }
    _sync = null;
    lastError = '$error';
    needsPermissionSettings =
        error is BleAccessException && error.canOpenSettings;
    _log('$error');
    _state(BleConnectionStatus.error);
  }

  Future<void> initializeAutoScan() async {
    if (_initialized || _disposed) return;
    _initialized = true;
    try {
      if (usePreferences) {
        final prefs = await SharedPreferences.getInstance();
        if (_disposed) return;
        _lastDeviceId = prefs.getString('ble.last_device_id');
        autoScanEnabled = prefs.getBool('ble.auto_scan_enabled') ?? false;
      }
      if (usePreferences || _store != null) {
        await _getStore();
        if (_disposed) {
          return;
        }
        savedRecords = await _store!.readRecent();
      }
      _changed();
      if (autoScanEnabled && !_suppressed && !_disposed) await startScan();
    } catch (error) {
      _fail(error);
    }
  }

  void setAutoReconnect(bool value) {
    autoReconnectEnabled = value;
    if (!value) _reconnectTimer?.cancel();
    _changed();
  }

  Future<void> setAutoScan(bool value) async {
    autoScanEnabled = value;
    _changed();
    try {
      if (usePreferences) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('ble.auto_scan_enabled', value);
      }
      if (_disposed) return;
      if (value && !hasConnection) {
        await startScan();
      } else if (!value) {
        await cancelScan();
      }
    } catch (error) {
      _fail(error);
    }
  }

  Future<void> _stopScan() async {
    _scanEpoch++;
    _scanTimer?.cancel();
    final subscription = _scan;
    _scan = null;
    if (subscription != null) {
      await subscription.cancel();
      _lastScanStopped = DateTime.now();
    }
  }

  Future<void> startScan() async {
    if (_disposed ||
        !_foreground ||
        hasConnection ||
        status == BleConnectionStatus.scanning) {
      return;
    }
    _suppressed = false;
    _reconnectTimer?.cancel();
    await _stopScan();
    final scanEpoch = _scanEpoch;
    _state(BleConnectionStatus.scanning);
    lastError = null;
    try {
      await _transport.ensureReady();
      if (_lastScanStopped != null) {
        final remaining =
            const Duration(seconds: 2) -
            DateTime.now().difference(_lastScanStopped!);
        if (remaining > Duration.zero) await Future<void>.delayed(remaining);
      }
      if (_disposed || _suppressed || scanEpoch != _scanEpoch) return;
      _devices.clear();
      _scan = _transport.scan().listen(
        (device) {
          if (_disposed || scanEpoch != _scanEpoch) return;
          final info = BleDeviceInfo(
            id: device.id,
            name: device.name.isEmpty ? 'ESP32 设备' : device.name,
            rssi: device.rssi,
          );
          final index = _devices.indexWhere((d) => d.id == info.id);
          if (index < 0) {
            _devices.add(info);
          } else {
            _devices[index] = info;
          }
          _changed();
          if (autoScanEnabled && device.id == _lastDeviceId && !hasConnection) {
            unawaited(connectToDevice(device.id));
          }
        },
        onError: (Object error) {
          if (scanEpoch != _scanEpoch || _disposed) return;
          unawaited(_stopScan());
          _fail(error);
        },
      );
      _scanTimer = Timer(const Duration(seconds: 15), () {
        if (scanEpoch == _scanEpoch && !_disposed) unawaited(cancelScan());
      });
    } catch (error) {
      if (scanEpoch == _scanEpoch) _fail(error);
    }
  }

  Future<void> cancelScan() async {
    _resumeDeviceId = null;
    _resumeScan = false;
    _suppressed = true;
    _reconnectTimer?.cancel();
    await _stopScan();
    if (!hasConnection) _state(BleConnectionStatus.disconnected);
  }

  Future<void> connectToDevice(
    String deviceId, {
    bool resetRetryCount = true,
  }) async {
    if (_disposed || !_foreground) return;
    _suppressed = false;
    _reconnectTimer?.cancel();
    final epoch = ++_epoch;
    if (resetRetryCount) _retryCount = 0;
    connectedDeviceId = deviceId;
    stableDeviceId = null;
    lastError = null;
    _state(BleConnectionStatus.connecting);
    try {
      await _stopScan();
      await _clearLink();
      if (!_active(epoch)) return;
      await _transport.ensureReady();
      if (!_active(epoch)) return;
      _connection = _transport
          .connect(deviceId)
          .listen(
            (update) {
              if (!_active(epoch)) return;
              switch (update.connectionState) {
                case DeviceConnectionState.connected:
                  if (!_linkConnected) {
                    _linkConnected = true;
                    unawaited(_subscribe(deviceId, epoch));
                  }
                case DeviceConnectionState.disconnected:
                  unawaited(_linkLost(deviceId, epoch, update.failure));
                case DeviceConnectionState.connecting:
                  _state(BleConnectionStatus.connecting);
                case DeviceConnectionState.disconnecting:
                  break;
              }
            },
            onError: (Object error) {
              unawaited(_linkLost(deviceId, epoch, error));
            },
          );
    } catch (error) {
      await _linkLost(deviceId, epoch, error);
    }
  }

  Future<void> _subscribe(String deviceId, int epoch) async {
    try {
      _state(BleConnectionStatus.subscribing);
      await _transport.discover(deviceId);
      if (!_active(epoch)) return;
      _log('服务发现完成，建立 Notify；等待设备 READY 确认');
      _notify = _transport
          .subscribe(deviceId)
          .listen(
            (bytes) {
              if (!_active(epoch)) return;
              receivedBytes += bytes.length;
              lastHex = bytes
                  .map((b) => b.toRadixString(16).padLeft(2, '0'))
                  .join(' ');
              for (final line in _buffer.add(bytes)) {
                _incoming = _incoming
                    .then((_) async {
                      if (_active(epoch)) await _receive(line, epoch);
                    })
                    .catchError((Object error) {
                      if (_active(epoch)) _fail(error);
                    });
              }
              _changed();
            },
            onError: (Object error) {
              if (_active(epoch)) _fail(error);
            },
          );
      var attempts = 0;
      Future<void> hello() async {
        if (!_active(epoch) ||
            stableDeviceId != null ||
            status != BleConnectionStatus.subscribing) {
          return;
        }
        if (++attempts > 6) {
          _fail('设备没有回复 READY。请刷入本次配套固件；旧固件文本仅显示在下方。');
          return;
        }
        try {
          await _write('HELLO', epoch);
          if (_active(epoch) &&
              stableDeviceId == null &&
              status == BleConnectionStatus.subscribing) {
            _handshakeTimer = Timer(
              handshakeInterval,
              () => unawaited(hello()),
            );
          }
        } catch (error) {
          if (_active(epoch)) _fail(error);
        }
      }

      await hello();
    } catch (error) {
      if (_active(epoch)) _fail(error);
    }
  }

  Future<void> _write(String command, int epoch, {bool Function()? guard}) {
    final bytes = utf8.encode(command);
    if (bytes.length > 20) throw ArgumentError('控制命令超过 20 字节');
    final pending = _outgoing.then((_) async {
      if (!_active(epoch) || !_linkConnected) throw StateError('连接已改变，取消旧命令');
      if (guard != null && !guard()) return;
      await _transport.write(connectedDeviceId!, bytes);
      if (_active(epoch)) _log('发送 $command');
    });
    _outgoing = pending.catchError((Object _) {});
    return pending;
  }

  Future<void> _receive(String line, int epoch) async {
    _rawLines.add(line);
    if (_rawLines.length > 40) _rawLines.removeAt(0);
    List<String> fields;
    try {
      fields = decodePrototypeFrame(line);
    } on FormatException catch (error) {
      _log(error.message);
      return;
    }
    if (fields[0] == 'READY') {
      if (status != BleConnectionStatus.subscribing) return;
      if ((fields.length != 3 && fields.length != 4) ||
          fields[2] != 'P01' ||
          (fields.length == 4 && fields[3] != 'TIME1') ||
          !RegExp(r'^[0-9A-Fa-f]{12}$').hasMatch(fields[1])) {
        throw const FormatException('设备 READY 格式或协议版本不匹配');
      }
      if (stableDeviceId != null) return;
      _handshakeTimer?.cancel();
      stableDeviceId = fields[1].toUpperCase();
      supportsClockCalibration = fields.length == 4;
      clockStatus = supportsClockCalibration
          ? ClockCalibrationStatus.unavailable
          : ClockCalibrationStatus.unsupported;
      _lastDeviceId = connectedDeviceId;
      _state(BleConnectionStatus.ready);
      _log('收到 READY：通知链路已确认，设备 $stableDeviceId');
      if (usePreferences) {
        final prefs = await SharedPreferences.getInstance();
        if (!_active(epoch)) return;
        await prefs.setString('ble.last_device_id', _lastDeviceId!);
      }
      if (_active(epoch)) {
        if (supportsClockCalibration) {
          // Only wait for the write here. Waiting for TIME_OK would block the
          // serialized notification queue that must deliver that acknowledgment.
          await requestClockCalibration(syncAfter: true);
        } else {
          _log('旧 P01 固件无 TIME1：保留原同步，原始时间未经手机校准');
          await requestSync();
        }
      }
      return;
    }
    if (fields[0] == 'TIME_OK') {
      if (clockStatus != ClockCalibrationStatus.pending ||
          fields.length != 3 ||
          _clockCommand?.substring(5) != fields.skip(1).join('|')) {
        return;
      }
      _clockTimer?.cancel();
      _clockCommand = null;
      clockStatus = ClockCalibrationStatus.synced;
      lastClockCalibrationAt = _clock();
      final syncAfter = _syncAfterClock;
      _syncAfterClock = false;
      lastError = null;
      _state(BleConnectionStatus.ready);
      _log('校时已获设备确认；历史文件保持原文，不补造过去的时间');
      if (syncAfter) await requestSync();
      return;
    }
    if (fields[0] == 'TIME_ERR') {
      if (clockStatus == ClockCalibrationStatus.pending && fields.length == 2) {
        _fail('设备校时失败（${fields[1]}）；检查固件/NVS 后点击“校准设备时间”');
      }
      return;
    }
    final sync = _sync;
    if (sync == null || fields.length < 2 || fields[1] != sync.token) return;
    await sync.accept(fields);
    if (!_active(epoch) || !identical(_sync, sync)) return;
    syncedCount = sync.savedCount;
    if (sync.completed) {
      _syncTimer?.cancel();
      savedRecords = await _store!.readRecent();
      if (!_active(epoch)) return;
      _sync = null;
      _retryCount = 0;
      _state(BleConnectionStatus.complete);
      _log('本轮 $syncedCount 条原型文本已保存；设备文件保留，可重复同步');
    } else {
      _armSyncTimeout(epoch);
      _changed();
    }
  }

  Future<void> requestClockCalibration({bool syncAfter = false}) async {
    if (_disposed || !_foreground || !canCalibrateClock) return;
    final now = _clock();
    final utc = now.millisecondsSinceEpoch ~/ 1000;
    final offset = now.timeZoneOffset.inMinutes;
    if (utc < 946684800 || utc > 4102444799 || offset.abs() > 840) {
      clockStatus = ClockCalibrationStatus.failed;
      _fail('手机日期或时区超出支持范围（2000–2099 年、UTC ±14 小时），请检查系统时间');
      return;
    }
    final command = 'TIME|${utc.toRadixString(16).padLeft(8, '0')}|$offset';
    _clockCommand = command;
    _clockAttempts = 0;
    _syncAfterClock = syncAfter;
    clockStatus = ClockCalibrationStatus.pending;
    lastClockCalibrationAt = null;
    lastError = null;
    _state(BleConnectionStatus.calibrating);
    await _sendClock(command, _epoch);
  }

  Future<void> _sendClock(String command, int epoch) async {
    if (!_active(epoch) || _clockCommand != command) return;
    if (_clockAttempts++ >= 3) {
      _fail('设备校时超时；文件仍保留，请点击“校准设备时间”重试');
      return;
    }
    try {
      await _write(command, epoch, guard: () => _clockCommand == command);
      if (_active(epoch) && _clockCommand == command) {
        _clockTimer?.cancel();
        _clockTimer = Timer(
          clockRetryInterval,
          () => unawaited(_sendClock(command, epoch)),
        );
      }
    } catch (error) {
      if (_active(epoch)) _fail(error);
    }
  }

  Future<void> requestSync() async {
    if (_disposed || !_foreground || !canSync) return;
    final epoch = _epoch;
    _state(BleConnectionStatus.syncing);
    lastError = null;
    syncedCount = 0;
    _commitRetries = 0;
    try {
      await _getStore();
      if (!_active(epoch)) return;
      final random = Random.secure();
      final token = List.generate(
        4,
        (_) => random.nextInt(256),
      ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      late final PrototypeSync sync;
      sync = PrototypeSync(
        deviceId: stableDeviceId!,
        token: token,
        store: _store!,
        write: (command) async {
          if (identical(_sync, sync)) {
            await _write(command, epoch, guard: () => identical(_sync, sync));
          }
        },
        isActive: () => _active(epoch) && identical(_sync, sync),
      );
      _sync = sync;
      await _write('SYNC_REQ|$token', epoch);
      if (_active(epoch)) _armSyncTimeout(epoch);
    } catch (error) {
      if (_active(epoch)) _fail(error);
    }
  }

  void _armSyncTimeout(int epoch) {
    _syncTimer?.cancel();
    final committing = _sync?.endReceived == true;
    _syncTimer = Timer(Duration(seconds: committing ? 2 : 12), () async {
      if (!_active(epoch)) return;
      if (_sync?.endReceived == true && _commitRetries++ < 3) {
        try {
          await _write('COMMIT|${_sync!.token}', epoch);
          if (_active(epoch) && _sync != null) _armSyncTimeout(epoch);
        } catch (error) {
          if (_active(epoch)) _fail(error);
        }
      } else {
        _fail('同步超时，已保存的数据仍保留；请点击“重新同步”');
      }
    });
  }

  Future<void> _linkLost(String deviceId, int epoch, Object? error) async {
    if (!_active(epoch)) return;
    final lostEpoch = ++_epoch;
    connectedDeviceId = null;
    stableDeviceId = null;
    await _clearLink();
    if (!_active(lostEpoch)) return;
    if (error != null) {
      _fail(error);
    } else {
      _state(BleConnectionStatus.disconnected);
    }
    _log('连接中断；未完成的记录不会获确认');
    if (autoReconnectEnabled &&
        !_suppressed &&
        _retryCount < maxReconnectAttempts) {
      _retryCount++;
      _log(
        '将在 ${reconnectDelay.inSeconds} 秒后重连（$_retryCount/$maxReconnectAttempts）',
      );
      _reconnectTimer = Timer(reconnectDelay, () {
        if (_active(lostEpoch) && !_suppressed && autoReconnectEnabled) {
          unawaited(connectToDevice(deviceId, resetRetryCount: false));
        }
      });
    }
  }

  Future<void> _clearLink() async {
    _handshakeTimer?.cancel();
    _syncTimer?.cancel();
    _clockTimer?.cancel();
    _clockCommand = null;
    _syncAfterClock = false;
    supportsClockCalibration = false;
    clockStatus = ClockCalibrationStatus.unavailable;
    lastClockCalibrationAt = null;
    _linkConnected = false;
    _sync = null;
    _buffer.reset();
    final notify = _notify;
    final connection = _connection;
    _notify = null;
    _connection = null;
    await notify?.cancel();
    await connection?.cancel();
  }

  Future<void> disconnect() async {
    _resumeDeviceId = null;
    _resumeScan = false;
    await _disconnectLink();
  }

  Future<void> _disconnectLink() async {
    _suppressed = true;
    ++_epoch;
    _reconnectTimer?.cancel();
    await _stopScan();
    await _clearLink();
    connectedDeviceId = null;
    stableDeviceId = null;
    _state(BleConnectionStatus.disconnected);
  }

  /// Foreground-only BLE on both mobile platforms. Ignore `inactive` (permission
  /// dialogs / Control Center); pause only on the application's `paused` event.
  Future<void> setForeground(bool value) {
    Future<void> restoration = Future.value();
    _lifecycle = _lifecycle
        .then((_) async {
          if (_disposed || _foreground == value) return;
          _foreground = value;
          if (!value) {
            _resumeDeviceId = autoReconnectEnabled ? connectedDeviceId : null;
            _resumeScan = status == BleConnectionStatus.scanning;
            await _disconnectLink();
            _log('已进入后台，暂停蓝牙；已保存记录保留');
          } else {
            final device = _resumeDeviceId;
            final scan = _resumeScan;
            _resumeDeviceId = null;
            _resumeScan = false;
            if (device != null && autoReconnectEnabled) {
              restoration = connectToDevice(device);
            } else if (scan) {
              restoration = startScan();
            }
          }
          _changed();
        })
        .catchError((Object error) {
          _fail(error);
        });
    // Permission prompts can remain open. A later pause must be able to cancel
    // this restoration without waiting for the prompt or scan cooldown.
    return _lifecycle.then((_) => restoration);
  }

  Future<void> _close() async {
    await disconnect();
    await _incoming;
    await _outgoing;
    try {
      await _openingStore;
    } catch (_) {
      /* Opening failed: no handle to close. */
    }
    await _store?.close();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_close());
    super.dispose();
  }
}
