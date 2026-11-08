import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../services/session.dart';

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
    return ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: [
      Text('Settings', style: t.headlineMedium),
      const SizedBox(height: 16),
      Text('Your cars', style: t.titleLarge),
      const SizedBox(height: 8),
      ...vehicles.when(
        loading: () => [const LinearProgressIndicator()],
        error: (e, _) => [Text('$e')],
        data: (list) => [
          for (final v in list)
            Card(
              child: ListTile(
                onTap: () async {
                  await session.setVehicle(v.vehicleId!);
                  setState(() {});
                },
                leading: Icon(v.vehicleId == session.vehicleId ? Icons.check_circle : Icons.circle_outlined,
                    color: v.vehicleId == session.vehicleId ? P.sign : P.line),
                title: Text(v.label),
                subtitle: Text('${v.plate} · ${v.state}'),
              ),
            ),
        ],
      ),
      const SizedBox(height: 20),
      Card(
        child: SwitchListTile(
          title: const Text('Demo mode'),
          subtitle: const Text('Show "Simulate arrival" on the home screen.'),
          value: session.demoMode,
          onChanged: (v) => setState(() => session.demoMode = v),
        ),
      ),
      const SizedBox(height: 12),
      Card(
        child: ListTile(
          title: const Text('Backend'),
          subtitle: Text(api.baseUrl),
          trailing: health.when(
            loading: () => const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            error: (_, _) => const Icon(Icons.cloud_off, color: P.tow),
            data: (ok) => Icon(ok ? Icons.cloud_done : Icons.cloud_off, color: ok ? P.sign : P.tow),
          ),
          onTap: () => ref.invalidate(healthProvider),
        ),
      ),
      const SizedBox(height: 12),
      Card(
        child: ListTile(
          title: const Text('Device ID'),
          subtitle: SelectableText(session.userId, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ),
      ),
      const SizedBox(height: 20),
      OutlinedButton(
        onPressed: () async {
          await session.reset();
          widget.onReset();
        },
        child: const Text('Start onboarding again'),
      ),
    ]);
  }
}
