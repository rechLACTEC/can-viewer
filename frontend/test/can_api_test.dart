import 'dart:convert';

import 'package:can_viewer/config/app_config.dart';
import 'package:can_viewer/data/can_api.dart';
import 'package:can_viewer/domain/can_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'sends FD create, direct filter request and optional TX token',
    () async {
      final client = MockClient((request) async {
        final body = request.body.isEmpty
            ? <String, Object?>{}
            : jsonDecode(request.body) as Map<String, Object?>;
        if (request.url.path.endsWith('/sessions')) {
          expect(body['fd'], isTrue);
          return _sessionResponse(filterRevision: 1, fd: true);
        }
        if (request.url.path.endsWith('/filters')) {
          expect(body['filter'], isNull);
          expect(body['mode'], 'filtered');
          return _sessionResponse(filterRevision: 2, fd: true);
        }
        if (request.url.path.endsWith('/frames')) {
          expect(request.headers['X-CAN-TX-Token'], 'secret');
          return http.Response('{"status":"submitted"}', 202);
        }
        return http.Response('not found', 404);
      });
      final api = HttpCanApi(
        config: AppConfig(apiBaseUri: Uri.parse('http://localhost:8000')),
        client: client,
      );

      final session = await api.connect(
        interfaceName: 'vcan0',
        isFd: true,
        mode: CanFilterMode.all,
        ids: const [],
      );
      final updated = await api.updateFilters(
        session.id,
        mode: CanFilterMode.filtered,
        ids: const [CanFilterId(canId: 0x123, isExtended: false)],
      );
      await api.sendFrame(
        session.id,
        canId: 0x123,
        isExtended: false,
        isFd: true,
        dataHex: '01 02',
        authorizationToken: 'secret',
      );
      expect(updated.filterRevision, 2);
      api.close();
    },
  );
}

http.Response _sessionResponse({
  required int filterRevision,
  required bool fd,
}) {
  return http.Response(
    jsonEncode({
      'id': 'session-1',
      'interface': 'vcan0',
      'fd': fd,
      'filter_revision': filterRevision,
    }),
    200,
  );
}
