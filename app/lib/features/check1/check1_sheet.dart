import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../models/models.dart';
import '../../services/notification_service.dart';
import '../../services/session.dart';
import '../status/status_screen.dart';

/// Starts a registration for a matched property: draft -> Check 1 sheet.
Future<void> startArrival(BuildContext context, WidgetRef ref, Property p) async {
  final session = ref.read(sessionProvider);
  final api = ref.read(apiProvider);
  if (!p.hasPortal) {
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(p.name),
        content: Text(p.notes ?? 'This property has no online guest registration.'),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
    return;
  }
  final vehicleId = session.vehicleId;
  if (vehicleId == null) return showError(context, 'Add a car first.');
  final maxH = p.guestRules.maxDurationHours;
  final duration = maxH > 0 && maxH < 8 ? maxH : 8;
  try {
    final reg = await api.createDraft(
      vehicleId: vehicleId,
      propertyId: p.propertyId,
      role: Role.visitor,
      host: session.hostFor(p.propertyId) ?? const Host(),
      durationHours: duration,
    );
    await NotificationService.showCheck1(reg.summary);
    if (context.mounted) await showCheck1(context, reg);
  } on ApiError catch (e) {
    if (!context.mounted) return;
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.do_not_disturb_on_outlined, color: P.tow),
        title: Text("Can't register at ${p.name}"),
        content: Text(e.message),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
  }
}

Future<void> showCheck1(BuildContext context, Registration reg) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: P.ground,
      constraints: const BoxConstraints(maxWidth: 480),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => Check1Sheet(initial: reg),
    );

class Check1Sheet extends ConsumerStatefulWidget {
  final Registration initial;
  const Check1Sheet({super.key, required this.initial});
  @override
  ConsumerState<Check1Sheet> createState() => _Check1SheetState();
}

class _Check1SheetState extends ConsumerState<Check1Sheet> {
  late Registration reg = widget.initial;
  bool busy = false;

  Future<void> run(Future<Registration> Function() call) async {
    setState(() => busy = true);
    try {
      final r = await call();
      if (mounted) setState(() => reg = r);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> register() async {
    setState(() => busy = true);
    try {
      final r = await ref.read(apiProvider).confirmRegistration(reg.registrationId);
      if (reg.host != null) {
        await ref.read(sessionProvider).rememberHost(reg.property.propertyId, reg.host!);
      }
      if (!mounted) return;
      final nav = Navigator.of(context);
      nav.pop();
      nav.push(MaterialPageRoute(builder: (_) => StatusScreen(initial: r)));
    } catch (e) {
      if (mounted) {
        setState(() => busy = false);
        showError(context, e);
      }
    }
  }

  Future<void> notParking() async {
    try {
      await ref.read(apiProvider).cancelRegistration(reg.registrationId);
    } catch (_) {}
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Center(
          child: Container(
              width: 40, height: 4, decoration: BoxDecoration(color: P.line, borderRadius: BorderRadius.circular(4))),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: P.permit, borderRadius: BorderRadius.circular(99)),
            child: const Text('CHECK 1 OF 2', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: 1)),
          ),
          const Spacer(),
          PlateBadge(reg.vehicle.plate, reg.vehicle.state),
        ]),
        const SizedBox(height: 14),
        Text(reg.property.name, style: t.headlineMedium),
        const SizedBox(height: 8),
        Text(reg.summary, style: t.titleMedium?.copyWith(fontWeight: FontWeight.w500, height: 1.35)),
        if (reg.alternatives.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text('Not here?', style: t.labelMedium?.copyWith(color: P.muted)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final a in reg.alternatives)
              ActionChip(
                label: Text(a.name),
                avatar: const Icon(Icons.swap_horiz, size: 18),
                onPressed: busy
                    ? null
                    : () => run(() => ref
                        .read(apiProvider)
                        .patchRegistration(reg.registrationId, {'property_id': a.propertyId})),
              ),
          ]),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: busy ? null : register,
          child: busy
              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
              : const Text('Register'),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: busy
                  ? null
                  : () async {
                      final patch = await showModalBottomSheet<Map<String, dynamic>>(
                        context: context,
                        isScrollControlled: true,
                        useSafeArea: true,
                        constraints: const BoxConstraints(maxWidth: 480),
                        builder: (_) => EditSheet(reg: reg),
                      );
                      if (patch != null && patch.isNotEmpty) {
                        await run(() => ref.read(apiProvider).patchRegistration(reg.registrationId, patch));
                      }
                    },
              child: const Text('Edit'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: OutlinedButton(onPressed: busy ? null : notParking, child: const Text('Not parking'))),
        ]),
      ]),
    );
  }
}

/// Edit host, unit, duration, role and car; returns a PATCH body.
class EditSheet extends ConsumerStatefulWidget {
  final Registration reg;
  const EditSheet({super.key, required this.reg});
  @override
  ConsumerState<EditSheet> createState() => _EditSheetState();
}

class _EditSheetState extends ConsumerState<EditSheet> {
  late Role role = widget.reg.role;
  late final hostName = TextEditingController(text: widget.reg.host?.name ?? '');
  late final hostUnit = TextEditingController(text: widget.reg.host?.unit ?? '');
  late double hours = widget.reg.durationHours.toDouble();
  late String vehicleId = widget.reg.vehicle.vehicleId ?? '';

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final vehicles = ref.watch(vehiclesProvider).valueOrNull ?? const <Vehicle>[];
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text('Edit registration', style: t.headlineSmall),
          const SizedBox(height: 16),
          SegmentedButton<Role>(
            segments: const [
              ButtonSegment(value: Role.visitor, label: Text("I'm visiting")),
              ButtonSegment(value: Role.resident, label: Text('I live here')),
            ],
            selected: {role},
            onSelectionChanged: (s) => setState(() => role = s.first),
          ),
          if (role == Role.visitor) ...[
            const SizedBox(height: 14),
            TextField(
                controller: hostName,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: "Who you're visiting")),
            const SizedBox(height: 12),
            TextField(controller: hostUnit, decoration: const InputDecoration(labelText: 'Their unit')),
          ],
          const SizedBox(height: 16),
          Text('Park for ${hours.round()} hours', style: t.titleMedium),
          Slider(value: hours, min: 1, max: 48, divisions: 47, onChanged: (v) => setState(() => hours = v)),
          if (vehicles.length > 1)
            DropdownButtonFormField<String>(
              initialValue: vehicles.any((v) => v.vehicleId == vehicleId) ? vehicleId : null,
              decoration: const InputDecoration(labelText: 'Car'),
              items: [
                for (final v in vehicles) DropdownMenuItem(value: v.vehicleId, child: Text('${v.label} · ${v.plate}'))
              ],
              onChanged: (v) => setState(() => vehicleId = v ?? vehicleId),
            ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () => Navigator.pop(context, <String, dynamic>{
              'role': role.name,
              'host': role == Role.visitor
                  ? {
                      'name': hostName.text.trim().isEmpty ? null : hostName.text.trim(),
                      'unit': hostUnit.text.trim().isEmpty ? null : hostUnit.text.trim()
                    }
                  : null,
              'duration_hours': hours.round(),
              if (vehicleId.isNotEmpty && vehicleId != widget.reg.vehicle.vehicleId) 'vehicle_id': vehicleId,
            }),
            child: const Text('Save'),
          ),
        ]),
      ),
    );
  }
}
