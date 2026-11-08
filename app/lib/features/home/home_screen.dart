import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../models/models.dart';
import '../../services/location_service.dart';
import '../../services/session.dart';
import '../arrival/arrival_watcher.dart';
import '../check1/check1_sheet.dart';
import '../map/property_sheet.dart';

class HomeScreen extends ConsumerStatefulWidget {
  final VoidCallback onOpenPasses;
  final VoidCallback onOpenMap;
  const HomeScreen({super.key, required this.onOpenPasses, required this.onOpenMap});
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool locating = false;

  /// "I'm parking": read location, match the nearest property inside its radius.
  Future<void> imParking() async {
    setState(() => locating = true);
    try {
      final pos = await LocationService.current();
      final nearby = await ref.read(apiProvider).nearbyProperties(pos.latitude, pos.longitude, limit: 5);
      if (!mounted) return;
      if (nearby.isNotEmpty && nearby.first.inside) {
        await startArrival(context, ref, nearby.first);
      } else {
        final picked = await pickProperty(context, nearby, title: "We couldn't match where you are");
        if (picked != null && mounted) await startArrival(context, ref, picked);
      }
    } on LocationUnavailable catch (e) {
      if (mounted) {
        showError(context, e.message);
        await simulate();
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) {
        setState(() => locating = false);
        ref.read(refreshTick.notifier).state++;
      }
    }
  }

  /// Demo mode: pretend we just drove into a complex. It raises the same "Do you want to park here?" prompt a
  /// real arrival does, so everything after it is the real flow: yes -> saved info check -> (Maverick Place, first
  /// time) ask for the resident's phone -> resident texted -> guest registered.
  Future<void> simulate() async {
    final p = await showModalBottomSheet<Property>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (_) => const _SimulateSheet(),
    );
    if (p != null && mounted) {
      ref.read(arrivalProvider.notifier).preview(p);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final session = ref.watch(sessionProvider);
    final passes = ref.watch(passesProvider);
    final campus = ref.watch(campusProvider);
    final nearby = ref.watch(campusPropertiesProvider(campus));
    final vehicles = ref.watch(vehiclesProvider).valueOrNull ?? const <Vehicle>[];
    final car = vehicles.where((v) => v.vehicleId == session.vehicleId).firstOrNull ?? vehicles.firstOrNull;
    final active = passes.valueOrNull?.where((r) => r.status == RegistrationStatus.confirmed).toList() ?? const [];

    return RefreshIndicator(
      color: P.sign,
      onRefresh: () async => ref.read(refreshTick.notifier).state++,
      child: ListView(padding: S.page, children: [
        // Top bar
        Row(children: [
          const ParkMark(size: 34),
          const SizedBox(width: 10),
          Text('Parkour', style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          const Spacer(),
          if (car != null) PlateBadge(car.plate, car.state),
        ]),
        const SizedBox(height: S.xxl),
        Appear(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_greeting(session.firstName), style: t.titleMedium?.copyWith(color: P.muted)),
            const SizedBox(height: 2),
            Text('You park.\nWe handle it.', style: t.displaySmall),
          ]),
        ),
        const SizedBox(height: S.xl),
        Appear(index: 1, child: _ParkHero(busy: locating, onTap: locating ? null : imParking, car: car)),
        if (session.demoMode) ...[
          const SizedBox(height: S.md),
          Appear(
            index: 2,
            child: OutlinedButton.icon(
              onPressed: locating ? null : simulate,
              icon: const Icon(Icons.near_me_rounded, size: 20),
              label: const Text('Simulate arrival'),
            ),
          ),
        ],
        const SizedBox(height: S.xxl),

        // Active pass
        SectionHeader('Active pass', action: 'All passes', onAction: widget.onOpenPasses),
        passes.when(
          loading: () => const Skeleton(height: 112),
          error: (e, _) => EmptyState(
            icon: Icons.cloud_off_rounded,
            title: "Can't load passes",
            body: '$e',
            tint: P.tow,
            action: 'Try again',
            onAction: () => ref.read(refreshTick.notifier).state++,
          ),
          data: (_) => active.isEmpty
              ? const _HowItWorks()
              : Column(children: [
                  for (final (i, r) in active.take(2).indexed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: S.md),
                      child: Appear(index: i, child: ActivePassHero(reg: r, onTap: widget.onOpenPasses)),
                    ),
                ]),
        ),
        const SizedBox(height: S.xxl),

        // Nearby complexes
        Row(children: [
          Expanded(child: Text('Complexes near', style: t.titleLarge)),
          _CampusToggle(
            value: campus,
            onChanged: (c) => ref.read(campusProvider.notifier).state = c,
          ),
        ]),
        const SizedBox(height: S.md),
        SizedBox(
          height: 152,
          child: nearby.when(
            loading: () => ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: 3,
              separatorBuilder: (_, _) => const SizedBox(width: S.md),
              itemBuilder: (_, _) => const SizedBox(width: 220, child: Skeleton(height: 152)),
            ),
            error: (e, _) => Center(child: Text('$e', style: const TextStyle(color: P.muted))),
            data: (list) => ListView.separated(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              itemCount: list.length + 1,
              separatorBuilder: (_, _) => const SizedBox(width: S.md),
              itemBuilder: (_, i) => i == list.length
                  ? _SeeMapCard(count: list.length, onTap: widget.onOpenMap)
                  : PropertyCard(p: list[i], onTap: () => showPropertySheet(context, ref, list[i])),
            ),
          ),
        ),
        const SizedBox(height: S.sm),
        const Text('Locations © OpenStreetMap contributors. Guest rules are demo data.',
            style: TextStyle(color: P.faint, fontSize: 12)),
      ]),
    );
  }

  static String _greeting(String name) {
    final h = DateTime.now().hour;
    final part = h < 12 ? 'Good morning' : (h < 18 ? 'Good afternoon' : 'Good evening');
    return name.isEmpty ? part : '$part, $name';
  }
}

/// The main call to action: a big sign-green card with a pulsing "P".
class _ParkHero extends StatefulWidget {
  final bool busy;
  final VoidCallback? onTap;
  final Vehicle? car;
  const _ParkHero({required this.busy, this.onTap, this.car});
  @override
  State<_ParkHero> createState() => _ParkHeroState();
}

class _ParkHeroState extends State<_ParkHero> with SingleTickerProviderStateMixin {
  late final pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();

  @override
  void dispose() {
    pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PressScale(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(S.xl, 22, S.xl, 22),
          decoration: BoxDecoration(
            gradient: P.heroGradient,
            borderRadius: BorderRadius.circular(S.rXl),
            boxShadow: const [BoxShadow(color: Color(0x400B6B45), blurRadius: 24, offset: Offset(0, 10))],
          ),
          child: Stack(clipBehavior: Clip.none, children: [
            // faint road stripes in the corner
            Positioned(
              right: -8,
              top: -6,
              child: Transform.rotate(
                angle: -0.5,
                child: Row(children: [
                  for (var i = 0; i < 3; i++)
                    Container(
                      width: 10,
                      height: 80,
                      margin: const EdgeInsets.only(left: 10),
                      decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(4)),
                    ),
                ]),
              ),
            ),
            Row(children: [
              SizedBox(
                width: 68,
                height: 68,
                child: AnimatedBuilder(
                  animation: pulse,
                  builder: (_, child) => Stack(alignment: Alignment.center, children: [
                    if (!widget.busy)
                      Container(
                        width: 56 + 16 * pulse.value,
                        height: 56 + 16 * pulse.value,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18 + 4 * pulse.value),
                          color: Colors.white.withValues(alpha: 0.28 * (1 - pulse.value)),
                        ),
                      ),
                    child!,
                  ]),
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                    alignment: Alignment.center,
                    child: widget.busy
                        ? const SizedBox(
                            width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 3, color: P.sign))
                        : const Text('P',
                            style: TextStyle(color: P.sign, fontSize: 34, fontWeight: FontWeight.w900, height: 1)),
                  ),
                ),
              ),
              const SizedBox(width: S.lg),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(widget.busy ? 'Finding you…' : "I'm parking",
                      style: const TextStyle(
                          color: Colors.white, fontSize: 27, fontWeight: FontWeight.w800, height: 1.05)),
                  const SizedBox(height: 5),
                  Text(
                    widget.car == null
                        ? 'Find this complex and register my car'
                        : 'Register my ${widget.car!.make} ${widget.car!.model} here',
                    style: const TextStyle(color: Color(0xD9FFFFFF), fontSize: 14.5, fontWeight: FontWeight.w500),
                  ),
                ]),
              ),
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.16), shape: BoxShape.circle),
                child: const Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 20),
              ),
            ]),
          ]),
        ),
      );
}

/// Active pass as a big glanceable card: ring, countdown, confirmation number.
class ActivePassHero extends StatelessWidget {
  final Registration reg;
  final VoidCallback? onTap;
  const ActivePassHero({super.key, required this.reg, this.onTap});
  @override
  Widget build(BuildContext context) {
    final proof = reg.proof;
    final until = proof?.expiresAt;
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(S.lg),
      child: Row(children: [
        if (until != null)
          TimeRing(
            start: reg.createdAt,
            until: until,
            size: 72,
            child: const Icon(Icons.local_parking_rounded, color: P.sign, size: 28),
          )
        else
          const Icon(Icons.verified_rounded, color: P.sign, size: 48),
        const SizedBox(width: S.lg),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(reg.property.name,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 2),
            if (until != null)
              Countdown(until, style: const TextStyle(color: P.sign, fontWeight: FontWeight.w800, fontSize: 18)),
            const SizedBox(height: 4),
            Row(children: [
              const Icon(Icons.tag_rounded, size: 15, color: P.muted),
              const SizedBox(width: 3),
              Flexible(
                child: Text(proof?.confirmationNumber ?? '-',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontWeight: FontWeight.w700, color: P.muted, letterSpacing: 0.5)),
              ),
              if (until != null) ...[
                const Text('  ·  ', style: TextStyle(color: P.faint)),
                Text('until ${formatTime(until)}', style: const TextStyle(color: P.muted, fontWeight: FontWeight.w600)),
              ],
            ]),
          ]),
        ),
        const Icon(Icons.chevron_right_rounded, color: P.faint),
      ]),
    );
  }
}

/// Shown instead of an active pass for first-time users.
class _HowItWorks extends StatelessWidget {
  const _HowItWorks();
  @override
  Widget build(BuildContext context) {
    const steps = [
      (Icons.location_on_rounded, 'Pull in', "Tap I'm parking. We match the complex."),
      (Icons.touch_app_rounded, 'One tap', 'Check the details and tap Register.'),
      (Icons.verified_rounded, 'Proof saved', 'The agent fills the portal and keeps the receipt.'),
    ];
    return AppCard(
      padding: const EdgeInsets.fromLTRB(S.lg, S.lg, S.lg, S.sm),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('No active pass yet', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        const SizedBox(height: 2),
        const Text('Here is what happens when you park:', style: TextStyle(color: P.muted)),
        const SizedBox(height: S.md),
        for (final (i, (icon, title, body)) in steps.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: S.md),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(color: P.signSoft, borderRadius: BorderRadius.circular(10)),
                alignment: Alignment.center,
                child: Icon(icon, color: P.sign, size: 19),
              ),
              const SizedBox(width: S.md),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${i + 1}. $title', style: const TextStyle(fontWeight: FontWeight.w800)),
                  Text(body, style: const TextStyle(color: P.muted, fontSize: 13.5)),
                ]),
              ),
            ]),
          ),
      ]),
    );
  }
}

class _SeeMapCard extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _SeeMapCard({required this.count, required this.onTap});
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 150,
        child: AppCard(
          onTap: onTap,
          color: P.ink,
          borderColor: P.ink,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.map_rounded, color: P.permit, size: 30),
            const Spacer(),
            const Text('Open map', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 17)),
            Text('All $count complexes', style: const TextStyle(color: Color(0xB3FFFFFF), fontSize: 13)),
          ]),
        ),
      );
}

class _CampusToggle extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _CampusToggle({required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(color: P.line, borderRadius: BorderRadius.circular(99)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (final c in const ['UTD', 'UTA'])
            GestureDetector(
              onTap: () => onChanged(c),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: c == value ? P.card : Colors.transparent,
                  borderRadius: BorderRadius.circular(99),
                  boxShadow: c == value ? softShadow : null,
                ),
                child: Text(c,
                    style: TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 13, color: c == value ? P.ink : P.muted)),
              ),
            ),
        ]),
      );
}

Future<Property?> pickProperty(BuildContext context, List<Property> list, {required String title}) =>
    showModalBottomSheet<Property>(
      context: context,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (_) => ListView(padding: const EdgeInsets.fromLTRB(S.lg, 0, S.lg, S.lg), children: [
        Text(title, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        const Text('Pick the complex you parked at.', style: TextStyle(color: P.muted)),
        const SizedBox(height: S.md),
        for (final p in list) PropertyTile(p: p, onTap: () => Navigator.pop(context, p)),
      ]),
    );

class PropertyTile extends StatelessWidget {
  final Property p;
  final VoidCallback onTap;
  const PropertyTile({super.key, required this.p, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final rules = p.guestRules;
    final sub = p.hasPortal
        ? '${rules.maxNightsPerMonth} guest nights/mo · up to ${rules.maxDurationHours}h'
        : 'Permit only · no online registration';
    return Padding(
      padding: const EdgeInsets.only(bottom: S.sm),
      child: AppCard(
        onTap: onTap,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
                color: p.hasPortal ? P.signSoft : P.line, borderRadius: BorderRadius.circular(12)),
            child: Icon(p.hasPortal ? Icons.apartment_rounded : Icons.lock_outline_rounded,
                color: p.hasPortal ? P.sign : P.muted),
          ),
          const SizedBox(width: S.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(p.name,
                      overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
                ),
                if (p.towEnforced) ...[
                  const SizedBox(width: 6),
                  const Icon(Icons.warning_amber_rounded, size: 15, color: P.tow),
                ],
              ]),
              const SizedBox(height: 2),
              Text(sub, style: const TextStyle(color: P.muted, fontSize: 13)),
            ]),
          ),
          if (p.distanceM != null)
            Text(formatDistance(p.distanceM), style: const TextStyle(color: P.muted, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }
}

class _SimulateSheet extends ConsumerStatefulWidget {
  const _SimulateSheet();
  @override
  ConsumerState<_SimulateSheet> createState() => _SimulateSheetState();
}

class _SimulateSheetState extends ConsumerState<_SimulateSheet> {
  late String campus = ref.read(campusProvider);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final list = ref.watch(campusPropertiesProvider(campus));
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      builder: (_, scroll) => Padding(
        padding: const EdgeInsets.fromLTRB(S.lg, 0, S.lg, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Simulate arrival', style: t.headlineSmall),
                const Text('Demo mode: pick where you just parked.', style: TextStyle(color: P.muted)),
              ]),
            ),
            _CampusToggle(value: campus, onChanged: (c) => setState(() => campus = c)),
          ]),
          const SizedBox(height: S.md),
          Expanded(
            child: list.when(
              error: (e, _) => Center(child: Text('$e')),
              loading: () => const Center(child: CircularProgressIndicator(color: P.sign)),
              data: (props) => ListView(controller: scroll, children: [
                for (final p in props) PropertyTile(p: p, onTap: () => Navigator.pop(context, p)),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: S.md),
                  child: Text('Locations © OpenStreetMap contributors. Guest rules are demo data.',
                      style: TextStyle(color: P.faint, fontSize: 12)),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
