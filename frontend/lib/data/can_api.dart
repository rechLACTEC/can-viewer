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
  Future<CanFrame?> sendFrame(
    String sessionId, {
    required int canId,
    required bool isExtended,
    required bool isFd,
    required String dataHex,
    String? authorizationToken,
  });
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
  Future<CanFrame?> sendFrame(
    String sessionId, {
    required int canId,
    required bool isExtended,
    required bool isFd,
    required String dataHex,
    String? authorizationToken,
  }) async {
    final response = await _client
        .post(
          _config.resolve('/api/v1/can/sessions/$sessionId/frames'),
          headers: {
            ..._jsonHeaders,
            if (authorizationToken != null && authorizationToken.isNotEmpty)
              'X-CAN-TX-Token': authorizationToken,
          },
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
  'mode': mode == CanFilterMode.all ? 'all' : 'filtered',
  'ids': ids.map((id) => id.toJson()).toList(growable: false),
};
