import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// UUIDs must match the Jetson's config.py
const _serviceUuid = "12345678-1234-5678-1234-56789abcdef0";
const _charUuid    = "12345678-1234-5678-1234-56789abcdef1";
const _deviceName  = "SleepyDrive";

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

  void _setState(String s) {
    _currentState = s;
    _stateCtrl.add(s);
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

  /// Scan for the SleepyDrive device and connect.
  Future<void> scanAndConnect() async {
    if (!await FlutterBluePlus.isSupported) {
      _setState('BLE unsupported');
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

    // Listen for scan results
    BluetoothDevice? found;
    Object? scanError;
    final scanSub = FlutterBluePlus.onScanResults.listen(
      (results) {
        for (final r in results) {
          if (_matchesDevice(r)) {
            found = r.device;
          }
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        scanError = error;
      },
    );

    try {
      await FlutterBluePlus.startScan(
        withServices: [Guid(_serviceUuid)],
        timeout: const Duration(seconds: 8),
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
      _setState('Scan failed');
      await Future.delayed(const Duration(seconds: 2));
      _setState('Disconnected');
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
      return;
    }

    _setState('Connecting…');

    try {
      await found!.connect(timeout: const Duration(seconds: 10));
      _device = found;

      // Listen for disconnection
      _connSub = found!.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _setState('Disconnected');
          _notifySub?.cancel();
        }
      });

      _setState('Connected');

      // Discover services and subscribe
      final services = await found!.discoverServices();
      for (final svc in services) {
        if (svc.uuid.toString().toLowerCase() == _serviceUuid) {
          for (final ch in svc.characteristics) {
            if (ch.uuid.toString().toLowerCase() == _charUuid) {
              await ch.setNotifyValue(true);
              _notifySub = ch.onValueReceived.listen(_onData);
              return;
            }
          }
        }
      }
      // If we get here, service/char not found
      _setState('Connected (no alert service)');
    } catch (e) {
      _setState('Connection failed');
      await Future.delayed(const Duration(seconds: 2));
      _setState('Disconnected');
    }
  }

  void _onData(List<int> raw) {
    try {
      final text = utf8.decode(raw);
      // Format: "<level>|<message>"
      final pipe = text.indexOf('|');
      if (pipe < 0) return;
      final level = int.tryParse(text.substring(0, pipe)) ?? 0;
      final message = text.substring(pipe + 1);
      _alertCtrl.add(BleAlert(level: level, message: message));
    } catch (_) {
      // ignore malformed data
    }
  }

  /// Disconnect from the current device.
  Future<void> disconnect() async {
    await _notifySub?.cancel();
    await _connSub?.cancel();
    await _device?.disconnect();
    _device = null;
    _setState('Disconnected');
  }

  /// Clean up resources.
  void dispose() {
    _notifySub?.cancel();
    _connSub?.cancel();
    _alertCtrl.close();
    _stateCtrl.close();
  }
}
