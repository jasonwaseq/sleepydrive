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
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

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

class JetsonPresence {
  final String sourceId;
  final bool online;
  final DateTime timestamp;

  JetsonPresence({
    required this.sourceId,
    required this.online,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
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
  final _presenceCtrl = StreamController<JetsonPresence>.broadcast();
  final _stateCtrl = StreamController<String>.broadcast();

  bool _disposed = false;
  bool _manualDisconnect = false;
  String _currentState = 'Disconnected';

  Stream<JetsonAlert> get alerts => _alertCtrl.stream;
  Stream<JetsonPresence> get presence => _presenceCtrl.stream;
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
      final presence = _parsePresence(raw);
      if (presence != null && !_presenceCtrl.isClosed) {
        _presenceCtrl.add(presence);
      }

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
        final decoded = _asStringDynamicMap(obj);
        if (decoded != null) {
          final payload = _extractAlertPayload(decoded);
          if (payload == null) return null;

          final level = _parseLevel(payload['level'] ?? payload['severity'] ?? payload['risk']);
          final msg = _parseMessage(
            payload['message'] ?? payload['alert'] ?? payload['text'] ?? payload['msg'],
          );
          final ts = _parseTimestamp(payload['event_ts'] ?? payload['received_ts'] ?? payload['timestamp'] ?? payload['ts']);
          return JetsonAlert(level: level, message: msg, timestamp: ts);
        }
      } catch (_) {
        // If JSON parsing fails, continue with fallback parsing.
      }
    }

    final pipe = text.indexOf('|');
    if (pipe > 0) {
      final level = _parseLevel(text.substring(0, pipe));
      final msg = text.substring(pipe + 1).trim();
      return JetsonAlert(level: level, message: msg.isEmpty ? 'Alert' : msg, timestamp: DateTime.now());
    }

    return JetsonAlert(level: 1, message: text, timestamp: DateTime.now());
  }

  JetsonPresence? _parsePresence(dynamic raw) {
    if (raw == null) return null;

    String text;
    if (raw is String) {
      text = raw.trim();
    } else if (raw is List<int>) {
      text = utf8.decode(raw, allowMalformed: true).trim();
    } else {
      text = raw.toString().trim();
    }
    if (text.isEmpty || !(text.startsWith('{') && text.endsWith('}'))) return null;

    try {
      final decoded = _asStringDynamicMap(jsonDecode(text));
      if (decoded == null) return null;

      final type = (decoded['type'] ?? '').toString().trim().toLowerCase();
      Map<String, dynamic>? payload;
      if (type == 'jetson_presence') {
        payload = _asStringDynamicMap(decoded['data']);
      } else if (type == 'presence' || type == 'status' || type == 'heartbeat') {
        payload = decoded;
      } else {
        return null;
      }
      if (payload == null) return null;

      final sourceId = (payload['source_id'] ?? payload['device_id'] ?? 'jetson').toString();
      final online = _parseOnline(payload['online'] ?? payload['status'], defaultValue: type == 'heartbeat');
      final ts = _parseTimestamp(payload['event_ts'] ?? payload['timestamp'] ?? payload['ts']);
      return JetsonPresence(sourceId: sourceId, online: online, timestamp: ts);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? _asStringDynamicMap(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) {
      try {
        return Map<String, dynamic>.from(raw);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  Map<String, dynamic>? _extractAlertPayload(Map<String, dynamic> obj) {
    final typeRaw = obj['type'];
    if (typeRaw != null) {
      final type = typeRaw.toString().trim().toLowerCase();
      if (type != 'alert') {
        // Ignore non-alert frames like status/heartbeat envelopes.
        return null;
      }

      final data = _asStringDynamicMap(obj['data']);
      if (data != null) return data;
    }

    return obj;
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

  bool _parseOnline(dynamic raw, {bool defaultValue = true}) {
    if (raw is bool) return raw;
    if (raw == null) return defaultValue;
    final text = raw.toString().trim().toLowerCase();
    if (text == 'online' || text == 'up' || text == 'connected') return true;
    if (text == 'offline' || text == 'down' || text == 'disconnected') return false;
    if (text == 'true' || text == '1' || text == 'yes' || text == 'on') return true;
    if (text == 'false' || text == '0' || text == 'no' || text == 'off') return false;
    return defaultValue;
  }

  String _parseMessage(dynamic raw) {
    if (raw == null) return 'Alert';
    final text = raw.toString().trim();
    return text.isEmpty ? 'Alert' : text;
  }

  DateTime _parseTimestamp(dynamic raw) {
    if (raw is DateTime) return raw;
    if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw, isUtc: true).toLocal();
    if (raw is double) {
      final ms = (raw * 1000).round();
      return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();
    }
    if (raw != null) {
      final text = raw.toString().trim();
      if (text.isNotEmpty) {
        final parsed = DateTime.tryParse(text);
        if (parsed != null) {
          return parsed.toLocal();
        }
      }
    }
    return DateTime.now();
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
    _presenceCtrl.close();
    _stateCtrl.close();
  }
}
