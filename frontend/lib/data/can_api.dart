import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../domain/can_models.dart';

class CanApiException implements Exception {
  const CanApiException(this.message, {this.code, this.statusCode});

  final String message;
  final String? code;
  final int? statusCode;

  @override
  String toString() => message;
}

abstract interface class CanApi {
  Future<List<CanInterfaceInfo>> listInterfaces();
  Future<CanSession> connect({
    required String interfaceName,
    required bool isFd,
    required CanFilterMode mode,
    required List<CanFilterId> ids,
  });
  Future<CanSession> updateFilters(
    String sessionId, {
    required CanFilterMode mode,
    required List<CanFilterId> ids,
  });
  Future<void> disconnect(String sessionId);
  Future<bool> getPhysicalTxEnabled();
  Future<bool> setPhysicalTxEnabled(bool enabled);
  Future<CanFrame?> sendFrame(
    String sessionId, {
    required int canId,
    required bool isExtended,
    required bool isFd,
    required String dataHex,
  });
  Future<CanRecording> startRecording(String sessionId);
  Future<CanRecording> getRecording(String sessionId, String recordingId);
  Future<CanRecording> pauseRecording(String sessionId, String recordingId);
  Future<CanRecording> resumeRecording(String sessionId, String recordingId);
  Future<CanRecording> stopRecording(String sessionId, String recordingId);
  Uri recordingDownloadUri(String recordingId);
  Future<CanTransmissionPreview> previewTransmission(
    String sessionId,
    CanTransmissionMessageConfig message,
  );
  Future<CanTransmissionStatus> configureTransmission(
    String sessionId,
    List<CanTransmissionMessageConfig> messages,
  );
  Future<CanTransmissionStatus> sendTransmissionOnce(
    String sessionId,
    List<CanTransmissionMessageConfig> messages,
  );
  Future<CanTransmissionStatus> startTransmission(
    String sessionId,
    String planId,
  );
  Future<CanTransmissionStatus> getTransmission(
    String sessionId,
    String planId,
  );
  Future<CanTransmissionStatus> pauseTransmission(
    String sessionId,
    String planId,
  );
  Future<CanTransmissionStatus> resumeTransmission(
    String sessionId,
    String planId,
  );
  Future<CanTransmissionStatus> stopTransmission(
    String sessionId,
    String planId,
  );
  Future<void> stopAllTransmissions(String sessionId);
  void close();
}

class HttpCanApi implements CanApi {
  HttpCanApi({required AppConfig config, http.Client? client})
    : _config = config,
      _client = client ?? http.Client();

  final AppConfig _config;
  final http.Client _client;

  @override
  Future<List<CanInterfaceInfo>> listInterfaces() async {
    final response = await _client
        .get(_config.resolve('/api/v1/can/interfaces'))
        .timeout(const Duration(seconds: 8));
    final json = _decode(response);
    final values = json['interfaces'];
    if (values is! List) {
      throw const FormatException('Lista de interfaces inválida.');
    }
    return values
        .map((item) {
          if (item is! Map<String, Object?>) {
            throw const FormatException('Interface inválida.');
          }
          return CanInterfaceInfo.fromJson(item);
        })
        .toList(growable: false);
  }

  @override
  Future<CanSession> connect({
    required String interfaceName,
    required bool isFd,
    required CanFilterMode mode,
    required List<CanFilterId> ids,
  }) async {
    final response = await _client
        .post(
          _config.resolve('/api/v1/can/sessions'),
          headers: _jsonHeaders,
          body: jsonEncode({
            'interface': interfaceName,
            'fd': isFd,
            'filter': _filterJson(mode, ids),
          }),
        )
        .timeout(const Duration(seconds: 10));
    return CanSession.fromJson(_decode(response));
  }

  @override
  Future<CanSession> updateFilters(
    String sessionId, {
    required CanFilterMode mode,
    required List<CanFilterId> ids,
  }) async {
    final response = await _client
        .put(
          _config.resolve('/api/v1/can/sessions/$sessionId/filters'),
          headers: _jsonHeaders,
          body: jsonEncode(_filterJson(mode, ids)),
        )
        .timeout(const Duration(seconds: 8));
    return CanSession.fromJson(_decode(response));
  }

  @override
  Future<void> disconnect(String sessionId) async {
    final response = await _client
        .delete(_config.resolve('/api/v1/can/sessions/$sessionId'))
        .timeout(const Duration(seconds: 8));
    _decode(response, allowEmpty: true);
  }

  @override
  Future<bool> getPhysicalTxEnabled() => _physicalTxRequest();

  @override
  Future<bool> setPhysicalTxEnabled(bool enabled) =>
      _physicalTxRequest(enabled: enabled);

  Future<bool> _physicalTxRequest({bool? enabled}) async {
    final uri = _config.resolve('/api/v1/can/tx-enabled');
    final response =
        await (enabled == null
                ? _client.get(uri, headers: _jsonHeaders)
                : _client.put(
                    uri,
                    headers: _jsonHeaders,
                    body: jsonEncode({'enabled': enabled}),
                  ))
            .timeout(const Duration(seconds: 8));
    final value = _decode(response)['enabled'];
    if (value is! bool) {
      throw const FormatException('Estado de transmissão física inválido.');
    }
    return value;
  }

  @override
  Future<CanFrame?> sendFrame(
    String sessionId, {
    required int canId,
    required bool isExtended,
    required bool isFd,
    required String dataHex,
  }) async {
    final response = await _client
        .post(
          _config.resolve('/api/v1/can/sessions/$sessionId/frames'),
          headers: _jsonHeaders,
          body: jsonEncode({
            'can_id': canId,
            'is_extended_id': isExtended,
            'is_fd': isFd,
            'data_hex': dataHex.replaceAll(RegExp(r'\s+'), '').toUpperCase(),
          }),
        )
        .timeout(const Duration(seconds: 8));
    final json = _decode(response, allowEmpty: true);
    final frame = json['frame'];
    return frame is Map<String, Object?> ? CanFrame.fromJson(frame) : null;
  }

  @override
  Future<CanRecording> startRecording(String sessionId) => _recordingRequest(
    '/api/v1/can/sessions/$sessionId/recordings',
    method: 'POST',
  );

  @override
  Future<CanRecording> getRecording(String sessionId, String recordingId) =>
      _recordingRequest(
        '/api/v1/can/sessions/$sessionId/recordings/$recordingId',
      );

  @override
  Future<CanRecording> pauseRecording(String sessionId, String recordingId) =>
      _recordingRequest(
        '/api/v1/can/sessions/$sessionId/recordings/$recordingId/pause',
        method: 'POST',
      );

  @override
  Future<CanRecording> resumeRecording(String sessionId, String recordingId) =>
      _recordingRequest(
        '/api/v1/can/sessions/$sessionId/recordings/$recordingId/resume',
        method: 'POST',
      );

  @override
  Future<CanRecording> stopRecording(String sessionId, String recordingId) =>
      _recordingRequest(
        '/api/v1/can/sessions/$sessionId/recordings/$recordingId/stop',
        method: 'POST',
      );

  @override
  Uri recordingDownloadUri(String recordingId) =>
      _config.resolve('/api/v1/can/recordings/$recordingId/download');

  @override
  Future<CanTransmissionPreview> previewTransmission(
    String sessionId,
    CanTransmissionMessageConfig message,
  ) async {
    final response = await _client
        .post(
          _config.resolve(
            '/api/v1/can/sessions/$sessionId/transmissions/preview',
          ),
          headers: _jsonHeaders,
          body: jsonEncode(message.toJson()),
        )
        .timeout(const Duration(seconds: 8));
    return CanTransmissionPreview.fromJson(_decode(response));
  }

  @override
  Future<CanTransmissionStatus> configureTransmission(
    String sessionId,
    List<CanTransmissionMessageConfig> messages,
  ) => _transmissionRequest(
    '/api/v1/can/sessions/$sessionId/transmissions',
    body: {'messages': messages.map((item) => item.toJson()).toList()},
  );

  @override
  Future<CanTransmissionStatus> sendTransmissionOnce(
    String sessionId,
    List<CanTransmissionMessageConfig> messages,
  ) => _transmissionRequest(
    '/api/v1/can/sessions/$sessionId/transmissions/send-once',
    body: {'messages': messages.map((item) => item.toJson()).toList()},
  );

  @override
  Future<CanTransmissionStatus> startTransmission(
    String sessionId,
    String planId,
  ) => _transmissionRequest(
    '/api/v1/can/sessions/$sessionId/transmissions/$planId/start',
  );

  @override
  Future<CanTransmissionStatus> getTransmission(
    String sessionId,
    String planId,
  ) => _transmissionRequest(
    '/api/v1/can/sessions/$sessionId/transmissions/$planId',
    method: 'GET',
  );

  @override
  Future<CanTransmissionStatus> pauseTransmission(
    String sessionId,
    String planId,
  ) => _transmissionRequest(
    '/api/v1/can/sessions/$sessionId/transmissions/$planId/pause',
  );

  @override
  Future<CanTransmissionStatus> resumeTransmission(
    String sessionId,
    String planId,
  ) => _transmissionRequest(
    '/api/v1/can/sessions/$sessionId/transmissions/$planId/resume',
  );

  @override
  Future<CanTransmissionStatus> stopTransmission(
    String sessionId,
    String planId,
  ) => _transmissionRequest(
    '/api/v1/can/sessions/$sessionId/transmissions/$planId/stop',
  );

  @override
  Future<void> stopAllTransmissions(String sessionId) async {
    final response = await _client
        .post(
          _config.resolve(
            '/api/v1/can/sessions/$sessionId/transmissions/stop-all',
          ),
          headers: _jsonHeaders,
        )
        .timeout(const Duration(seconds: 8));
    _decode(response);
  }

  Future<CanTransmissionStatus> _transmissionRequest(
    String path, {
    String method = 'POST',
    Map<String, Object?>? body,
  }) async {
    final uri = _config.resolve(path);
    final headers = _jsonHeaders;
    final response =
        await (method == 'GET'
                ? _client.get(uri, headers: headers)
                : _client.post(
                    uri,
                    headers: headers,
                    body: body == null ? null : jsonEncode(body),
                  ))
            .timeout(const Duration(seconds: 10));
    return CanTransmissionStatus.fromJson(_decode(response));
  }

  Future<CanRecording> _recordingRequest(
    String path, {
    String method = 'GET',
  }) async {
    final uri = _config.resolve(path);
    final response =
        await (method == 'POST'
                ? _client.post(uri, headers: _jsonHeaders)
                : _client.get(uri, headers: _jsonHeaders))
            .timeout(const Duration(seconds: 15));
    return CanRecording.fromJson(_decode(response));
  }

  @override
  void close() => _client.close();

  Map<String, Object?> _decode(
    http.Response response, {
    bool allowEmpty = false,
  }) {
    Map<String, Object?> json = const {};
    if (response.body.isNotEmpty) {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('Resposta JSON deve ser um objeto.');
      }
      json = decoded;
    } else if (!allowEmpty) {
      throw const FormatException('Resposta vazia do backend.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw CanApiException(
        json['detail'] as String? ?? 'Falha HTTP ${response.statusCode}.',
        code: json['code'] as String?,
        statusCode: response.statusCode,
      );
    }
    return json;
  }
}

const _jsonHeaders = {
  'Accept': 'application/json, application/problem+json',
  'Content-Type': 'application/json',
};

Map<String, Object> _filterJson(CanFilterMode mode, List<CanFilterId> ids) => {
  'mode': mode.name,
  'ids': (mode == CanFilterMode.all ? const <CanFilterId>[] : ids)
      .map((id) => id.toJson())
      .toList(growable: false),
};
