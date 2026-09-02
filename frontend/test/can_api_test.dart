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

  test('serializes multi-message transmission and custom CRC', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/api/v1/can/sessions/session-1/transmissions');
      expect(request.headers['X-CAN-TX-Token'], 'secret');
      final body = jsonDecode(request.body) as Map<String, Object?>;
      final messages = body['messages'] as List<Object?>;
      expect(messages, hasLength(2));
      final cyclic = messages.first as Map<String, Object?>;
      expect(cyclic['mode'], 'cyclic');
      expect(cyclic['period_ms'], 50.0);
      expect(cyclic['crc'], {
        'algorithm': 'CUSTOM',
        'range_start': 0,
        'range_end': 2,
        'position': 3,
        'byte_order': 'big',
        'width': 8,
        'polynomial': 0x1D,
        'initial_value': 0xFF,
        'xor_out': 0xFF,
        'reflect_input': false,
        'reflect_output': false,
      });
      return http.Response(jsonEncode(_transmissionResponse()), 201);
    });
    final api = HttpCanApi(
      config: AppConfig(apiBaseUri: Uri.parse('http://localhost:8000')),
      client: client,
    );

    final status = await api.configureTransmission('session-1', const [
      CanTransmissionMessageConfig(
        messageId: 'cyclic',
        enabled: true,
        canId: 0x181,
        isExtended: false,
        isFd: false,
        dataHex: '01 02 03 00',
        mode: CanTransmissionMode.cyclic,
        periodMs: 50,
        crc: CanCrcConfig(
          algorithm: 'CUSTOM',
          rangeStart: 0,
          rangeEnd: 2,
          position: 3,
          width: 8,
          polynomial: 0x1D,
          initialValue: 0xFF,
          xorOut: 0xFF,
          reflectInput: false,
          reflectOutput: false,
        ),
      ),
      CanTransmissionMessageConfig(
        messageId: 'single',
        enabled: true,
        canId: 0x281,
        isExtended: false,
        isFd: false,
        dataHex: 'AA',
        mode: CanTransmissionMode.single,
      ),
    ], authorizationToken: 'secret');

    expect(status.messages, hasLength(2));
    expect(status.estimatedBusLoadPercent, 0.25);
    api.close();
  });
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

Map<String, Object?> _transmissionResponse() => {
  'plan_id': 'plan-1',
  'session_id': 'session-1',
  'interface': 'vcan0',
  'state': 'stopped',
  'sent_frames': 0,
  'send_errors': 0,
  'deadline_misses': 0,
  'estimated_bus_load_percent': 0.25,
  'messages': [
    for (final id in ['cyclic', 'single'])
      {
        'message_id': id,
        'state': 'stopped',
        'sent_frames': 0,
        'send_errors': 0,
        'deadline_misses': 0,
        'last_transmission': null,
        'last_error': null,
      },
  ],
};
