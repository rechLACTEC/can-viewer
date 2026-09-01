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

  test(
    'controls recording lifecycle and exposes streaming download URL',
    () async {
      final calls = <String>[];
      final client = MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        final state = request.url.path.endsWith('/pause')
            ? 'paused'
            : request.url.path.endsWith('/stop')
            ? 'completed'
            : 'recording';
        return http.Response(jsonEncode(_recordingResponse(state)), 200);
      });
      final api = HttpCanApi(
        config: AppConfig(apiBaseUri: Uri.parse('http://localhost:8000')),
        client: client,
      );

      final started = await api.startRecording('session-1');
      await api.getRecording('session-1', started.recordingId);
      final paused = await api.pauseRecording('session-1', started.recordingId);
      await api.resumeRecording('session-1', started.recordingId);
      final completed = await api.stopRecording(
        'session-1',
        started.recordingId,
      );

      expect(paused.state, CanRecordingState.paused);
      expect(completed.state, CanRecordingState.completed);
      expect(calls, contains('POST /api/v1/can/sessions/session-1/recordings'));
      expect(
        api.recordingDownloadUri(started.recordingId).toString(),
        'http://localhost:8000/api/v1/can/recordings/recording-1/download',
      );
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

Map<String, Object?> _recordingResponse(String state) => {
  'state': state,
  'recording_id': 'recording-1',
  'session_id': 'session-1',
  'interface': 'vcan0',
  'started_at': '2026-09-01T15:42:18Z',
  'completed_at': state == 'completed' ? '2026-09-01T15:43:00Z' : null,
  'recorded_frames': 8,
  'unsupported_frames': 0,
  'unsupported_can_fd': 0,
  'unsupported_remote_frames': 0,
  'unsupported_error_frames': 0,
  'dropped_frames': 0,
  'size_bytes': 2048,
  'degraded': false,
  'filename': 'vcan0_recording-1.trc',
  'error': null,
};
