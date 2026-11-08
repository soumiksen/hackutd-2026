import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../services/session.dart';
import '../arrival/arrival_watcher.dart';
import '../check1/check1_sheet.dart' show maverickId;

class SettingsScreen extends ConsumerStatefulWidget {
  final VoidCallback onReset;
  const SettingsScreen({super.key, required this.onReset});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final session = ref.watch(sessionProvider);
    final api = ref.watch(apiProvider);
    final health = ref.watch(healthProvider);
    final vehicles = ref.watch(vehiclesProvider);
    final name = session.firstName;

    return ListView(
      padding: S.page,
      children: [
        Text('Settings', style: t.headlineMedium),
        const SizedBox(height: S.lg),

        // Profile header
        AppCard(
          child: Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: P.signSoft,
                child: Text(
                  name.isEmpty ? '?' : name[0].toUpperCase(),
                  style: const TextStyle(color: P.sign, fontWeight: FontWeight.w900, fontSize: 22),
                ),
              ),
              const SizedBox(width: S.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name.isEmpty ? 'Guest' : name, style: t.titleLarge),
                    Text(
                      session.signedIn
                          ? (session.email ?? 'Signed in')
                          : 'Not signed in. Create an account to keep your cars on every device.',
                      style: const TextStyle(color: P.muted, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: S.md),
        if (session.signedIn)
          OutlinedButton.icon(
            onPressed: () async {
              try {
                await api.signOut(); // ends this session on the server
              } catch (_) {} // already expired is fine
              await session.clearSession();
              widget.onReset();
            },
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Sign out'),
          )
        else
          FilledButton.icon(
            onPressed: () async {
              final done = await showDialog<bool>(context: context, builder: (_) => const _CreateAccountDialog());
              if (done == true && context.mounted) {
                showToast(context, 'Account created', icon: Icons.check_circle_outline_rounded);
                setState(() {});
              }
            },
            icon: const Icon(Icons.person_add_alt_1_rounded),
            label: const Text('Create account'),
          ),
        const SizedBox(height: S.xl),

        Text('YOUR CARS', style: t.labelMedium),
        const SizedBox(height: S.sm),
        ...vehicles.when(
          loading: () => [const Skeleton(height: 72)],
          error: (e, _) => [Text('$e', style: const TextStyle(color: P.muted))],
          data: (list) => [
            for (final v in list)
              Padding(
                padding: const EdgeInsets.only(bottom: S.sm),
                child: AppCard(
                  onTap: () async {
                    await session.setVehicle(v.vehicleId!);
                    setState(() {});
                  },
                  borderColor: v.vehicleId == session.vehicleId ? P.sign : P.line,
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      PlateBadge(v.plate, v.state),
                      const SizedBox(width: S.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(v.label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
                            Text(
                              v.vehicleId == session.vehicleId ? 'Used for new registrations' : 'Tap to use this car',
                              style: const TextStyle(color: P.muted, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: v.vehicleId == session.vehicleId
                            ? const Icon(Icons.check_circle_rounded, color: P.sign, key: ValueKey(1))
                            : const Icon(Icons.circle_outlined, color: P.line, key: ValueKey(0)),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: S.lg),

        Text('APP', style: t.labelMedium),
        const SizedBox(height: S.sm),
        AppCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              SwitchListTile(
                secondary: const _IconBox(Icons.science_outlined, P.agent),
                title: const Text('Demo mode', style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: const Text('Show "Simulate arrival" on the home screen.'),
                value: session.demoMode,
                onChanged: (v) => setState(() => session.demoMode = v),
              ),
              const Divider(indent: 16, endIndent: 16),
              ListTile(
                leading: const _IconBox(Icons.timer_outlined, P.agent),
                title: const Text('Test notification in 10s', style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: const Text('Always Maverick Place. Tap, then leave the app or lock the phone.'),
                trailing: const Icon(Icons.chevron_right_rounded, color: P.faint),
                onTap: () async {
                  try {
                    // Always Maverick Place, whatever the campus toggle or the phone's location says.
                    final p = await ref.read(apiProvider).getProperty(maverickId);
                    await ref.read(arrivalProvider.notifier).scheduleTest(p);
                    if (context.mounted) {
                      showToast(
                        context,
                        'Notification in 10 seconds. Go to the home screen to see it.',
                        icon: Icons.timer_outlined,
                      );
                    }
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
              ),
              const Divider(indent: 16, endIndent: 16),
              ListTile(
                leading: const _IconBox(Icons.notifications_active_outlined, P.sign),
                title: const Text('Preview arrival alert', style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: const Text('Shows the "Do you want to park here?" island.'),
                trailing: const Icon(Icons.chevron_right_rounded, color: P.faint),
                onTap: () async {
                  try {
                    final campus = ref.read(campusProvider);
                    final list = await ref.read(campusPropertiesProvider(campus).future);
                    final p = list.where((p) => p.hasPortal).firstOrNull;
                    if (p != null) ref.read(arrivalProvider.notifier).preview(p);
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
              ),
              const Divider(indent: 16, endIndent: 16),
              ListTile(
                leading: const _IconBox(Icons.dns_outlined, P.sign),
                title: const Text('Backend', style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(api.baseUrl, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: health.when(
                  loading: () =>
                      const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  error: (_, _) => const Pill('Offline', fg: P.tow, bg: P.towSoft),
                  data: (ok) => ok
                      ? const Pill('Online', fg: P.sign, bg: P.signSoft, icon: Icons.circle)
                      : const Pill('Offline', fg: P.tow, bg: P.towSoft),
                ),
                onTap: () => ref.invalidate(healthProvider),
              ),
              const Divider(indent: 16, endIndent: 16),
              ListTile(
                leading: const _IconBox(Icons.fingerprint_rounded, P.inkSoft),
                title: const Text('Device ID', style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(
                  session.userId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                trailing: const Icon(Icons.copy_rounded, size: 18, color: P.faint),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: session.userId));
                  showToast(context, 'Device ID copied', icon: Icons.copy_rounded);
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: S.xl),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: P.tow),
          onPressed: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('Start onboarding again?'),
                content: const Text('Your saved car and name on this device will be cleared.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: P.tow, minimumSize: const Size(0, 44)),
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Start over'),
                  ),
                ],
              ),
            );
            if (ok != true) return;
            if (session.signedIn) {
              try {
                await api.signOut();
              } catch (_) {}
            }
            await session.reset();
            widget.onReset();
          },
          icon: const Icon(Icons.restart_alt_rounded),
          label: const Text('Start onboarding again'),
        ),
      ],
    );
  }
}

/// For people who started before accounts existed: adds an email and password to this device's profile.
class _CreateAccountDialog extends ConsumerStatefulWidget {
  const _CreateAccountDialog();
  @override
  ConsumerState<_CreateAccountDialog> createState() => _CreateAccountDialogState();
}

class _CreateAccountDialogState extends ConsumerState<_CreateAccountDialog> {
  final form = GlobalKey<FormState>();
  final email = TextEditingController();
  final password = TextEditingController();
  bool busy = false;

  Future<void> submit() async {
    if (!form.currentState!.validate()) return;
    setState(() => busy = true);
    final api = ref.read(apiProvider);
    final session = ref.read(sessionProvider);
    try {
      final me = await api.getMe(); // the profile this device already saved: name, phone, consent
      final auth = await api.signUp(
        email: email.text.trim(),
        password: password.text,
        name: me.name,
        phone: me.phone,
        consentRegister: me.consentRegister,
        notifyChannel: me.notifyChannel,
      );
      api.setToken(auth.token);
      await session.saveSession(token: auth.token, email: auth.user.email, name: auth.user.name);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Create account'),
        content: Form(
          key: form,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(
              controller: email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email'),
              validator: (v) => (v ?? '').contains('@') ? null : 'Enter an email',
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password', helperText: 'At least 8 characters'),
              validator: (v) => (v ?? '').length >= 8 ? null : 'At least 8 characters',
              onFieldSubmitted: (_) => busy ? null : submit(),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: busy ? null : submit,
            child: busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Create'),
          ),
        ],
      );
}

class _IconBox extends StatelessWidget {
  final IconData icon;
  final Color color;
  const _IconBox(this.icon, this.color);
  @override
  Widget build(BuildContext context) => Container(
    width: 36,
    height: 36,
    decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
    child: Icon(icon, color: color, size: 20),
  );
}
