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

  String get levelLabel {
    switch (level) {
      case 0:  return 'SAFE';
      case 1:  return 'WARNING';
      case 2:  return 'DANGER';
      default: return 'UNKNOWN';
    }
  }
}

/// Minimal BLE service — scan for "SleepyDrive", connect, stream alerts.
class BleService {
  BluetoothDevice? _device;
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
  Timer? _reconnectTimer;

  void _setState(String s) {
    _currentState = s;
    _stateCtrl.add(s);
    debugPrint('[BLE] state → $s');
  }

  bool _matchesExpectedName(String name) {
    return name.toLowerCase().contains(_deviceName.toLowerCase());
  }

  bool _matchesExpectedService(ScanResult result) {
    for (final uuid in result.advertisementData.serviceUuids) {
      if (uuid.toLowerCase() == _serviceUuid) {
        return true;
      }
    }
    return false;
  }

  int _deviceMatchScore(ScanResult result) {
    final platformName = result.device.platformName;
    final advName = result.advertisementData.advName;
    final platformExact = platformName.toLowerCase() == _deviceName.toLowerCase();
    final advExact = advName.toLowerCase() == _deviceName.toLowerCase();
    final platformMatch = _matchesExpectedName(platformName);
    final advMatch = advName.isNotEmpty && _matchesExpectedName(advName);
    final serviceMatch = _matchesExpectedService(result);

    // Prioritize exact-name + service match to avoid unsupported devices.
    if ((platformExact || advExact) && serviceMatch) return 6;
    if (platformExact || advExact) return 5;
    if (serviceMatch && (platformMatch || advMatch)) return 4;
    if (serviceMatch) return 3;
    if (platformMatch || advMatch) return 2;
    return 0;
  }

  bool _matchesDevice(ScanResult result) {
    return _deviceMatchScore(result) >= 3;
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
    int foundScore = 0;
    Object? scanError;
    final scanSub = FlutterBluePlus.onScanResults.listen(
      (results) {
        for (final r in results) {
          final score = _deviceMatchScore(r);
          if (score > foundScore) {
            found = r.device;
            foundScore = score;
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
      final keywords = mode == _ScanMode.keyword
          ? [_deviceName]
          : <String>[];
      await FlutterBluePlus.startScan(
        withServices: services,
        withNames: names,
        withKeywords: keywords,
        timeout: const Duration(seconds: 8),
        androidUsesFineLocation: true,
        androidCheckLocationServices: false,
      );
      await FlutterBluePlus.isScanning
          .where((isScanning) => isScanning == false)
          .first
          .timeout(const Duration(seconds: 10));
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
    _autoReconnect = true;
    _reconnectTimer?.cancel();

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
        return;
      }
    }

    _setState('Scanning…');

    BluetoothDevice? found;
    try {
      found = await _scanForSleepyDrive(_ScanMode.serviceOrName);
      // Keyword scan is intentionally skipped to avoid broad noisy results from
      // unrelated nearby BLE devices that the app cannot communicate with.
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

    _setState('Connecting…');

    try {
      await found.connect(timeout: const Duration(seconds: 10));
      _device = found;

      // Listen for disconnection — trigger auto-reconnect if we own the session.
      _connSub?.cancel();
      _connSub = found.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _notifySub?.cancel();
          _notifySub = null;
          _setState('Disconnected');
          _scheduleReconnect();
        }
      });

      _setState('Connected');

      // Discover services and subscribe to the alert characteristic.
      final services = await found.discoverServices();
      bool subscribed = false;
      for (final svc in services) {
        if (svc.uuid.toString().toLowerCase() == _serviceUuid) {
          for (final ch in svc.characteristics) {
            if (ch.uuid.toString().toLowerCase() == _charUuid) {
              if (!ch.properties.notify) {
                debugPrint('[BLE] characteristic found but notify not supported');
                _setState('Connected (notify unsupported)');
                return;
              }
              await ch.setNotifyValue(true);
              await _notifySub?.cancel();
              _notifySub = ch.lastValueStream.listen(_onData);
              try {
                await ch.read();
              } catch (e) {
                debugPrint('[BLE] initial characteristic read failed: $e');
              }
              subscribed = true;
              debugPrint('[BLE] subscribed to alert characteristic');
              return;
            }
          }
        }
      }
      if (!subscribed) {
        debugPrint('[BLE] connected but alert service/characteristic not found');
        _setState('Connected (no alert service)');
      }
    } catch (e) {
      debugPrint('[BLE] connection error: $e');
      _setState('Connection failed');
      await Future.delayed(const Duration(seconds: 2));
      _setState('Disconnected');
      _scheduleReconnect();
    }
  }

  /// Schedule a reconnection attempt after a short backoff, unless we were
  /// explicitly disconnected by the user.
  void _scheduleReconnect() {
    if (!_autoReconnect || _disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
      if (_autoReconnect && !_disposed && _currentState == 'Disconnected') {
        debugPrint('[BLE] auto-reconnecting…');
        scanAndConnect();
      }
    });
  }

  void _onData(List<int> raw) {
    try {
      final text = utf8.decode(raw);
      // Format: "<level>|<message>"
      final pipe = text.indexOf('|');
      if (pipe < 0) {
        debugPrint('[BLE] malformed packet (no pipe): $text');
        return;
      }
      final level = int.tryParse(text.substring(0, pipe)) ?? 0;
      final message = text.substring(pipe + 1);
      _alertCtrl.add(BleAlert(level: level, message: message));
    } catch (e) {
      debugPrint('[BLE] failed to decode packet: $e');
    }
  }

  /// Disconnect from the current device. Disables auto-reconnect.
  Future<void> disconnect() async {
    _autoReconnect = false;
    _reconnectTimer?.cancel();
    await _notifySub?.cancel();
    _notifySub = null;
    await _connSub?.cancel();
    _connSub = null;
    await _device?.disconnect();
    _device = null;
    _setState('Disconnected');
  }

  /// Clean up resources.
  void dispose() {
    _disposed = true;
    _autoReconnect = false;
    _reconnectTimer?.cancel();
    _notifySub?.cancel();
    _connSub?.cancel();
    _alertCtrl.close();
    _stateCtrl.close();
  }
}
