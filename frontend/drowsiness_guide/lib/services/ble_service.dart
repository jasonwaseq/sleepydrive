import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// UUIDs must match the Jetson's config.py
const _serviceUuid = "12345678-1234-5678-1234-56789abcdef0";
const _charUuid = "12345678-1234-5678-1234-56789abcdef1";
const _deviceName = "SleepyDrive";

enum _ScanMode { serviceOrName, keyword }

/// A parsed alert from the Jetson BLE server.
class BleAlert {
  /// 0 = SAFE, 1 = WARNING, 2 = DANGER
  final int level;
  final String message;
  final DateTime timestamp;

  BleAlert({required this.level, required this.message})
    : timestamp = DateTime.now();

  static BleAlert? tryParsePayload(String payload) {
    final text = payload.trim();
    if (text.isEmpty) return null;
    final pipe = text.indexOf('|');
    if (pipe < 0) return null;
    final level = int.tryParse(text.substring(0, pipe).trim());
    if (level == null || level < 0) return null;
    final message = text.substring(pipe + 1).trim();
    if (message.isEmpty) return null;
    return BleAlert(level: level, message: message);
  }

  String get levelLabel {
    switch (level) {
      case 0:
        return 'SAFE';
      case 1:
        return 'WARNING';
      case 2:
        return 'DANGER';
      default:
        return 'UNKNOWN';
    }
  }
}

/// Minimal BLE service — scan for "SleepyDrive", connect, stream alerts.
class BleService {
  BluetoothDevice? _device;
  BluetoothDevice? _lastDevice;
  StreamSubscription? _notifySub;
  StreamSubscription? _connSub;

  final _alertCtrl = StreamController<BleAlert>.broadcast();
  final _stateCtrl = StreamController<String>.broadcast();

  /// Stream of parsed alerts from the Jetson.
  Stream<BleAlert> get alerts => _alertCtrl.stream;

  /// Stream of connection state strings: "Scanning…", "Connecting…",
  /// "Connected", "Disconnected".
  Stream<String> get connectionState => _stateCtrl.stream;

  String _currentState = 'Disconnected';
  String get currentState => _currentState;

  // Auto-reconnect state: true while we own a connection attempt.
  // Set false only during explicit disconnect().
  bool _autoReconnect = false;
  bool _disposed = false;
  bool _connecting = false; // guard against concurrent scanAndConnect() calls
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;

  String _packetBuffer = '';
  Timer? _packetFlushTimer;
  String? _lastPacketText;
  DateTime? _lastPacketAt;

  void _setState(String s) {
    _currentState = s;
    _stateCtrl.add(s);
    debugPrint('[BLE] state → $s');
  }

  bool _matchesExpectedName(String name) {
    return name.toLowerCase().contains(_deviceName.toLowerCase());
  }

  bool _matchesDevice(ScanResult result) {
    if (_matchesExpectedName(result.device.platformName)) {
      return true;
    }
    final advName = result.advertisementData.advName;
    return advName.isNotEmpty && _matchesExpectedName(advName);
  }

  Future<bool> _ensureBlePermissions() async {
    if (kIsWeb) {
      return true;
    }

    final permissions = <Permission>[];
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        permissions.addAll([
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.locationWhenInUse,
        ]);
        break;
      case TargetPlatform.iOS:
        permissions.add(Permission.bluetooth);
        break;
      default:
        return true;
    }

    final statuses = await permissions.request();
    return statuses.values.every((status) => status.isGranted);
  }

  Future<BluetoothDevice?> _scanForSleepyDrive(_ScanMode mode) async {
    BluetoothDevice? found;
    Object? scanError;
    bool stopRequested = false;
    final scanSub = FlutterBluePlus.onScanResults.listen(
      (results) {
        for (final r in results) {
          if (_matchesDevice(r)) {
            found = r.device;
            if (!stopRequested) {
              stopRequested = true;
              unawaited(FlutterBluePlus.stopScan());
            }
          }
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        scanError = error;
      },
    );

    try {
      final services = mode == _ScanMode.serviceOrName
          ? [Guid(_serviceUuid)]
          : <Guid>[];
      final names = mode == _ScanMode.serviceOrName
          ? [_deviceName]
          : <String>[];
      final keywords = mode == _ScanMode.keyword ? [_deviceName] : <String>[];
      await FlutterBluePlus.startScan(
        withServices: services,
        withNames: names,
        withKeywords: keywords,
        timeout: const Duration(seconds: 6),
        androidUsesFineLocation: true,
        androidCheckLocationServices: true,
      );
      await FlutterBluePlus.isScanning
          .where((isScanning) => isScanning == false)
          .first
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      scanError ??= e;
    } finally {
      await scanSub.cancel();
    }

    if (scanError != null) {
      throw scanError!;
    }
    return found;
  }

  /// Scan for the SleepyDrive device and connect.
  /// Set [autoReconnect] to false only when called from an explicit
  /// user-initiated retry; the internal reconnect path always leaves it true.
  Future<void> scanAndConnect() async {
    if (_disposed) return;
    if (_connecting) return; // prevent concurrent connection attempts
    _connecting = true;
    _autoReconnect = true;
    _reconnectTimer?.cancel();

    try {
      if (!await FlutterBluePlus.isSupported) {
        _setState('BLE unsupported');
        return;
      }

      if (!await _ensureBlePermissions()) {
        _setState('Bluetooth permission denied');
        await Future.delayed(const Duration(seconds: 2));
        _setState('Disconnected');
        return;
      }

      // Wait for Bluetooth adapter to be on (gives iOS time to process permission)
      if (!kIsWeb) {
        _setState('Waiting for Bluetooth…');
        try {
          final initialState = await FlutterBluePlus.adapterState.first.timeout(
            const Duration(seconds: 5),
          );
          if (initialState == BluetoothAdapterState.unauthorized) {
            _setState('Bluetooth unauthorized');
            return;
          }
          if (initialState != BluetoothAdapterState.on) {
            await FlutterBluePlus.adapterState
                .where((s) => s == BluetoothAdapterState.on)
                .first
                .timeout(const Duration(seconds: 5));
          }
        } catch (_) {
          _setState('Bluetooth is off');
          await Future.delayed(const Duration(seconds: 1));
          _setState('Disconnected');
          _scheduleReconnect();
          return;
        }
      }

      final cached = _lastDevice;
      if (cached != null) {
        if (await _connectToDevice(cached)) return;
      }

      _setState('Scanning…');

      BluetoothDevice? found;
      try {
        found = await _scanForSleepyDrive(_ScanMode.serviceOrName);
        found ??= await _scanForSleepyDrive(_ScanMode.keyword);
      } catch (e) {
        debugPrint('[BLE] scan error: $e');
        _setState('Scan failed');
        await Future.delayed(const Duration(seconds: 2));
        _setState('Disconnected');
        _scheduleReconnect();
        return;
      }

      if (found == null) {
        try {
          final systemDevices = await FlutterBluePlus.systemDevices([
            Guid(_serviceUuid),
          ]);
          for (final device in systemDevices) {
            if (_matchesExpectedName(device.platformName)) {
              found = device;
              break;
            }
          }
        } catch (_) {
          // Ignore system-device lookup failures and fall through to "Not found".
        }
      }

      if (found == null) {
        _setState('Not found');
        await Future.delayed(const Duration(seconds: 2));
        _setState('Disconnected');
        _scheduleReconnect();
        return;
      }

      if (!await _connectToDevice(found)) {
        _setState('Disconnected');
        _scheduleReconnect();
      }
    } finally {
      _connecting = false;
    }
  }

  Future<bool> _connectToDevice(BluetoothDevice found) async {
    if (_disposed) return false;

    _setState('Connecting…');
    _packetBuffer = '';
    _packetFlushTimer?.cancel();

    await _notifySub?.cancel();
    _notifySub = null;
    await _connSub?.cancel();
    _connSub = null;

    try {
      if (found.isDisconnected) {
        await found.connect(timeout: const Duration(seconds: 12), mtu: null);
      }
      _device = found;
      _lastDevice = found;

      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        try {
          await found
              .requestConnectionPriority(
                connectionPriorityRequest: ConnectionPriority.high,
              )
              .timeout(const Duration(seconds: 4));
        } catch (e) {
          debugPrint('[BLE] connection priority request skipped: $e');
        }
        try {
          final mtu = await found
              .requestMtu(247)
              .timeout(const Duration(seconds: 6));
          debugPrint('[BLE] MTU set to $mtu');
        } catch (e) {
          debugPrint('[BLE] MTU request skipped: $e');
        }
      }

      _connSub = found.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _handleDeviceDisconnected(found);
        }
      });

      final services = await found
          .discoverServices(subscribeToServicesChanged: false)
          .timeout(const Duration(seconds: 10));
      debugPrint('[BLE] discovered ${services.length} services');
      for (final svc in services) {
        debugPrint('[BLE]   service: ${svc.uuid}');
      }

      for (final svc in services) {
        if (svc.uuid.toString().toLowerCase() != _serviceUuid) continue;
        for (final ch in svc.characteristics) {
          debugPrint(
            '[BLE]     char: ${ch.uuid} notify=${ch.properties.notify} '
            'indicate=${ch.properties.indicate}',
          );
          if (ch.uuid.toString().toLowerCase() != _charUuid) continue;
          if (!ch.properties.notify && !ch.properties.indicate) {
            throw StateError('alert characteristic does not support notify');
          }

          final sub = ch.onValueReceived.listen(
            _onData,
            onError: (Object e, StackTrace st) {
              debugPrint('[BLE] notification stream error: $e');
            },
          );
          found.cancelWhenDisconnected(sub);
          _notifySub = sub;

          await ch.setNotifyValue(true).timeout(const Duration(seconds: 8));
          try {
            final current = await ch
                .read(timeout: 5)
                .timeout(const Duration(seconds: 6));
            if (current.isNotEmpty) {
              _onData(current);
            }
          } catch (e) {
            debugPrint('[BLE] initial characteristic read skipped: $e');
          }

          _reconnectAttempt = 0;
          _setState('Connected');
          debugPrint('[BLE] subscribed to alert characteristic');
          return true;
        }
      }

      throw StateError('alert service/characteristic not found');
    } catch (e) {
      debugPrint('[BLE] connection/setup error: $e');
      await _cleanupFailedConnection(found);
      _setState('Connection failed');
      await Future.delayed(const Duration(milliseconds: 600));
      return false;
    }
  }

  void _handleDeviceDisconnected(BluetoothDevice device) {
    if (_device != null && _device != device) return;
    _notifySub?.cancel();
    _notifySub = null;
    unawaited(_connSub?.cancel() ?? Future<void>.value());
    _connSub = null;
    _device = null;
    _packetBuffer = '';
    _packetFlushTimer?.cancel();
    if (_currentState != 'Disconnected') {
      _setState('Disconnected');
    }
    Future(() async {
      try {
        await device
            .disconnect(queue: false)
            .timeout(const Duration(seconds: 5));
      } catch (_) {}
      _scheduleReconnect();
    });
  }

  Future<void> _cleanupFailedConnection(BluetoothDevice device) async {
    await _notifySub?.cancel();
    _notifySub = null;
    await _connSub?.cancel();
    _connSub = null;
    if (_device == device) {
      _device = null;
    }
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        device.isConnected) {
      try {
        await device.clearGattCache().timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    try {
      await device.disconnect(queue: false).timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  /// Schedule a reconnection attempt after a short backoff, unless we were
  /// explicitly disconnected by the user.
  void _scheduleReconnect() {
    if (!_autoReconnect || _disposed) return;
    _reconnectTimer?.cancel();
    _reconnectAttempt = (_reconnectAttempt + 1).clamp(1, 5).toInt();
    final delay = Duration(seconds: 3 * (1 << (_reconnectAttempt - 1)));
    _reconnectTimer = Timer(delay, () {
      if (_autoReconnect && !_disposed && _currentState == 'Disconnected') {
        debugPrint('[BLE] auto-reconnecting…');
        scanAndConnect();
      }
    });
  }

  void _onData(List<int> raw) {
    try {
      final text = utf8.decode(raw, allowMalformed: true);
      _packetBuffer += text;
      _drainCompletePackets();
      if (_packetBuffer.isEmpty) {
        _packetFlushTimer?.cancel();
      } else if (!_packetBuffer.contains('\n')) {
        _packetFlushTimer?.cancel();
        _packetFlushTimer = Timer(const Duration(milliseconds: 150), () {
          final pending = _packetBuffer;
          _packetBuffer = '';
          _handlePacket(pending);
        });
      }
    } catch (e) {
      debugPrint('[BLE] failed to decode packet: $e');
    }
  }

  void _drainCompletePackets() {
    var newline = _packetBuffer.indexOf('\n');
    while (newline >= 0) {
      final packet = _packetBuffer.substring(0, newline);
      _packetBuffer = _packetBuffer.substring(newline + 1);
      _handlePacket(packet);
      newline = _packetBuffer.indexOf('\n');
    }
  }

  void _handlePacket(String packet) {
    final normalized = packet.trim();
    if (normalized.isEmpty) return;

    final now = DateTime.now();
    final lastAt = _lastPacketAt;
    if (_lastPacketText == normalized &&
        lastAt != null &&
        now.difference(lastAt) < const Duration(seconds: 2)) {
      return;
    }

    final alert = BleAlert.tryParsePayload(normalized);
    if (alert == null) return;

    _lastPacketText = normalized;
    _lastPacketAt = now;
    _alertCtrl.add(alert);
  }

  /// Disconnect from the current device. Disables auto-reconnect.
  Future<void> disconnect() async {
    _autoReconnect = false;
    _reconnectTimer?.cancel();
    _packetFlushTimer?.cancel();
    await _notifySub?.cancel();
    _notifySub = null;
    await _connSub?.cancel();
    _connSub = null;
    await _device?.disconnect();
    _device = null;
    _packetBuffer = '';
    _setState('Disconnected');
  }

  /// Clean up resources.
  void dispose() {
    _disposed = true;
    _autoReconnect = false;
    _reconnectTimer?.cancel();
    _packetFlushTimer?.cancel();
    _notifySub?.cancel();
    _connSub?.cancel();
    _alertCtrl.close();
    _stateCtrl.close();
  }
}
