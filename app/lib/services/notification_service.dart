import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Local notification for Check 1 (no Firebase). On web there is no plugin,
/// so the home screen shows an in-app banner instead.
class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static bool get supported => !kIsWeb;

  /// Called with the payload when the user taps one of our notifications.
  static void Function(String? payload)? onTap;

  static Future<void> init() async {
    if (!supported || _ready) return;
    try {
      tzdata.initializeTimeZones();
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
        ),
        onDidReceiveNotificationResponse: (r) => onTap?.call(r.payload),
      );
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
        android: AndroidNotificationDetails(
          'check1',
          'Registration prompts',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
    );
  }

  /// Geofence hit while the app is in the background.
  static Future<void> showArrival(String propertyName, {String? propertyId}) async {
    if (!_ready) return;
    await _plugin.show(
      id: 2,
      payload: propertyId == null ? null : 'arrival:$propertyId',
      title: 'Do you want to park here?',
      body: "You're at $propertyName. Open Parkour to register your car.",
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'arrival',
          'Arrival prompts',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(interruptionLevel: InterruptionLevel.timeSensitive),
      ),
    );
  }

  /// Test button: iOS itself delivers this after [delay], so it still pops
  /// when the app is in the background or the phone is locked. While the app
  /// is open no banner is shown (the in-app island shows instead).
  static Future<bool> scheduleArrivalTest(
    String propertyId,
    String propertyName, {
    Duration delay = const Duration(seconds: 10),
  }) async {
    if (!_ready) return false;
    await _plugin.zonedSchedule(
      id: 3,
      title: 'Do you want to park here?',
      body: "You're at $propertyName. Tap to register your car.",
      payload: 'arrival:$propertyId',
      scheduledDate: tz.TZDateTime.now(tz.UTC).add(delay),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'arrival',
          'Arrival prompts',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: false,
          presentBanner: false,
          presentList: true,
          presentSound: false,
          interruptionLevel: InterruptionLevel.timeSensitive,
        ),
      ),
    );
    return true;
  }
}
