import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Local notification for Check 1 (no Firebase). On web there is no plugin,
/// so the home screen shows an in-app banner instead.
class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static bool get supported => !kIsWeb;

  static Future<void> init() async {
    if (!supported || _ready) return;
    try {
      await _plugin.initialize(settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ));
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      _ready = true;
    } catch (_) {
      _ready = false;
    }
  }

  static Future<void> showCheck1(String summary) async {
    if (!_ready) return;
    await _plugin.show(
      id: 1,
      title: 'Parkour: register your car?',
      body: summary,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails('check1', 'Registration prompts',
            importance: Importance.high, priority: Priority.high),
        iOS: DarwinNotificationDetails(),
      ),
    );
  }
}
