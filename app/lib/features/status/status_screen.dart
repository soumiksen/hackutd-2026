import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../models/models.dart';
import '../../services/session.dart';
import '../passes/passes_screen.dart';

const _stepLabels = {
  'match_property': 'Matched the property',
  'open_portal': 'Opened the parking portal',
  'fill_form': 'Filled in your car and visit',
  'submit': 'Submitted the registration',
  'capture_proof': 'Saved the confirmation',
};

/// Live agent progress. Polls GET /registrations/{id} every 2 s (contract: the app never needs push).
class StatusScreen extends ConsumerStatefulWidget {
  final Registration initial;
  const StatusScreen({super.key, required this.initial});
  @override
  ConsumerState<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends ConsumerState<StatusScreen> {
  late Registration reg = widget.initial;
  Timer? timer;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 2), (_) => poll());
    poll();
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> poll() async {
    try {
      final r = await ref.read(apiProvider).getRegistration(reg.registrationId);
      if (!mounted) return;
      setState(() => reg = r);
      if (!r.status.isActive) {
        timer?.cancel();
        ref.read(refreshTick.notifier).state++;
      }
    } catch (_) {/* keep polling */}
  }

  Future<void> act(Future<Registration> Function() call) async {
    setState(() => busy = true);
    try {
      final r = await call();
      if (!mounted) return;
      setState(() => reg = r);
      timer?.cancel();
      timer = Timer.periodic(const Duration(seconds: 2), (_) => poll());
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Registration')),
      body: PhoneFrame(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 32), children: [
          Row(children: [StatusChip(reg.status)]),
          const SizedBox(height: S.sm),
          Text(reg.property.name, style: t.headlineMedium),
          const SizedBox(height: S.sm),
          Row(children: [
            PlateBadge(reg.vehicle.plate, reg.vehicle.state),
            const SizedBox(width: 10),
            Expanded(child: Text(reg.vehicle.label, style: t.bodyLarge?.copyWith(color: P.muted))),
          ]),
          if (reg.status == RegistrationStatus.submitting) ...[
            const SizedBox(height: S.lg),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: const LinearProgressIndicator(minHeight: 4, color: P.agent, backgroundColor: P.agentSoft),
            ),
            const SizedBox(height: 6),
            const Text('The agent is filling the portal for you. You can leave this screen.',
                style: TextStyle(color: P.muted, fontSize: 13)),
          ],
          const SizedBox(height: S.xl),
          if (reg.status == RegistrationStatus.needsUser && reg.needsUser != null) ...[
            Check2Card(reg: reg, busy: busy, onAct: act),
            const SizedBox(height: 20),
          ],
          if (reg.status == RegistrationStatus.confirmed) ...[
            _Confirmed(reg: reg),
            const SizedBox(height: 20),
          ],
          if (reg.status == RegistrationStatus.failed) ...[
            _Banner(
              color: P.towSoft,
              fg: P.tow,
              icon: Icons.error_outline,
              title: 'Registration failed',
              body: reg.error?.message ?? 'The portal did not accept the registration.',
            ),
            const SizedBox(height: 20),
          ],
          if (reg.status == RegistrationStatus.cancelled) ...[
            const _Banner(
                color: P.line, fg: P.ink, icon: Icons.block, title: 'Cancelled', body: 'Nothing was submitted.'),
            const SizedBox(height: 20),
          ],
          Text('What the agent is doing', style: t.titleLarge),
          const SizedBox(height: 10),
          AppCard(padding: const EdgeInsets.all(S.lg), child: _Steps(reg: reg)),
          const SizedBox(height: 24),
          if (!reg.status.isActive)
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
        ]),
      ),
    );
  }
}

/// Vertical timeline: a dot per step joined by a line that fills in as steps finish.
class _Steps extends StatelessWidget {
  final Registration reg;
  const _Steps({required this.reg});
  @override
  Widget build(BuildContext context) {
    final byName = {for (final s in reg.steps) s.name: s};
    final names = _stepLabels.keys.toList();
    return Column(children: [
      for (final (i, name) in names.indexed)
        Builder(builder: (_) {
          final s = byName[name];
          final status = s?.status ?? StepStatus.pending;
          final nextDone = i + 1 < names.length && (byName[names[i + 1]]?.status ?? StepStatus.pending) != StepStatus.pending;
          final last = i == names.length - 1;
          final (Color fill, Color fg) = switch (status) {
            StepStatus.done => (P.sign, Colors.white),
            StepStatus.running => (P.agentSoft, P.agent),
            StepStatus.error => (P.tow, Colors.white),
            StepStatus.pending => (P.ground, P.faint),
          };
          final Widget dot = AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: fill,
              shape: BoxShape.circle,
              border: Border.all(color: status == StepStatus.pending ? P.line : fill, width: 2),
            ),
            alignment: Alignment.center,
            child: switch (status) {
              StepStatus.done => const Icon(Icons.check_rounded, size: 18, color: Colors.white),
              StepStatus.error => const Icon(Icons.close_rounded, size: 18, color: Colors.white),
              StepStatus.running =>
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2.4, color: P.agent)),
              StepStatus.pending =>
                Text('${i + 1}', style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 13)),
            },
          );
          return IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(
                width: 30,
                child: Column(children: [
                  dot,
                  if (!last)
                    Expanded(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 400),
                        width: 3,
                        margin: const EdgeInsets.symmetric(vertical: 3),
                        decoration: BoxDecoration(
                          color: status == StepStatus.done && nextDone ? P.sign : P.line,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                ]),
              ),
              const SizedBox(width: S.md),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(top: 5, bottom: last ? 0 : S.lg),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: Text(_stepLabels[name]!,
                          style: TextStyle(
                              fontSize: 15.5,
                              fontWeight: status == StepStatus.pending ? FontWeight.w600 : FontWeight.w800,
                              color: switch (status) {
                                StepStatus.pending => P.muted,
                                StepStatus.running => P.agent,
                                StepStatus.error => P.tow,
                                StepStatus.done => P.ink,
                              })),
                    ),
                    if (s?.at != null)
                      Text(formatTime(DateTime.tryParse(s!.at!)),
                          style: const TextStyle(color: P.muted, fontSize: 13, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
            ]),
          );
        }),
    ]);
  }
}

class _Confirmed extends ConsumerWidget {
  final Registration reg;
  const _Confirmed({required this.reg});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final proof = reg.proof;
    return Appear(
      child: Container(
      padding: const EdgeInsets.all(S.xl),
      decoration: BoxDecoration(
        color: P.signSoft,
        borderRadius: BorderRadius.circular(S.rLg),
        border: Border.all(color: P.sign.withValues(alpha: 0.25), width: 1.5),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.4, end: 1),
            duration: const Duration(milliseconds: 600),
            curve: Curves.elasticOut,
            builder: (_, v, c) => Transform.scale(scale: v, child: c),
            child: Container(
              width: 44,
              height: 44,
              decoration: const BoxDecoration(color: P.sign, shape: BoxShape.circle),
              child: const Icon(Icons.check_rounded, color: Colors.white, size: 28),
            ),
          ),
          const SizedBox(width: S.md),
          const Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text("You're registered", style: TextStyle(color: P.signDeep, fontWeight: FontWeight.w800, fontSize: 20)),
              Text('Park with peace of mind. Proof is saved.', style: TextStyle(color: P.sign, fontWeight: FontWeight.w600)),
            ]),
          ),
        ]),
        const SizedBox(height: S.lg),
        Text('CONFIRMATION', style: t.labelMedium),
        SelectableText(proof?.confirmationNumber ?? '-',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: 1)),
        if (proof?.expiresAt != null) ...[
          const SizedBox(height: S.sm),
          Row(children: [
            const Icon(Icons.timer_outlined, size: 18, color: P.sign),
            const SizedBox(width: 6),
            Countdown(proof!.expiresAt!, style: const TextStyle(color: P.sign, fontWeight: FontWeight.w800, fontSize: 16)),
            const Spacer(),
            Text('until ${formatTime(proof.expiresAt)}', style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
        ],
        if (proof != null && proof.screenshotUrls.isNotEmpty) ...[
          const SizedBox(height: 14),
          ProofImage(url: ref.read(apiProvider).proofUrl(proof.screenshotUrls.first)),
        ],
      ]),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final Color color, fg;
  final IconData icon;
  final String title, body;
  const _Banner({required this.color, required this.fg, required this.icon, required this.title, required this.body});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(16)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 4),
              Text(body),
            ]),
          ),
        ]),
      );
}

/// Check 2: the only other time the user is asked anything.
class Check2Card extends ConsumerStatefulWidget {
  final Registration reg;
  final bool busy;
  final Future<void> Function(Future<Registration> Function()) onAct;
  const Check2Card({super.key, required this.reg, required this.busy, required this.onAct});
  @override
  ConsumerState<Check2Card> createState() => _Check2CardState();
}

class _Check2CardState extends ConsumerState<Check2Card> {
  final answer = TextEditingController();

  Future<void> openPortal(String url) async {
    if (kIsWeb) {
      await launchUrl(Uri.parse(url), webOnlyWindowName: '_blank');
    } else {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => _PortalWebView(url: url)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final nu = widget.reg.needsUser!;
    final api = ref.read(apiProvider);
    final id = widget.reg.registrationId;
    final t = Theme.of(context).textTheme;
    final List<Widget> actions = switch (nu.reason) {
      NeedsUserReason.captcha => [
          FilledButton.icon(
            onPressed: nu.portalUrl == null ? null : () => openPortal(nu.portalUrl!),
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open the portal'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: widget.busy ? null : () => widget.onAct(() => api.resumeRegistration(id)),
            child: const Text("I'm done"),
          ),
        ],
      NeedsUserReason.missingInfo => [
          TextField(
            controller: answer,
            autofocus: true,
            decoration: InputDecoration(labelText: (nu.field ?? 'answer').replaceAll('_', ' ')),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: widget.busy
                ? null
                : () {
                    final value = answer.text.trim();
                    final session = ref.read(sessionProvider);
                    final pid = widget.reg.property.propertyId;
                    final old = session.hostFor(pid) ?? widget.reg.host ?? const Host();
                    // remember host answers so the next draft here needs no question
                    if (nu.field == 'host_unit') session.rememberHost(pid, Host(name: old.name, unit: value));
                    if (nu.field == 'host_name') session.rememberHost(pid, Host(name: value, unit: old.unit));
                    widget.onAct(() => api.answerRegistration(id, nu.field ?? 'answer', value));
                  },
            child: const Text('Continue'),
          ),
        ],
      NeedsUserReason.ruleConflict => [
          FilledButton(
            onPressed: widget.busy ? null : () => widget.onAct(() => api.answerRegistration(id, 'override', 'true')),
            child: const Text('Register anyway'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: widget.busy ? null : () => widget.onAct(() => api.answerRegistration(id, 'override', 'false')),
            child: const Text('Cancel'),
          ),
        ],
      NeedsUserReason.payment => const [],
    };
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: P.permitSoft,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: P.permit, width: 2),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: P.permit, borderRadius: BorderRadius.circular(99)),
            child: const Text('CHECK 2 OF 2', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: 1)),
          ),
        ]),
        const SizedBox(height: 10),
        Text(switch (nu.reason) {
          NeedsUserReason.captcha => 'The portal wants a human check',
          NeedsUserReason.missingInfo => 'One quick question',
          NeedsUserReason.ruleConflict => 'Guest limit reached',
          NeedsUserReason.payment => 'Payment needed',
        }, style: t.titleLarge),
        const SizedBox(height: 6),
        Text(nu.message, style: t.bodyLarge),
        if (nu.reason == NeedsUserReason.captcha)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Parkour never solves CAPTCHAs for you.', style: t.bodySmall?.copyWith(color: P.muted)),
          ),
        const SizedBox(height: 14),
        ...actions,
      ]),
    );
  }
}

class _PortalWebView extends StatefulWidget {
  final String url;
  const _PortalWebView({required this.url});
  @override
  State<_PortalWebView> createState() => _PortalWebViewState();
}

class _PortalWebViewState extends State<_PortalWebView> {
  late final controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..loadRequest(Uri.parse(widget.url));
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Parking portal'), actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("I'm done")),
        ]),
        body: WebViewWidget(controller: controller),
      );
}
