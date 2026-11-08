import 'package:flutter/foundation.dart';

/// Backend URL (contract section 1). Pass --dart-define=API_BASE_URL=... to override.
///
/// With no define:
///  - web: the app calls /api on its own origin. Locally tool/serve_web.py forwards that to the backend; on the AWS
///    server, Caddy serves the web app and /api from the same address, so it just works.
///  - release builds on a phone: the deployed AWS server ([productionApiUrl]).
///  - debug builds on a phone or emulator: the Android emulator's host machine (10.0.2.2).
class Config {
  static const _fromEnv = String.fromEnvironment('API_BASE_URL');

  /// The deployed backend (AWS EC2, HTTPS through Caddy).
  static const productionApiUrl = 'https://16-58-149-33.sslip.io/api';

  static String get apiBaseUrl {
    if (_fromEnv.isNotEmpty) return _fromEnv.replaceAll(RegExp(r'/$'), '');
    if (kIsWeb) return '${Uri.base.origin}/api';
    if (kReleaseMode) return productionApiUrl;
    return 'http://10.0.2.2:8000'; // Android emulator -> host machine
  }

  /// Campus centers for the simulated-arrival demo mode (frontend-plan section 6).
  static const campuses = {
    'UTD': (32.9886, -96.7494),
    'UTA': (32.7315, -97.1115),
  };
}
