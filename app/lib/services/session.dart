import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/api_client.dart';
import '../core/config.dart';
import '../models/models.dart';

/// Device identity, onboarding state and small local caches (shared_preferences).
class Session {
  final SharedPreferences prefs;
  Session(this.prefs);

  static const _kUserId = 'device_user_id';
  static const _kOnboarded = 'onboarded';
  static const _kVehicleId = 'vehicle_id';
  static const _kName = 'user_name';
  static const _kDemo = 'demo_mode';
  static const _kToken = 'auth_token';
  static const _kEmail = 'auth_email';

  /// Random UUID generated once, sent as X-User-Id (contract section 2).
  String get userId {
    var id = prefs.getString(_kUserId);
    if (id == null) {
      id = const Uuid().v4();
      prefs.setString(_kUserId, id);
    }
    return id;
  }

  /// Session token from sign-up / sign-in. Stored in shared_preferences (browser storage on web).
  String? get token => prefs.getString(_kToken);
  String? get email => prefs.getString(_kEmail);
  bool get signedIn => token != null;

  Future<void> saveSession({required String token, required String email, required String name}) async {
    await prefs.setString(_kToken, token);
    await prefs.setString(_kEmail, email);
    await prefs.setString(_kName, name);
  }

  /// Forget the account on this device but keep the device id (so an anonymous profile is not orphaned).
  Future<void> clearSession() async {
    await prefs.remove(_kToken);
    await prefs.remove(_kEmail);
    await prefs.remove(_kOnboarded);
    await prefs.remove(_kVehicleId);
    await prefs.remove(_kName);
  }

  bool get onboarded => prefs.getBool(_kOnboarded) ?? false;
  String? get vehicleId => prefs.getString(_kVehicleId);
  String get firstName => (prefs.getString(_kName) ?? '').split(' ').first;
  bool get demoMode => prefs.getBool(_kDemo) ?? true;
  set demoMode(bool v) => prefs.setBool(_kDemo, v);

  Future<void> completeOnboarding({required String vehicleId, required String name}) async {
    await prefs.setString(_kVehicleId, vehicleId);
    await prefs.setString(_kName, name);
    await prefs.setBool(_kOnboarded, true);
  }

  Future<void> setVehicle(String vehicleId) => prefs.setString(_kVehicleId, vehicleId);

  /// Last host used at a property, so the next draft needs no typing.
  Host? hostFor(String propertyId) {
    final raw = prefs.getStringList('host:$propertyId');
    if (raw == null || raw.length != 2) return null;
    return Host(name: raw[0].isEmpty ? null : raw[0], unit: raw[1].isEmpty ? null : raw[1]);
  }

  Future<void> rememberHost(String propertyId, Host host) =>
      prefs.setStringList('host:$propertyId', [host.name ?? '', host.unit ?? '']);

  Future<void> reset() async {
    final id = userId;
    await prefs.clear();
    await prefs.setString(_kUserId, id);
  }
}

final prefsProvider = Provider<SharedPreferences>((ref) => throw UnimplementedError('overridden in main'));
final sessionProvider = Provider<Session>((ref) => Session(ref.watch(prefsProvider)));
/// Bumped when the server says the session is no longer valid; the app then shows sign-in again.
final authTick = StateProvider<int>((ref) => 0);

final apiProvider = Provider<ApiClient>((ref) {
  final session = ref.watch(sessionProvider);
  final api = ApiClient(session.userId, token: session.token);
  api.onUnauthorized = () async {
    await session.clearSession();
    ref.read(authTick.notifier).state++;
  };
  return api;
});

/// Bumped to refresh lists after a registration changes.
final refreshTick = StateProvider<int>((ref) => 0);

final passesProvider = FutureProvider.autoDispose<List<Registration>>((ref) async {
  ref.watch(refreshTick);
  final passes = await ref.watch(apiProvider).listPasses();
  passes.sort((a, b) => (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)));
  return passes;
});

final vehiclesProvider = FutureProvider.autoDispose<List<Vehicle>>((ref) async {
  ref.watch(refreshTick);
  return ref.watch(apiProvider).listVehicles();
});

/// Which campus the map and nearby list are centered on.
final campusProvider = StateProvider<String>((ref) => 'UTD');

/// Every seeded complex near a campus, sorted by distance from its center.
final campusPropertiesProvider = FutureProvider.autoDispose.family<List<Property>, String>((ref, campus) async {
  final (lat, lng) = Config.campuses[campus]!;
  final all = await ref.watch(apiProvider).nearbyProperties(lat, lng, limit: 50);
  return all.where((p) => p.campus == campus).toList();
});

final healthProvider = FutureProvider.autoDispose<bool>((ref) async {
  try {
    return await ref.watch(apiProvider).health();
  } catch (_) {
    return false;
  }
});
