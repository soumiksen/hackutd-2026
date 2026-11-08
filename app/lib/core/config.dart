import 'package:flutter/foundation.dart';

/// Backend URL. Pass with --dart-define=API_BASE_URL=... (contract section 1).
/// On web with no define, the app talks to /api on its own origin
/// (tool/serve_web.py forwards that to the backend, so no CORS is needed).
class Config {
  static const _fromEnv = String.fromEnvironment('API_BASE_URL');

  static String get apiBaseUrl {
    if (_fromEnv.isNotEmpty) return _fromEnv.replaceAll(RegExp(r'/$'), '');
    if (kIsWeb) return '${Uri.base.origin}/api';
    return 'http://10.0.2.2:8000'; // Android emulator -> host machine
  }

  /// Campus centers for the simulated-arrival demo mode (frontend-plan section 6).
  static const campuses = {
    'UTD': (32.9886, -96.7494),
    'UTA': (32.7315, -97.1115),
  };
}
