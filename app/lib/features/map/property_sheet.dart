import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../models/models.dart';
import '../check1/check1_sheet.dart';

/// Vendor ids in the seed data -> display names (data/vendors.json).
String vendorName(String? id) => switch (id) {
      'mockpark' => 'MockPark',
      'guestpass' => 'GuestPass',
      null => 'No online portal',
      _ => id,
    };

/// Details for one complex: guest rules, tow risk, and a "Park here" action.
Future<void> showPropertySheet(BuildContext context, WidgetRef ref, Property p) async {
  final park = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 480),
    builder: (_) => PropertySheet(p: p),
  );
  if (park == true && context.mounted) await startArrival(context, ref, p);
}

class PropertySheet extends StatelessWidget {
  final Property p;
  const PropertySheet({super.key, required this.p});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final r = p.guestRules;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(S.xl, 0, S.xl, S.xl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Pill(p.campus, fg: P.sign, bg: P.signSoft, caps: true),
          const SizedBox(width: S.sm),
          if (p.towEnforced) const Pill('Tow enforced', fg: P.tow, bg: P.towSoft, icon: Icons.warning_amber_rounded),
          const Spacer(),
          if (p.distanceM != null)
            Text(formatDistance(p.distanceM), style: const TextStyle(color: P.muted, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: S.md),
        Text(p.name, style: t.headlineMedium),
        const SizedBox(height: S.xs),
        Row(children: [
          Icon(p.hasPortal ? Icons.language_rounded : Icons.lock_outline_rounded, size: 16, color: P.muted),
          const SizedBox(width: 6),
          Text(p.hasPortal ? 'Registers through ${vendorName(p.vendorId)}' : 'Permit only, no online guest registration',
              style: const TextStyle(color: P.muted, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: S.lg),
        if (p.hasPortal) ...[
          Text('GUEST RULES', style: t.labelMedium),
          const SizedBox(height: S.sm),
          Row(children: [
            Expanded(
                child: InfoTile(
                    icon: Icons.nights_stay_rounded, label: 'Guest nights', value: '${r.maxNightsPerMonth} / month')),
            const SizedBox(width: S.sm),
            Expanded(
                child: InfoTile(
                    icon: Icons.timer_outlined, label: 'Max stay', value: '${r.maxDurationHours} hours', tint: P.agent)),
          ]),
          const SizedBox(height: S.sm),
          InfoTile(
              icon: Icons.schedule_rounded,
              label: 'Guest hours',
              value: r.guestHours.isEmpty ? 'Any time' : r.guestHours,
              tint: const Color(0xFF8A6A00)),
          const SizedBox(height: S.sm),
          InfoTile(
              icon: Icons.door_front_door_outlined,
              label: 'Host unit',
              value: r.requiresHostUnit ? 'Required: you name who you visit' : 'Not needed',
              tint: P.inkSoft),
        ],
        if (p.notes != null && p.notes!.isNotEmpty) ...[
          const SizedBox(height: S.md),
          Container(
            padding: const EdgeInsets.all(S.md),
            decoration: BoxDecoration(color: P.permitSoft, borderRadius: BorderRadius.circular(S.rMd)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.info_outline_rounded, size: 18, color: Color(0xFF7A5D00)),
              const SizedBox(width: 8),
              Expanded(child: Text(p.notes!, style: const TextStyle(fontSize: 13, color: Color(0xFF5C4600)))),
            ]),
          ),
        ],
        const SizedBox(height: S.xl),
        FilledButton.icon(
          onPressed: p.hasPortal ? () => Navigator.pop(context, true) : null,
          icon: const Icon(Icons.local_parking_rounded),
          label: Text(p.hasPortal ? "I'm parking here" : 'No online registration'),
        ),
      ]),
    );
  }
}

/// Compact card for horizontal "nearby" lists.
class PropertyCard extends StatelessWidget {
  final Property p;
  final VoidCallback onTap;
  const PropertyCard({super.key, required this.p, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final r = p.guestRules;
    return SizedBox(
      width: 220,
      child: AppCard(
        onTap: onTap,
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                  color: p.hasPortal ? P.signSoft : P.line, borderRadius: BorderRadius.circular(11)),
              child: Icon(p.hasPortal ? Icons.apartment_rounded : Icons.lock_outline_rounded,
                  color: p.hasPortal ? P.sign : P.muted, size: 21),
            ),
            const Spacer(),
            if (p.towEnforced) const Icon(Icons.warning_amber_rounded, color: P.tow, size: 18),
          ]),
          const SizedBox(height: 10),
          Text(p.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 2),
          Text(
            p.hasPortal ? '${r.maxNightsPerMonth} nights/mo · ${r.maxDurationHours}h max' : 'Permit only',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: P.muted, fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(formatDistance(p.distanceM) + (p.distanceM == null ? '' : ' from campus'),
              style: const TextStyle(color: P.sign, fontSize: 12.5, fontWeight: FontWeight.w800)),
        ]),
      ),
    );
  }
}
