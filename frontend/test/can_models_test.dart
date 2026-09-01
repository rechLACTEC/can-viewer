import 'package:can_viewer/config/app_config.dart';
import 'package:can_viewer/data/can_stream.dart';
import 'package:can_viewer/domain/can_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CAN models', () {
    test('preserves nanosecond timestamp and renders bytes by byte', () {
      final frame = CanFrame.fromJson({
        'sequence': 7,
        'filter_revision': 2,
        'timestamp_ns': '9007199254740993123',
        'ingress_monotonic_ns': '123456789',
        'interface': 'vcan0',
        'can_id': 0x123,
        'is_extended_id': false,
        'is_fd': false,
        'dlc': 3,
        'data_hex': '010AFF',
        'direction': 'rx',
      });

      expect(frame.timestampNanoseconds, BigInt.parse('9007199254740993123'));
      expect(frame.hexText, '01 0A FF');
      expect(frame.binaryText, '00000001 00001010 11111111');
      expect(frame.idText, '0x123');
      expect(frame.sequence, 7);
      expect(frame.filterRevision, 2);
      expect(frame.timingNanoseconds, BigInt.from(123456789));
    });

    test('validates standard and extended identifier boundaries', () {
      expect(parseCanId('0x7ff', extended: false), 0x7ff);
      expect(parseCanId('18FF50E5', extended: true), 0x18FF50E5);
      expect(
        () => parseCanId('800', extended: false),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects malformed hexadecimal payload', () {
      expect(() => parseHexBytes('0'), throwsA(isA<FormatException>()));
      expect(() => parseHexBytes('GG'), throwsA(isA<FormatException>()));
    });

    test('renders every payload byte with exactly eight binary digits', () {
      final frame = CanFrame.fromJson({
        'sequence': 1,
        'filter_revision': 1,
        'timestamp_ns': '1',
        'ingress_monotonic_ns': '1',
        'interface': 'vcan0',
        'can_id': 1,
        'is_extended_id': false,
        'is_fd': false,
        'dlc': 4,
        'data_hex': '00FF0180',
        'direction': 'rx',
      });

      expect(frame.hexText, '00 FF 01 80');
      expect(frame.binaryText, '00000000 11111111 00000001 10000000');
    });

    test('matches backend CAN and CAN FD payload lengths', () {
      expect(validatePayloadLength(8, isFd: false), isNull);
      expect(validatePayloadLength(9, isFd: false), isNotNull);
      expect(validatePayloadLength(12, isFd: true), isNull);
      expect(validatePayloadLength(10, isFd: true), isNotNull);
      expect(validatePayloadLength(64, isFd: true), isNull);
    });

    test('parses versioned WS envelope counters', () {
      final batch = parseCanFrameBatch({
        'version': 1,
        'type': 'frames',
        'stream_dropped_frames': 2,
        'adapter_dropped_frames': 3,
        'frames': [
          {
            'sequence': 9,
            'filter_revision': 4,
            'timestamp_ns': '1000',
            'ingress_monotonic_ns': '900',
            'interface': 'vcan0',
            'can_id': 1,
            'is_extended_id': false,
            'is_fd': false,
            'dlc': 0,
            'data_hex': '',
            'direction': 'rx',
          },
        ],
      });
      expect(batch.frames.single.sequence, 9);
      expect(batch.frames.single.filterRevision, 4);
      expect(batch.streamDroppedFrames, 2);
      expect(batch.adapterDroppedFrames, 3);
    });

    test('rejects non HTTP(S) API base URLs', () {
      expect(
        () => AppConfig(apiBaseUri: Uri.parse('ftp://localhost/service')),
        throwsA(isA<FormatException>()),
      );
      expect(
        AppConfig(
          apiBaseUri: Uri.parse('https://example.test'),
        ).webSocket('/ws').scheme,
        'wss',
      );
    });

    test('accepts final backend interface and session fields', () {
      final interface = CanInterfaceInfo.fromJson({
        'name': 'can0',
        'kind': 'can',
        'operational_state': 'up',
        'bitrate': 500000,
        'fd_capable': true,
      });
      final session = CanSession.fromJson({
        'id': 'abc',
        'interface': 'can0',
        'fd': true,
        'filter_revision': 3,
      });
      expect(interface.isUp, isTrue);
      expect(interface.type, 'can');
      expect(session.id, 'abc');
      expect(session.isFd, isTrue);
      expect(session.filterRevision, 3);
    });
  });
}
