import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

class JetsonAlert {
  final int level;
  final String message;
  final DateTime timestamp;

  JetsonAlert({
    required this.level,
    required this.message,
  }) : timestamp = DateTime.now();

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

class JetsonWebSocketService {
  JetsonWebSocketService({
    required Uri uri,
    Duration reconnectDelay = const Duration(seconds: 3),
  })  : _uri = uri,
        _reconnectDelay = reconnectDelay;

  final Uri _uri;
  final Duration _reconnectDelay;

  WebSocketChannel? _channel;
  StreamSubscription? _socketSub;
  Timer? _reconnectTimer;

  final _alertCtrl = StreamController<JetsonAlert>.broadcast();
  final _stateCtrl = StreamController<String>.broadcast();

  bool _disposed = false;
  bool _manualDisconnect = false;
  String _currentState = 'Disconnected';

  Stream<JetsonAlert> get alerts => _alertCtrl.stream;
  Stream<String> get connectionState => _stateCtrl.stream;
  String get currentState => _currentState;

  void _setState(String state) {
    _currentState = state;
    if (!_stateCtrl.isClosed) {
      _stateCtrl.add(state);
    }
  }

  Future<void> connect() async {
    if (_disposed) return;
    if (_currentState == 'Connected' || _currentState == 'Connecting…') return;

    _manualDisconnect = false;
    _reconnectTimer?.cancel();
    await _socketSub?.cancel();
    await _channel?.sink.close();
    _channel = null;

    _setState('Connecting…');

    try {
      final channel = WebSocketChannel.connect(_uri);
      _channel = channel;
      await channel.ready.timeout(const Duration(seconds: 8));
      if (_disposed || _manualDisconnect) {
        await channel.sink.close();
        return;
      }
      _setState('Connected');

      _socketSub = channel.stream.listen(
        _onMessage,
        onError: (error) => _handleSocketClosed(
          'Connection error: ${_compactError(error)}',
        ),
        onDone: () => _handleSocketClosed('Disconnected'),
        cancelOnError: false,
      );
    } catch (e) {
      _handleSocketClosed('Connection failed: ${_compactError(e)}');
    }
  }

  void _handleSocketClosed(String terminalState) {
    if (_disposed) return;

    _setState(terminalState);
    _socketSub?.cancel();
    _channel?.sink.close();
    _socketSub = null;
    _channel = null;

    if (_manualDisconnect) {
      _setState('Disconnected');
      return;
    }

    _setState('Reconnecting… ($terminalState)');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_reconnectDelay, () {
      if (!_disposed && !_manualDisconnect) {
        connect();
      }
    });
  }

  void _onMessage(dynamic raw) {
    try {
      final alert = _parseAlert(raw);
      if (alert != null && !_alertCtrl.isClosed) {
        _alertCtrl.add(alert);
      }
    } catch (_) {
      // Ignore malformed frame payloads to keep stream alive.
    }
  }

  JetsonAlert? _parseAlert(dynamic raw) {
    if (raw == null) return null;

    String text;
    if (raw is String) {
      text = raw.trim();
    } else if (raw is List<int>) {
      text = utf8.decode(raw, allowMalformed: true).trim();
    } else {
      text = raw.toString().trim();
    }

    if (text.isEmpty) return null;

    if (text.startsWith('{') && text.endsWith('}')) {
      try {
        final obj = jsonDecode(text);
        if (obj is Map<String, dynamic>) {
          final level = _parseLevel(obj['level'] ?? obj['severity'] ?? obj['risk']);
          final msg = _parseMessage(
            obj['message'] ?? obj['alert'] ?? obj['text'] ?? obj['msg'],
          );
          return JetsonAlert(level: level, message: msg);
        }
      } catch (_) {
        // If JSON parsing fails, continue with fallback parsing.
      }
    }

    final pipe = text.indexOf('|');
    if (pipe > 0) {
      final level = _parseLevel(text.substring(0, pipe));
      final msg = text.substring(pipe + 1).trim();
      return JetsonAlert(level: level, message: msg.isEmpty ? 'Alert' : msg);
    }

    return JetsonAlert(level: 1, message: text);
  }

  int _parseLevel(dynamic raw) {
    if (raw == null) return 1;
    if (raw is int) return raw;

    final text = raw.toString().trim().toLowerCase();
    final asInt = int.tryParse(text);
    if (asInt != null) return asInt;

    switch (text) {
      case 'safe':
      case 'normal':
      case 'info':
        return 0;
      case 'warning':
      case 'warn':
      case 'caution':
        return 1;
      case 'danger':
      case 'critical':
      case 'alert':
        return 2;
      default:
        return 1;
    }
  }

  String _parseMessage(dynamic raw) {
    if (raw == null) return 'Alert';
    final text = raw.toString().trim();
    return text.isEmpty ? 'Alert' : text;
  }

  String _compactError(Object error) {
    final text = error.toString().replaceAll('\n', ' ').trim();
    if (text.isEmpty) return 'unknown';
    if (text.length <= 90) return text;
    return '${text.substring(0, 90)}…';
  }

  Future<void> disconnect() async {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    await _socketSub?.cancel();
    await _channel?.sink.close();
    _socketSub = null;
    _channel = null;
    _setState('Disconnected');
  }

  void dispose() {
    _disposed = true;
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _socketSub?.cancel();
    _channel?.sink.close();
    _alertCtrl.close();
    _stateCtrl.close();
  }
}
