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
          Row(children: [
            Expanded(child: Text(reg.property.name, style: t.headlineMedium)),
            StatusChip(reg.status),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            PlateBadge(reg.vehicle.plate, reg.vehicle.state),
            const SizedBox(width: 10),
            Expanded(child: Text(reg.vehicle.label, style: t.bodyLarge?.copyWith(color: P.muted))),
          ]),
          const SizedBox(height: 20),
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
          Card(child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: _Steps(reg: reg))),
          const SizedBox(height: 24),
          if (!reg.status.isActive)
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
        ]),
      ),
    );
  }
}

class _Steps extends StatelessWidget {
  final Registration reg;
  const _Steps({required this.reg});
  @override
  Widget build(BuildContext context) {
    final byName = {for (final s in reg.steps) s.name: s};
    return Column(children: [
      for (final name in _stepLabels.keys)
        Builder(builder: (_) {
          final s = byName[name];
          final status = s?.status ?? StepStatus.pending;
          final Widget icon = switch (status) {
            StepStatus.done => const Icon(Icons.check_circle, color: P.sign),
            StepStatus.running => const SizedBox(
                width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: P.agent)),
            StepStatus.error => const Icon(Icons.cancel, color: P.tow),
            StepStatus.pending => const Icon(Icons.radio_button_unchecked, color: P.line),
          };
          return ListTile(
            dense: true,
            leading: SizedBox(width: 28, child: Center(child: icon)),
            title: Text(_stepLabels[name]!,
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: status == StepStatus.running ? FontWeight.w700 : FontWeight.w500,
                    color: status == StepStatus.pending ? P.muted : P.ink)),
            trailing: s?.at == null ? null : Text(formatTime(DateTime.tryParse(s!.at!)), style: const TextStyle(color: P.muted)),
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
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: P.signSoft, borderRadius: BorderRadius.circular(18)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.verified, color: P.sign),
          SizedBox(width: 8),
          Text("You're registered", style: TextStyle(color: P.sign, fontWeight: FontWeight.w800, fontSize: 18)),
        ]),
        const SizedBox(height: 12),
        Text('Confirmation', style: t.labelMedium?.copyWith(color: P.muted)),
        SelectableText(proof?.confirmationNumber ?? '-',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: 1)),
        if (proof?.expiresAt != null) ...[
          const SizedBox(height: 6),
          Text('Valid until ${formatTime(proof!.expiresAt)}', style: t.titleMedium),
          Countdown(proof.expiresAt!, style: const TextStyle(color: P.sign, fontWeight: FontWeight.w700)),
        ],
        if (proof != null && proof.screenshotUrls.isNotEmpty) ...[
          const SizedBox(height: 14),
          ProofImage(url: ref.read(apiProvider).proofUrl(proof.screenshotUrls.first)),
        ],
      ]),
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
