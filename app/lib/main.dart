import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/theme.dart';
import 'core/widgets.dart';
import 'features/arrival/arrival_watcher.dart';
import 'features/arrival/park_island.dart';
import 'features/home/home_screen.dart';
import 'features/map/map_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/passes/passes_screen.dart';
import 'features/settings/settings_screen.dart';
import 'services/notification_service.dart';
import 'services/session.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  await NotificationService.init();
  runApp(ProviderScope(overrides: [prefsProvider.overrideWithValue(prefs)], child: const ParkourApp()));
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
          : OnboardingScreen(
              onDone: () {
                ref.read(refreshTick.notifier).state++;
                setState(() {});
              },
            ),
    );
  }
}

class Shell extends ConsumerStatefulWidget {
  final VoidCallback onReset;
  const Shell({super.key, required this.onReset});
  @override
  ConsumerState<Shell> createState() => _ShellState();
}

class _ShellState extends ConsumerState<Shell> {
  int tab = 0;

  @override
  void initState() {
    super.initState();
    // Start watching location for "Do you want to park here?" prompts.
    WidgetsBinding.instance.addPostFrameCallback((_) => ref.read(arrivalProvider.notifier).start());
    // Tapping a "Do you want to park here?" notification opens the island.
    NotificationService.onTap = (payload) => ref.read(arrivalProvider.notifier).openFromNotification(payload);
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomeScreen(onOpenPasses: () => setState(() => tab = 2), onOpenMap: () => setState(() => tab = 1)),
      const MapScreen(),
      const PassesScreen(),
      SettingsScreen(onReset: widget.onReset),
    ];
    return Stack(
      children: [
        Scaffold(
          body: SafeArea(
            bottom: false,
            child: PhoneFrame(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOut,
                child: KeyedSubtree(key: ValueKey(tab), child: pages[tab]),
              ),
            ),
          ),
          bottomNavigationBar: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: P.line)),
                ),
                child: NavigationBar(
                  selectedIndex: tab,
                  onDestinationSelected: (i) {
                    HapticFeedback.selectionClick();
                    setState(() => tab = i);
                  },
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.local_parking_outlined),
                      selectedIcon: Icon(Icons.local_parking_rounded),
                      label: 'Park',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.map_outlined),
                      selectedIcon: Icon(Icons.map_rounded),
                      label: 'Map',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.confirmation_number_outlined),
                      selectedIcon: Icon(Icons.confirmation_number_rounded),
                      label: 'Passes',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.tune_outlined),
                      selectedIcon: Icon(Icons.tune_rounded),
                      label: 'Settings',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const ParkIsland(),
      ],
    );
  }
}
