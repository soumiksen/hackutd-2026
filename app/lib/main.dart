import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/theme.dart';
import 'core/widgets.dart';
import 'features/home/home_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/passes/passes_screen.dart';
import 'features/settings/settings_screen.dart';
import 'services/notification_service.dart';
import 'services/session.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  await NotificationService.init();
  runApp(ProviderScope(
    overrides: [prefsProvider.overrideWithValue(prefs)],
    child: const ParkourApp(),
  ));
}

class ParkourApp extends ConsumerStatefulWidget {
  const ParkourApp({super.key});
  @override
  ConsumerState<ParkourApp> createState() => _ParkourAppState();
}

class _ParkourAppState extends ConsumerState<ParkourApp> {
  @override
  Widget build(BuildContext context) {
    final onboarded = ref.watch(sessionProvider).onboarded;
    return MaterialApp(
      title: 'Parkour',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: onboarded
          ? Shell(onReset: () => setState(() {}))
          : OnboardingScreen(onDone: () {
              ref.read(refreshTick.notifier).state++;
              setState(() {});
            }),
    );
  }
}

class Shell extends StatefulWidget {
  final VoidCallback onReset;
  const Shell({super.key, required this.onReset});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int tab = 0;
  @override
  Widget build(BuildContext context) {
    final pages = [
      HomeScreen(onOpenPasses: () => setState(() => tab = 1)),
      const PassesScreen(),
      SettingsScreen(onReset: widget.onReset),
    ];
    return Scaffold(
      body: SafeArea(child: PhoneFrame(child: pages[tab])),
      bottomNavigationBar: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (i) => setState(() => tab = i),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.local_parking), label: 'Park'),
              NavigationDestination(icon: Icon(Icons.confirmation_number_outlined), label: 'Passes'),
              NavigationDestination(icon: Icon(Icons.tune), label: 'Settings'),
            ],
          ),
        ),
      ),
    );
  }
}
