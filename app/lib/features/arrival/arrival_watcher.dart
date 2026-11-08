import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../models/models.dart';
import '../../services/notification_service.dart';
import '../../services/session.dart';

/// The complex the user just drove into, or null. The island widget shows
/// "Do you want to park here?" whenever this is set.
final arrivalProvider = StateNotifierProvider<ArrivalWatcher, Property?>((ref) => ArrivalWatcher(ref));

/// Watches the phone's location and asks the backend which seeded complex
/// (if any) the user is inside, using each complex's radius_m geofence.
class ArrivalWatcher extends StateNotifier<Property?> {
  ArrivalWatcher(this.ref) : super(null);
  final Ref ref;

  StreamSubscription<Position>? _sub;
  final _snoozed = <String, DateTime>{};
  String? _lastInside;
  bool _busy = false;
  Position? _pending; // newest fix that arrived while a check was running

  bool get running => _sub != null;

  Future<void> start() async {
    if (_sub != null) return;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;
      _sub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 15),
      ).listen(_onPosition, onError: (_) {});
    } catch (_) {
      // No location on this device: the Simulate arrival flow still works.
    }
  }

  Future<void> _onPosition(Position pos) async {
    // Never drop a fix: a parked phone sends no more updates, so the last
    // one must always be checked. Only the newest pending fix is kept.
    if (_busy) {
      _pending = pos;
      return;
    }
    _busy = true;
    final now = DateTime.now();
    try {
      final api = ref.read(apiProvider);
      final nearby = await api.nearbyProperties(pos.latitude, pos.longitude, limit: 3);
      final hit = nearby.where((p) => p.inside && p.hasPortal).firstOrNull;
      if (hit == null) {
        _lastInside = null; // left the complex, so the next visit prompts again
        return;
      }
      if (hit.propertyId == _lastInside) return; // already asked on this visit
      _lastInside = hit.propertyId;

      final until = _snoozed[hit.propertyId];
      if (until != null && now.isBefore(until)) return;

      // Already have a live pass here? Then don't nag.
      try {
        final passes = await api.listPasses();
        final covered = passes.any(
          (r) => r.status == RegistrationStatus.confirmed && r.property.propertyId == hit.propertyId,
        );
        if (covered) return;
      } catch (_) {}

      if (!mounted) return;
      state = hit;
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        await NotificationService.showArrival(hit.name, propertyId: hit.propertyId);
      }
    } catch (_) {
      // Backend unreachable: try again on the next position update.
    } finally {
      _busy = false;
      final next = _pending;
      _pending = null;
      if (next != null && mounted) _onPosition(next);
    }
  }

  /// Show the island for [p] without moving (demo / Settings button).
  void preview(Property p) => state = p;

  Timer? _test;

  /// Settings test button: after [delay], iOS pops a notification (seen when
  /// the app is in the background); if the app is open, the island shows.
  Future<void> scheduleTest(Property p, {Duration delay = const Duration(seconds: 10)}) async {
    _test?.cancel();
    await NotificationService.scheduleArrivalTest(p.propertyId, p.name, delay: delay);
    _test = Timer(delay, () {
      if (!mounted) return;
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) state = p;
    });
  }

  /// User tapped an arrival notification: show the island for that complex.
  Future<void> openFromNotification(String? payload) async {
    if (payload == null || !payload.startsWith('arrival:')) return;
    try {
      final p = await ref.read(apiProvider).getProperty(payload.substring('arrival:'.length));
      if (mounted) state = p;
    } catch (_) {}
  }

  /// "Not now": hide, and don't ask about this complex for an hour.
  void dismiss() {
    final p = state;
    if (p != null) _snoozed[p.propertyId] = DateTime.now().add(const Duration(hours: 1));
    state = null;
  }

  /// "Park here": hide; the caller starts the registration.
  void accept() => state = null;

  @override
  void dispose() {
    _sub?.cancel();
    _test?.cancel();
    super.dispose();
  }
}
