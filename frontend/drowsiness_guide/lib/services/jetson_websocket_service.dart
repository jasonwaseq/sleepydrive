import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

class JetsonAlert {
  final String deviceId;
  final int level;
  final String message;
  final DateTime timestamp;
  final Map<String, dynamic> metadata;
  final int? fatigueRiskPercent;
  final bool? recovered;

  JetsonAlert({
    required this.deviceId,
    required this.level,
    required this.message,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
    this.fatigueRiskPercent,
    this.recovered,
  }) : timestamp = timestamp ?? DateTime.now(),
       metadata = metadata ?? const <String, dynamic>{};

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
  final Map<String, dynamic> metadata;
  final int? fatigueRiskPercent;

  JetsonPresence({
    required this.sourceId,
    required this.online,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
    this.fatigueRiskPercent,
  }) : timestamp = timestamp ?? DateTime.now(),
       metadata = metadata ?? const <String, dynamic>{};
}

class JetsonWebSocketService {
  JetsonWebSocketService({
    required Uri uri,
    Duration reconnectDelay = const Duration(seconds: 3),
  }) : _uri = uri,
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
        onError: (error) =>
            _handleSocketClosed('Connection error: ${_compactError(error)}'),
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

          final deviceId =
              (payload['device_id'] ?? payload['source_id'] ?? 'unknown')
                  .toString();

          final level = _parseLevel(
            payload['level'] ?? payload['severity'] ?? payload['risk'],
          );

          final msg = _parseMessage(
            payload['message'] ??
                payload['alert'] ??
                payload['text'] ??
                payload['msg'],
          );

          final ts = _parseTimestamp(
            payload['event_ts'] ??
                payload['received_ts'] ??
                payload['timestamp'] ??
                payload['ts'],
          );
          final metadata = _metadataFromPayload(payload);

          return JetsonAlert(
            deviceId: deviceId,
            level: level,
            message: msg,
            timestamp: ts,
            metadata: metadata,
            fatigueRiskPercent: _parseFatigueRisk(payload, metadata),
            recovered: _parseRecoveryState(payload, metadata, msg, level),
          );
        }
      } catch (_) {
        // If JSON parsing fails, continue with fallback parsing.
      }
    }

    final pipe = text.indexOf('|');
    if (pipe > 0) {
      final level = _parseLevel(text.substring(0, pipe));
      final msg = text.substring(pipe + 1).trim();

      return JetsonAlert(
        deviceId: 'unknown',
        level: level,
        message: msg.isEmpty ? 'Alert' : msg,
        timestamp: DateTime.now(),
        recovered: _parseRecoveryState(
          const <String, dynamic>{},
          const <String, dynamic>{},
          msg,
          level,
        ),
      );
    }

    return JetsonAlert(
      deviceId: 'unknown',
      level: 1,
      message: text,
      timestamp: DateTime.now(),
      recovered: _parseRecoveryState(
        const <String, dynamic>{},
        const <String, dynamic>{},
        text,
        1,
      ),
    );
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
    if (text.isEmpty || !(text.startsWith('{') && text.endsWith('}'))) {
      return null;
    }

    try {
      final decoded = _asStringDynamicMap(jsonDecode(text));
      if (decoded == null) return null;

      final type = (decoded['type'] ?? '').toString().trim().toLowerCase();
      Map<String, dynamic>? payload;
      if (type == 'jetson_presence') {
        payload = _asStringDynamicMap(decoded['data']);
      } else if (type == 'presence' ||
          type == 'status' ||
          type == 'heartbeat') {
        payload = decoded;
      } else {
        return null;
      }
      if (payload == null) return null;

      final sourceId =
          (payload['source_id'] ?? payload['device_id'] ?? 'jetson').toString();
      final online = _parseOnline(
        payload['online'] ?? payload['status'],
        defaultValue: type == 'heartbeat',
      );
      final ts = _parseTimestamp(
        payload['event_ts'] ?? payload['timestamp'] ?? payload['ts'],
      );
      final metadata = _metadataFromPayload(payload);
      return JetsonPresence(
        sourceId: sourceId,
        online: online,
        timestamp: ts,
        metadata: metadata,
        fatigueRiskPercent: _parseFatigueRisk(payload, metadata),
      );
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

  Map<String, dynamic> _metadataFromPayload(Map<String, dynamic> payload) {
    final raw = payload['metadata'];
    final metadata = raw is Map<String, dynamic>
        ? Map<String, dynamic>.from(raw)
        : raw is Map
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{};

    for (final key in const [
      'fatigue_risk_percent',
      'fatigue_risk',
      'fatigueRiskPercent',
      'fatigueRisk',
      'risk_percent',
      'riskPercent',
      'risk',
      'fatigue_score',
      'fatigueScore',
      'score',
      'event_count',
      'closed_duration_sec',
      'ear',
      'blink_ms',
    ]) {
      if (payload.containsKey(key) && !metadata.containsKey(key)) {
        metadata[key] = payload[key];
      }
    }

    return metadata;
  }

  int? _parseFatigueRisk(
    Map<String, dynamic> payload,
    Map<String, dynamic> metadata,
  ) {
    for (final key in const [
      'fatigue_risk_percent',
      'fatigue_risk',
      'fatigueRiskPercent',
      'fatigueRisk',
      'risk_percent',
      'riskPercent',
      'fatigue_score',
      'fatigueScore',
      'score',
    ]) {
      final value = _parsePercent(payload[key] ?? metadata[key]);
      if (value != null) return value;
    }

    final risk = _parsePercent(payload['risk'] ?? metadata['risk']);
    if (risk != null && risk > 2) return risk;
    return null;
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

  bool? _parseRecoveryState(
    Map<String, dynamic> payload,
    Map<String, dynamic> metadata,
    String message,
    int level,
  ) {
    const keys = [
      'recovered',
      'is_recovered',
      'has_recovered',
      'recovery',
      'recovery_state',
      'resolved',
      'is_resolved',
      'alert_active',
      'active',
      'in_alert_state',
      'alert_state',
      'state',
      'event',
      'event_type',
      'status',
    ];

    for (final key in keys) {
      final state = _parseRecoveryToken(payload[key] ?? metadata[key]);
      if (state != null) return state;
    }

    final messageState = _parseRecoveryToken(message);
    if (messageState != null) return messageState;

    if (level <= 0) return true;
    return null;
  }

  bool? _parseRecoveryToken(dynamic raw) {
    if (raw == null) return null;
    if (raw is bool) return raw;

    final text = raw.toString().trim().toLowerCase();
    if (text.isEmpty) return null;

    if (text == '1' ||
        text == 'true' ||
        text == 'yes' ||
        text == 'recovered' ||
        text == 'recovery' ||
        text == 'resolved' ||
        text == 'cleared' ||
        text == 'clear' ||
        text == 'normal' ||
        text == 'safe' ||
        text == 'inactive' ||
        text == 'ended') {
      return true;
    }

    if (text == '0' ||
        text == 'false' ||
        text == 'no' ||
        text == 'active' ||
        text == 'alert' ||
        text == 'triggered' ||
        text == 'unrecovered' ||
        text == 'ongoing') {
      return false;
    }

    if (text.contains('recover')) return true;
    if (text.contains('resolved') ||
        text.contains('clear') ||
        text.contains('back to normal') ||
        text.contains('attentive again')) {
      return true;
    }

    if (text.contains('eyes closed') ||
        text.contains('out of frame') ||
        text.contains('inattentive') ||
        text.contains('drows') ||
        text.contains('fatigue') ||
        text.contains('head down') ||
        text.contains('no face')) {
      return false;
    }

    return null;
  }

  int? _parsePercent(dynamic raw) {
    if (raw == null || raw is bool) return null;
    final text = raw.toString().trim().replaceAll('%', '');
    if (text.isEmpty) return null;
    final parsed = num.tryParse(text);
    if (parsed == null) return null;
    var value = parsed.toDouble();
    if (value < 0) value = 0;
    if (value > 0 && value <= 1) value *= 100;
    return value.round().clamp(0, 100).toInt();
  }

  bool _parseOnline(dynamic raw, {bool defaultValue = true}) {
    if (raw is bool) return raw;
    if (raw == null) return defaultValue;
    final text = raw.toString().trim().toLowerCase();
    if (text == 'online' || text == 'up' || text == 'connected') return true;
    if (text == 'offline' || text == 'down' || text == 'disconnected') {
      return false;
    }
    if (text == 'true' || text == '1' || text == 'yes' || text == 'on') {
      return true;
    }
    if (text == 'false' || text == '0' || text == 'no' || text == 'off') {
      return false;
    }
    return defaultValue;
  }

  String _parseMessage(dynamic raw) {
    if (raw == null) return 'Alert';
    final text = raw.toString().trim();
    return text.isEmpty ? 'Alert' : text;
  }

  DateTime _parseTimestamp(dynamic raw) {
    if (raw is DateTime) return raw;
    if (raw is int) {
      return DateTime.fromMillisecondsSinceEpoch(raw, isUtc: true).toLocal();
    }
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
