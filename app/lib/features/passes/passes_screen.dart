import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../models/models.dart';
import '../../services/session.dart';
import '../check1/check1_sheet.dart';

class PassesScreen extends ConsumerWidget {
  const PassesScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final passes = ref.watch(passesProvider);
    return RefreshIndicator(
      onRefresh: () async => ref.read(refreshTick.notifier).state++,
      child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: [
        Text('Passes', style: t.headlineMedium),
        Text('Every registration, with the portal\'s own confirmation as proof.',
            style: t.bodyMedium?.copyWith(color: P.muted)),
        const SizedBox(height: 16),
        ...passes.when(
          loading: () => [const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))],
          error: (e, _) => [Text('$e')],
          data: (list) => list.isEmpty
              ? [const Text('No passes yet.', style: TextStyle(color: P.muted))]
              : [for (final r in list) Padding(padding: const EdgeInsets.only(bottom: 12), child: PassCard(reg: r))],
        ),
      ]),
    );
  }
}

class PassCard extends ConsumerWidget {
  final Registration reg;
  const PassCard({super.key, required this.reg});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final proof = reg.proof;
    final api = ref.read(apiProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(reg.property.name, style: t.titleLarge)),
            StatusChip(reg.status),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            PlateBadge(reg.vehicle.plate, reg.vehicle.state),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(proof?.confirmationNumber ?? '-',
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 18, fontWeight: FontWeight.w800)),
                if (proof?.expiresAt != null)
                  reg.status == RegistrationStatus.confirmed
                      ? Countdown(proof!.expiresAt!, style: const TextStyle(color: P.sign, fontWeight: FontWeight.w700))
                      : Text('Ended ${formatTime(proof!.expiresAt)}', style: const TextStyle(color: P.muted)),
              ]),
            ),
          ]),
          if (proof != null && proof.screenshotUrls.isNotEmpty) ...[
            const SizedBox(height: 12),
            ProofImage(url: api.proofUrl(proof.screenshotUrls.first), height: 140),
          ],
          if (reg.status == RegistrationStatus.confirmed) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () async {
                try {
                  final r = await api.renewRegistration(reg.registrationId, reg.durationHours);
                  if (context.mounted) await showCheck1(context, r);
                  ref.read(refreshTick.notifier).state++;
                } catch (e) {
                  if (context.mounted) showError(context, e);
                }
              },
              icon: const Icon(Icons.update),
              label: const Text('Renew'),
            ),
          ],
        ]),
      ),
    );
  }
}

/// Screenshot of the portal's confirmation page. Tap to view full size.
class ProofImage extends StatelessWidget {
  final String url;
  final double height;
  const ProofImage({super.key, required this.url, this.height = 220});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () => showDialog(
          context: context,
          builder: (_) => Dialog(
            insetPadding: const EdgeInsets.all(16),
            child: InteractiveViewer(child: Image.network(url)),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            height: height,
            width: double.infinity,
            decoration: BoxDecoration(border: Border.all(color: P.line), borderRadius: BorderRadius.circular(12)),
            child: Image.network(
              url,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              errorBuilder: (_, _, _) => const Center(child: Text('Proof image unavailable')),
            ),
          ),
        ),
      );
}
