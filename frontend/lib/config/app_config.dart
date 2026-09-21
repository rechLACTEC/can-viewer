class AppConfig {
  factory AppConfig({required Uri apiBaseUri}) {
    _validate(apiBaseUri);
    return AppConfig._(apiBaseUri);
  }

  const AppConfig._(this.apiBaseUri);

  factory AppConfig.fromEnvironment({
    Uri? pageUri,
    String apiBaseUrl = const String.fromEnvironment('CAN_API_BASE_URL'),
  }) {
    if (apiBaseUrl.isNotEmpty) {
      return AppConfig(apiBaseUri: Uri.parse(apiBaseUrl));
    }
    final page = pageUri ?? Uri.base;
    _validate(page);
    // The browser's origin follows the Jetson address without rebuilding.
    return AppConfig(apiBaseUri: Uri.parse(page.origin));
  }

  final Uri apiBaseUri;

  Uri resolve(String path) {
    final base = apiBaseUri.toString().replaceFirst(RegExp(r'/$'), '');
    return Uri.parse('$base$path');
  }

  Uri webSocket(String path) {
    final uri = resolve(path);
    return uri.replace(scheme: uri.scheme == 'https' ? 'wss' : 'ws');
  }
}

void _validate(Uri uri) {
  if (!const {'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty) {
    throw const FormatException(
      'CAN_API_BASE_URL deve ser uma URL HTTP(S) absoluta.',
    );
  }
}
