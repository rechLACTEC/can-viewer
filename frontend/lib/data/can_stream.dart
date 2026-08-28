import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/app_config.dart';
import '../domain/can_models.dart';

abstract interface class CanStreamConnection {
  Stream<CanFrameBatch> get batches;
  Future<void> close();
}

abstract interface class CanStreamConnector {
  Future<CanStreamConnection> connect(String sessionId);
}

class WebSocketCanStreamConnector implements CanStreamConnector {
  WebSocketCanStreamConnector(this._config);

  final AppConfig _config;

  @override
  Future<CanStreamConnection> connect(String sessionId) async {
    final channel = WebSocketChannel.connect(
      _config.webSocket('/api/v1/can/sessions/$sessionId/stream'),
    );
    await channel.ready.timeout(const Duration(seconds: 8));
    return _WebSocketCanStreamConnection(channel);
  }
}

class _WebSocketCanStreamConnection implements CanStreamConnection {
  _WebSocketCanStreamConnection(this._channel);

  final WebSocketChannel _channel;

  @override
  Stream<CanFrameBatch> get batches => _channel.stream
      .where((message) => message is String)
      .map((message) => jsonDecode(message as String))
      .where((message) => message is Map<String, Object?>)
      .map((message) => message as Map<String, Object?>)
      .where((message) => message['type'] == 'frames')
      .map(parseCanFrameBatch);

  @override
  Future<void> close() async => _channel.sink.close(1000, 'client disconnect');
}

CanFrameBatch parseCanFrameBatch(Map<String, Object?> message) {
  final frames = message['frames'];
  if (frames is! List) throw const FormatException('Batch WS inválido.');
  final version = _counter(message, 'version');
  if (version != 1) throw FormatException('Versão WS não suportada: $version.');
  return CanFrameBatch(
    version: version,
    frames: frames
        .map((item) {
          if (item is! Map<String, Object?>) {
            throw const FormatException('Frame WS inválido.');
          }
          return CanFrame.fromJson(item);
        })
        .toList(growable: false),
    streamDroppedFrames: _counter(message, 'stream_dropped_frames'),
    adapterDroppedFrames: _counter(message, 'adapter_dropped_frames'),
  );
}

int _counter(Map<String, Object?> message, String key) {
  final value = message[key];
  if (value is! num || value < 0) {
    throw FormatException('$key ausente ou inválido.');
  }
  return value.toInt();
}
