import 'package:can_viewer/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses the browser origin for REST, WebSocket and TRC downloads', () {
    final config = AppConfig.fromEnvironment(
      pageUri: Uri.parse('http://192.168.10.42:8000/?source=lan#/transmission'),
      apiBaseUrl: '',
    );

    expect(
      config.resolve('/api/v1/can/interfaces').toString(),
      'http://192.168.10.42:8000/api/v1/can/interfaces',
    );
    expect(
      config.webSocket('/api/v1/can/sessions/session-1/stream').toString(),
      'ws://192.168.10.42:8000/api/v1/can/sessions/session-1/stream',
    );
    expect(
      config.resolve('/api/v1/can/recordings/recording-1/download').host,
      '192.168.10.42',
    );
  });

  test('preserves HTTPS and IPv6 while discarding page paths', () {
    final config = AppConfig.fromEnvironment(
      pageUri: Uri.parse('https://[::1]:8443/transmission?source=lan'),
      apiBaseUrl: '',
    );

    expect(
      config.webSocket('/api/v1/can/sessions/a/stream').toString(),
      'wss://[::1]:8443/api/v1/can/sessions/a/stream',
    );
  });

  test('explicit development override preserves its base path', () {
    final config = AppConfig.fromEnvironment(
      pageUri: Uri.parse('http://localhost:3000/'),
      apiBaseUrl: 'http://localhost:8000/backend/',
    );

    expect(
      config.resolve('/api/v1/can/interfaces').toString(),
      'http://localhost:8000/backend/api/v1/can/interfaces',
    );
  });

  test(
    'rejects invalid origins and overrides instead of guessing localhost',
    () {
      for (final override in ['ftp://jetson', '/api']) {
        expect(
          () => AppConfig.fromEnvironment(
            pageUri: Uri.parse('http://jetson/'),
            apiBaseUrl: override,
          ),
          throwsFormatException,
        );
      }
      expect(
        () => AppConfig.fromEnvironment(
          pageUri: Uri.parse('file:///app/index.html'),
          apiBaseUrl: '',
        ),
        throwsFormatException,
      );
    },
  );
}
