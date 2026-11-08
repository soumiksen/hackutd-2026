import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../models/models.dart';
import '../../services/session.dart';
import '../check1/check1_sheet.dart';

class PassesScreen extends ConsumerStatefulWidget {
  const PassesScreen({super.key});
  @override
  ConsumerState<PassesScreen> createState() => _PassesScreenState();
}

class _PassesScreenState extends ConsumerState<PassesScreen> {
  bool showActive = true;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final passes = ref.watch(passesProvider);
    final all = passes.valueOrNull ?? const <Registration>[];
    final active = all.where((r) => r.status == RegistrationStatus.confirmed).toList();
    final past = all.where((r) => r.status != RegistrationStatus.confirmed).toList();
    final shown = showActive ? active : past;

    return RefreshIndicator(
      color: P.sign,
      onRefresh: () async => ref.read(refreshTick.notifier).state++,
      child: ListView(padding: S.page, children: [
        Text('Passes', style: t.headlineMedium),
        const SizedBox(height: 2),
        const Text("Every registration, with the portal's own confirmation as proof.",
            style: TextStyle(color: P.muted)),
        const SizedBox(height: S.lg),
        SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: true, label: Text('Active · ${active.length}')),
            ButtonSegment(value: false, label: Text('History · ${past.length}')),
          ],
          selected: {showActive},
          onSelectionChanged: (s) => setState(() => showActive = s.first),
        ),
        const SizedBox(height: S.lg),
        ...passes.when(
          loading: () => [
            for (var i = 0; i < 2; i++)
              const Padding(padding: EdgeInsets.only(bottom: S.md), child: Skeleton(height: 220)),
          ],
          error: (e, _) => [
            EmptyState(
              icon: Icons.cloud_off_rounded,
              title: "Can't load passes",
              body: '$e',
              tint: P.tow,
              action: 'Try again',
              onAction: () => ref.read(refreshTick.notifier).state++,
            ),
          ],
          data: (_) => shown.isEmpty
              ? [
                  EmptyState(
                    icon: showActive ? Icons.confirmation_number_outlined : Icons.history_rounded,
                    title: showActive ? 'No active pass' : 'No history yet',
                    body: showActive
                        ? "When you park, your proof shows up here with a live countdown."
                        : 'Expired and finished passes are kept here.',
                  ),
                ]
              : [
                  for (final (i, r) in shown.indexed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: S.lg),
                      child: Appear(index: i, child: PassCard(reg: r)),
                    ),
                ],
        ),
      ]),
    );
  }
}

/// A pass shaped like a parking ticket: header, perforation, stub with proof.
class PassCard extends ConsumerWidget {
  final Registration reg;
  const PassCard({super.key, required this.reg});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final proof = reg.proof;
    final api = ref.read(apiProvider);
    final live = reg.status == RegistrationStatus.confirmed;
    final headColor = live ? P.sign : P.inkSoft;

    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(S.rLg), boxShadow: softShadow),
      child: ClipPath(
        clipper: _TicketClipper(notchY: 118),
        child: Container(
          color: P.card,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Header
            Container(
              height: 118,
              padding: const EdgeInsets.fromLTRB(S.lg, S.lg, S.lg, S.md),
              decoration: BoxDecoration(
                gradient: live
                    ? P.heroGradient
                    : const LinearGradient(colors: [Color(0xFF3A4741), P.inkSoft]),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Text('GUEST PARKING PASS',
                      style: TextStyle(
                          color: Color(0xB3FFFFFF), fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.4)),
                  const Spacer(),
                  _HeadChip(reg.status),
                ]),
                const Spacer(),
                Text(reg.property.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(reg.vehicle.label,
                    style: const TextStyle(color: Color(0xCCFFFFFF), fontWeight: FontWeight.w600)),
              ]),
            ),
            // Perforation
            SizedBox(height: 1, child: CustomPaint(painter: _DashPainter(color: headColor.withValues(alpha: 0.25)))),
            // Stub
            Padding(
              padding: const EdgeInsets.all(S.lg),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('CONFIRMATION', style: TextStyle(color: P.muted, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.2)),
                      const SizedBox(height: 2),
                      GestureDetector(
                        onTap: proof?.confirmationNumber == null
                            ? null
                            : () {
                                Clipboard.setData(ClipboardData(text: proof!.confirmationNumber!));
                                showToast(context, 'Confirmation number copied', icon: Icons.copy_rounded);
                              },
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Flexible(
                            child: Text(proof?.confirmationNumber ?? '-',
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontFamily: 'monospace', fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: 0.8)),
                          ),
                          if (proof?.confirmationNumber != null) ...[
                            const SizedBox(width: 6),
                            const Icon(Icons.copy_rounded, size: 15, color: P.faint),
                          ],
                        ]),
                      ),
                    ]),
                  ),
                  PlateBadge(reg.vehicle.plate, reg.vehicle.state),
                ]),
                if (proof?.expiresAt != null) ...[
                  const SizedBox(height: S.md),
                  Row(children: [
                    Icon(live ? Icons.timer_outlined : Icons.event_busy_rounded,
                        size: 18, color: live ? P.sign : P.muted),
                    const SizedBox(width: 6),
                    if (live)
                      Countdown(proof!.expiresAt!, style: const TextStyle(color: P.sign, fontWeight: FontWeight.w800, fontSize: 15))
                    else
                      Text('Ended ${formatTime(proof!.expiresAt)}', style: const TextStyle(color: P.muted, fontWeight: FontWeight.w700)),
                    const Spacer(),
                    if (live)
                      Text('until ${formatTime(proof.expiresAt)}',
                          style: const TextStyle(color: P.muted, fontWeight: FontWeight.w600)),
                  ]),
                  if (live) ...[
                    const SizedBox(height: S.sm),
                    _TimeBar(start: reg.createdAt, until: proof.expiresAt!),
                  ],
                ],
                if (proof != null && proof.screenshotUrls.isNotEmpty) ...[
                  const SizedBox(height: S.md),
                  ProofImage(url: api.proofUrl(proof.screenshotUrls.first), height: 132),
                ],
                if (live) ...[
                  const SizedBox(height: S.md),
                  OutlinedButton.icon(
                    onPressed: () async {
                      try {
                        final r = await api.renewRegistration(reg.registrationId, reg.durationHours);
                        if (context.mounted) await showCheck1(context, r);
                        if (context.mounted) ref.read(refreshTick.notifier).state++;
                      } catch (e) {
                        if (context.mounted) showError(context, e);
                      }
                    },
                    icon: const Icon(Icons.update_rounded),
                    label: Text('Renew for ${reg.durationHours}h'),
                  ),
                ],
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _HeadChip extends StatelessWidget {
  final RegistrationStatus status;
  const _HeadChip(this.status);
  @override
  Widget build(BuildContext context) {
    final (label, _, _, icon) = StatusChip.styleOf(status);
    return Pill(label, fg: Colors.white, bg: Colors.white.withValues(alpha: 0.18), icon: icon);
  }
}

class _TimeBar extends StatelessWidget {
  final DateTime? start;
  final DateTime until;
  const _TimeBar({this.start, required this.until});
  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final s = start ?? now.subtract(const Duration(hours: 8));
    final total = until.difference(s).inSeconds;
    final frac = total <= 0 ? 0.0 : (until.difference(now).inSeconds / total).clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: LinearProgressIndicator(value: frac, minHeight: 6, color: P.sign, backgroundColor: P.signSoft),
    );
  }
}

/// Rounded rectangle with two half-circle notches at the perforation line.
class _TicketClipper extends CustomClipper<Path> {
  final double notchY;
  const _TicketClipper({required this.notchY});
  @override
  Path getClip(Size size) {
    const r = 10.0;
    final outer = Path()
      ..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(S.rLg)));
    final notches = Path()
      ..addOval(Rect.fromCircle(center: Offset(0, notchY), radius: r))
      ..addOval(Rect.fromCircle(center: Offset(size.width, notchY), radius: r));
    return Path.combine(PathOperation.difference, outer, notches);
  }

  @override
  bool shouldReclip(_TicketClipper old) => old.notchY != notchY;
}

class _DashPainter extends CustomPainter {
  final Color color;
  const _DashPainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5;
    const dash = 6.0, gap = 5.0;
    for (var x = 16.0; x < size.width - 16; x += dash + gap) {
      canvas.drawLine(Offset(x, 0), Offset(x + dash, 0), paint);
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) => old.color != color;
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
            clipBehavior: Clip.antiAlias,
            child: InteractiveViewer(child: Image.network(url)),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(S.rMd),
          child: Container(
            height: height,
            width: double.infinity,
            decoration: BoxDecoration(
                color: P.ground, border: Border.all(color: P.line), borderRadius: BorderRadius.circular(S.rMd)),
            child: Stack(fit: StackFit.expand, children: [
              Image.network(
                url,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                errorBuilder: (_, _, _) => const Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.image_not_supported_outlined, color: P.faint),
                    SizedBox(height: 4),
                    Text('Proof image unavailable', style: TextStyle(color: P.muted)),
                  ]),
                ),
              ),
              Positioned(
                right: 8,
                bottom: 8,
                child: Pill('Proof', fg: Colors.white, bg: P.ink.withValues(alpha: 0.75), icon: Icons.zoom_in_rounded),
              ),
            ]),
          ),
        ),
      );
}
