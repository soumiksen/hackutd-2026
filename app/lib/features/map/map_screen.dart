import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:url_launcher/url_launcher.dart';

import '../../core/config.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../models/models.dart';
import '../../services/session.dart';
import 'property_sheet.dart';

/// Seeded complexes on OpenStreetMap (frontend-plan P1). Tap a pin or swipe the cards.
class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});
  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  final map = MapController();
  final pages = PageController(viewportFraction: 0.86);
  int selected = 0;

  void select(List<Property> list, int i, {bool fromPin = false}) {
    if (i < 0 || i >= list.length) return;
    setState(() => selected = i);
    map.move(LatLng(list[i].lat, list[i].lng), 15.5);
    if (fromPin && pages.hasClients) {
      pages.animateToPage(i, duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
    }
  }

  void switchCampus(String c) {
    ref.read(campusProvider.notifier).state = c;
    final (lat, lng) = Config.campuses[c]!;
    setState(() => selected = 0);
    map.move(LatLng(lat, lng), 14);
    if (pages.hasClients) pages.jumpToPage(0);
  }

  @override
  Widget build(BuildContext context) {
    final campus = ref.watch(campusProvider);
    final async = ref.watch(campusPropertiesProvider(campus));
    final list = async.valueOrNull ?? const <Property>[];
    final (clat, clng) = Config.campuses[campus]!;

    return Stack(children: [
      FlutterMap(
        mapController: map,
        options: MapOptions(
          initialCenter: LatLng(clat, clng),
          initialZoom: 14,
          minZoom: 10,
          maxZoom: 18,
          interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'app.parkour.hackutd',
          ),
          CircleLayer(circles: [
            for (final (i, p) in list.indexed)
              CircleMarker(
                point: LatLng(p.lat, p.lng),
                radius: p.radiusM,
                useRadiusInMeter: true,
                color: (p.hasPortal ? P.sign : P.muted).withValues(alpha: i == selected ? 0.18 : 0.08),
                borderColor: (p.hasPortal ? P.sign : P.muted).withValues(alpha: i == selected ? 0.7 : 0.3),
                borderStrokeWidth: i == selected ? 2 : 1,
              ),
          ]),
          MarkerLayer(markers: [
            // campus center
            Marker(
              point: LatLng(clat, clng),
              width: 64,
              height: 30,
              child: Pill(campus, fg: Colors.white, bg: P.ink, icon: Icons.school_rounded),
            ),
            for (final (i, p) in list.indexed)
              Marker(
                point: LatLng(p.lat, p.lng),
                width: 48,
                height: 56,
                alignment: Alignment.topCenter,
                child: GestureDetector(onTap: () => select(list, i, fromPin: true), child: _Pin(p: p, selected: i == selected)),
              ),
          ]),
          RichAttributionWidget(
            alignment: AttributionAlignment.bottomLeft,
            showFlutterMapAttribution: false,
            attributions: [
              TextSourceAttribution('OpenStreetMap contributors',
                  onTap: () => launchUrl(Uri.parse('https://openstreetmap.org/copyright'))),
            ],
          ),
        ],
      ),

      // Top bar
      Positioned(
        left: S.lg,
        right: S.lg,
        top: S.md,
        child: Row(children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(color: P.card, borderRadius: BorderRadius.circular(S.rMd), boxShadow: softShadow),
              child: Row(children: [
                const Icon(Icons.map_rounded, color: P.sign, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    async.isLoading ? 'Loading complexes…' : '${list.length} complexes near $campus',
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                ),
              ]),
            ),
          ),
          const SizedBox(width: S.sm),
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(color: P.card, borderRadius: BorderRadius.circular(S.rMd), boxShadow: softShadow),
            child: Row(children: [
              for (final c in Config.campuses.keys)
                GestureDetector(
                  onTap: () => switchCampus(c),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    decoration: BoxDecoration(
                        color: c == campus ? P.ink : Colors.transparent, borderRadius: BorderRadius.circular(11)),
                    child: Text(c,
                        style: TextStyle(
                            color: c == campus ? Colors.white : P.muted, fontWeight: FontWeight.w800, fontSize: 13)),
                  ),
                ),
            ]),
          ),
        ]),
      ),

      // Legend
      const Positioned(
        right: S.lg,
        top: 70,
        child: _Legend(),
      ),

      // Recenter
      Positioned(
        right: S.lg,
        bottom: 156,
        child: FloatingActionButton.small(
          heroTag: 'recenter',
          backgroundColor: P.card,
          foregroundColor: P.ink,
          elevation: 2,
          onPressed: () => map.move(LatLng(clat, clng), 14),
          child: const Icon(Icons.my_location_rounded),
        ),
      ),

      // Cards
      Positioned(
        left: 0,
        right: 0,
        bottom: S.lg,
        height: 128,
        child: async.when(
          loading: () => const Padding(
              padding: EdgeInsets.symmetric(horizontal: S.xl), child: Skeleton(height: 128)),
          error: (e, _) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.lg),
            child: AppCard(
                child: Row(children: [
              const Icon(Icons.cloud_off_rounded, color: P.tow),
              const SizedBox(width: S.md),
              Expanded(child: Text('$e')),
            ])),
          ),
          data: (list) => PageView.builder(
            controller: pages,
            itemCount: list.length,
            onPageChanged: (i) => select(list, i),
            itemBuilder: (_, i) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: _MapCard(p: list[i], onTap: () => showPropertySheet(context, ref, list[i])),
            ),
          ),
        ),
      ),
    ]);
  }
}

class _Pin extends StatelessWidget {
  final Property p;
  final bool selected;
  const _Pin({required this.p, required this.selected});
  @override
  Widget build(BuildContext context) {
    final color = !p.hasPortal ? P.muted : (p.towEnforced ? P.sign : P.agent);
    return AnimatedScale(
      scale: selected ? 1.15 : 0.9,
      alignment: Alignment.bottomCenter,
      duration: const Duration(milliseconds: 200),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: selected ? color : Colors.white,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: color, width: 2.5),
            boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 6, offset: Offset(0, 3))],
          ),
          alignment: Alignment.center,
          child: p.hasPortal
              ? Text('P',
                  style: TextStyle(
                      color: selected ? Colors.white : color, fontWeight: FontWeight.w900, fontSize: 20, height: 1))
              : Icon(Icons.lock_rounded, size: 18, color: selected ? Colors.white : color),
        ),
        CustomPaint(size: const Size(12, 8), painter: _TrianglePainter(color)),
      ]),
    );
  }
}

class _TrianglePainter extends CustomPainter {
  final Color color;
  const _TrianglePainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_TrianglePainter old) => old.color != color;
}

class _Legend extends StatelessWidget {
  const _Legend();
  @override
  Widget build(BuildContext context) {
    Widget row(Color c, String label) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3))),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
          ]),
        );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(color: P.card.withValues(alpha: 0.94), borderRadius: BorderRadius.circular(S.rSm), boxShadow: softShadow),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        row(P.sign, 'Online · tow enforced'),
        row(P.agent, 'Online'),
        row(P.muted, 'Permit only'),
      ]),
    );
  }
}

class _MapCard extends StatelessWidget {
  final Property p;
  final VoidCallback onTap;
  const _MapCard({required this.p, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final r = p.guestRules;
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(S.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(p.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge),
          ),
          Text(formatDistance(p.distanceM), style: const TextStyle(color: P.muted, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 4),
        Text(p.hasPortal ? 'Guest registration via ${vendorName(p.vendorId)}' : 'Permit only, no online registration',
            style: const TextStyle(color: P.muted, fontWeight: FontWeight.w600)),
        const Spacer(),
        Row(children: [
          if (p.hasPortal) ...[
            Pill('${r.maxNightsPerMonth} nights/mo', fg: P.sign, bg: P.signSoft, icon: Icons.nights_stay_rounded),
            const SizedBox(width: 6),
            Pill('${r.maxDurationHours}h max', fg: P.agent, bg: P.agentSoft, icon: Icons.timer_outlined),
          ],
          const Spacer(),
          if (p.towEnforced) const Icon(Icons.warning_amber_rounded, color: P.tow, size: 20),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right_rounded, color: P.faint),
        ]),
      ]),
    );
  }
}
