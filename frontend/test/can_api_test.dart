import 'dart:convert';

import 'package:can_viewer/config/app_config.dart';
import 'package:can_viewer/data/can_api.dart';
import 'package:can_viewer/domain/can_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('sends FD create, direct filter request and CAN frame', () async {
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
        expect(body['mode'], 'whitelist');
        return _sessionResponse(filterRevision: 2, fd: true);
      }
      if (request.url.path.endsWith('/frames')) {
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
      mode: CanFilterMode.whitelist,
      ids: const [CanFilterId(canId: 0x123, isExtended: false)],
    );
    await api.sendFrame(
      session.id,
      canId: 0x123,
      isExtended: false,
      isFd: true,
      dataHex: '01 02',
    );
    expect(updated.filterRevision, 2);
    api.close();
  });

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

  test('serializes blacklist with exact standard and extended IDs', () async {
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      expect(body['mode'], 'blacklist');
      expect(body['ids'], [
        {'can_id': 0x123, 'is_extended_id': false},
        {'can_id': 0x123, 'is_extended_id': true},
      ]);
      return _sessionResponse(filterRevision: 3);
    });
    final api = HttpCanApi(
      config: AppConfig(apiBaseUri: Uri.parse('http://localhost:8000')),
      client: client,
    );

    await api.updateFilters(
      'session-1',
      mode: CanFilterMode.blacklist,
      ids: const [
        CanFilterId(canId: 0x123, isExtended: false),
        CanFilterId(canId: 0x123, isExtended: true),
      ],
    );
    api.close();
  });

  test('reads and updates the physical TX runtime state', () async {
    var enabled = false;
    final client = MockClient((request) async {
      expect(request.url.path, '/api/v1/can/tx-enabled');
      if (request.method == 'PUT') {
        final body = jsonDecode(request.body) as Map<String, Object?>;
        enabled = body['enabled'] as bool;
      }
      return http.Response(jsonEncode({'enabled': enabled}), 200);
    });
    final api = HttpCanApi(
      config: AppConfig(apiBaseUri: Uri.parse('http://localhost:8000')),
      client: client,
    );

    expect(await api.getPhysicalTxEnabled(), isFalse);
    expect(await api.setPhysicalTxEnabled(true), isTrue);
    expect(await api.getPhysicalTxEnabled(), isTrue);
    api.close();
  });

  test('serializes transmission counter and custom CRC', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/api/v1/can/sessions/session-1/transmissions');
      final body = jsonDecode(request.body) as Map<String, Object?>;
      final messages = body['messages'] as List<Object?>;
      expect(messages, hasLength(2));
      final cyclic = messages.first as Map<String, Object?>;
      expect(cyclic['mode'], 'cyclic');
      expect(cyclic['period_ms'], 50.0);
      expect(cyclic['counter'], {
        'enabled': true,
        'bit_offset': 4,
        'bit_length': 4,
        'initial_value': 2,
        'increment': 3,
      });
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
        counter: CanCounterConfig(
          bitOffset: 4,
          bitLength: 4,
          initialValue: 2,
          increment: 3,
        ),
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
    ]);

    expect(status.messages, hasLength(2));
    expect(status.estimatedBusLoadPercent, 0.25);
    expect(status.messages.first.configuredFrequencyHz, 200);
    expect(status.messages.first.effectiveFrequencyHz, 198.5);
    api.close();
  });
}

http.Response _sessionResponse({required int filterRevision, bool fd = false}) {
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
        'configured_frequency_hz': id == 'cyclic' ? 200.0 : null,
        'effective_frequency_hz': id == 'cyclic' ? 198.5 : null,
        'last_transmission': null,
        'last_error': null,
      },
  ],
};
