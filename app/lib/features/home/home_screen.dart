import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../models/models.dart';
import '../../services/location_service.dart';
import '../../services/session.dart';
import '../check1/check1_sheet.dart';
import '../passes/passes_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  final VoidCallback onOpenPasses;
  const HomeScreen({super.key, required this.onOpenPasses});
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
      if (mounted) setState(() => locating = false);
      ref.read(refreshTick.notifier).state++;
    }
  }

  /// Demo mode: pretend we just parked at a seeded property near a campus.
  Future<void> simulate() async {
    final p = await showModalBottomSheet<Property>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (_) => const _SimulateSheet(),
    );
    if (p != null && mounted) {
      await startArrival(context, ref, p);
      ref.read(refreshTick.notifier).state++;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final session = ref.watch(sessionProvider);
    final passes = ref.watch(passesProvider);
    final active = passes.valueOrNull?.where((r) => r.status == RegistrationStatus.confirmed).toList() ?? const [];
    return RefreshIndicator(
      onRefresh: () async => ref.read(refreshTick.notifier).state++,
      child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: [
        Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: P.sign, borderRadius: BorderRadius.circular(10)),
            alignment: Alignment.center,
            child: const Text('P', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900)),
          ),
          const SizedBox(width: 10),
          Text('Parkour', style: t.headlineSmall),
        ]),
        const SizedBox(height: 20),
        Text(session.firstName.isEmpty ? 'Hey there' : 'Hey ${session.firstName}', style: t.titleMedium?.copyWith(color: P.muted)),
        Text('You park.\nWe handle it.', style: t.displaySmall),
        const SizedBox(height: 24),
        _ParkButton(busy: locating, onTap: locating ? null : imParking),
        const SizedBox(height: 12),
        if (session.demoMode)
          OutlinedButton.icon(
            onPressed: simulate,
            icon: const Icon(Icons.near_me_outlined),
            label: const Text('Simulate arrival'),
          ),
        const SizedBox(height: 28),
        Row(children: [
          Text('Active passes', style: t.titleLarge),
          const Spacer(),
          TextButton(onPressed: widget.onOpenPasses, child: const Text('All passes')),
        ]),
        const SizedBox(height: 8),
        passes.when(
          loading: () => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => _Empty(text: '$e'),
          data: (_) => active.isEmpty
              ? const _Empty(text: 'No active pass. When you park, your proof shows up here.')
              : Column(children: [
                  for (final r in active.take(2)) Padding(padding: const EdgeInsets.only(bottom: 12), child: PassCard(reg: r)),
                ]),
        ),
      ]),
    );
  }
}

class _ParkButton extends StatelessWidget {
  final bool busy;
  final VoidCallback? onTap;
  const _ParkButton({required this.busy, this.onTap});
  @override
  Widget build(BuildContext context) => Material(
        color: P.sign,
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 26),
            child: Row(children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
                alignment: Alignment.center,
                child: busy
                    ? const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 3))
                    : const Text('P', style: TextStyle(color: P.sign, fontSize: 34, fontWeight: FontWeight.w900)),
              ),
              const SizedBox(width: 18),
              const Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text("I'm parking",
                      style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800, height: 1.1)),
                  SizedBox(height: 4),
                  Text('Find this property and register my car',
                      style: TextStyle(color: Color(0xCCFFFFFF), fontSize: 14)),
                ]),
              ),
              const Icon(Icons.arrow_forward, color: Colors.white),
            ]),
          ),
        ),
      );
}

class _Empty extends StatelessWidget {
  final String text;
  const _Empty({required this.text});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: P.line),
        ),
        child: Text(text, style: const TextStyle(color: P.muted)),
      );
}

Future<Property?> pickProperty(BuildContext context, List<Property> list, {required String title}) =>
    showModalBottomSheet<Property>(
      context: context,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (_) => ListView(padding: const EdgeInsets.all(16), children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
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
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: CircleAvatar(
        backgroundColor: p.hasPortal ? P.signSoft : P.line,
        child: Icon(p.hasPortal ? Icons.apartment : Icons.lock_outline, color: p.hasPortal ? P.sign : P.muted),
      ),
      title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(sub),
      trailing: p.distanceM == null
          ? null
          : Text(p.distanceM! < 1000 ? '${p.distanceM!.round()} m' : '${(p.distanceM! / 1609).toStringAsFixed(1)} mi',
              style: const TextStyle(color: P.muted)),
      onTap: onTap,
    );
  }
}

class _SimulateSheet extends ConsumerStatefulWidget {
  const _SimulateSheet();
  @override
  ConsumerState<_SimulateSheet> createState() => _SimulateSheetState();
}

class _SimulateSheetState extends ConsumerState<_SimulateSheet> {
  String campus = 'UTD';
  Future<List<Property>>? future;

  void load() {
    final (lat, lng) = Config.campuses[campus]!;
    future = ref.read(apiProvider).nearbyProperties(lat, lng, limit: 30).then(
        (all) => all.where((p) => p.campus == campus).toList());
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      builder: (_, scroll) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Simulate arrival', style: t.headlineSmall),
          Text('Demo mode: pick where you just parked.', style: t.bodyMedium?.copyWith(color: P.muted)),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'UTD', label: Text('Near UTD')),
              ButtonSegment(value: 'UTA', label: Text('Near UTA')),
            ],
            selected: {campus},
            onSelectionChanged: (s) => setState(() {
              campus = s.first;
              load();
            }),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: FutureBuilder<List<Property>>(
              future: future,
              builder: (_, snap) {
                if (snap.hasError) return Center(child: Text('${snap.error}'));
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                return ListView(controller: scroll, children: [
                  for (final p in snap.data!) PropertyTile(p: p, onTap: () => Navigator.pop(context, p)),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('Locations © OpenStreetMap contributors. Guest rules are demo data.',
                        style: TextStyle(color: P.muted, fontSize: 12)),
                  ),
                ]);
              },
            ),
          ),
        ]),
      ),
    );
  }
}
