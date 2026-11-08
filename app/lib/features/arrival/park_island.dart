import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../models/models.dart';
import '../check1/check1_sheet.dart';
import 'arrival_watcher.dart';

/// Bright green that reads well on the black island.
const _mint = Color(0xFF3DDC97);

/// A Dynamic Island style prompt: a black pill at the top of the screen that
/// grows into a card asking "Do you want to park here?".
///
/// On iPhones with a Dynamic Island it starts exactly on top of the hardware
/// island, so it looks like the island itself is expanding.
class ParkIsland extends ConsumerStatefulWidget {
  const ParkIsland({super.key});
  @override
  ConsumerState<ParkIsland> createState() => _ParkIslandState();
}

class _ParkIslandState extends ConsumerState<ParkIsland> with TickerProviderStateMixin {
  static const autoHide = Duration(seconds: 15);

  late final expand = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
    reverseDuration: const Duration(milliseconds: 380),
  );
  late final timer = AnimationController(vsync: this, duration: autoHide);
  Property? shown;

  @override
  void initState() {
    super.initState();
    timer.addStatusListener((s) {
      if (s == AnimationStatus.completed) ref.read(arrivalProvider.notifier).dismiss();
    });
  }

  @override
  void dispose() {
    expand.dispose();
    timer.dispose();
    super.dispose();
  }

  Future<void> _open(Property p) async {
    setState(() => shown = p);
    HapticFeedback.mediumImpact();
    await expand.forward(from: 0);
    if (mounted && shown == p) timer.forward(from: 0);
  }

  Future<void> _close() async {
    timer.stop();
    await expand.reverse();
    if (mounted && ref.read(arrivalProvider) == null) setState(() => shown = null);
  }

  Future<void> _park() async {
    final p = shown;
    if (p == null) return;
    HapticFeedback.lightImpact();
    ref.read(arrivalProvider.notifier).accept();
    await expand.reverse();
    if (mounted) await startArrival(context, ref, p);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<Property?>(arrivalProvider, (prev, next) {
      if (next != null && next.propertyId != shown?.propertyId) {
        _open(next);
      } else if (next == null && shown != null) {
        _close();
      }
    });
    if (shown == null) return const SizedBox.shrink();

    final mq = MediaQuery.of(context);
    final topInset = mq.viewPadding.top;
    // iPhone 14 Pro and later report a ~59pt+ top inset; the island sits at y=11.
    final hasIsland = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS && topInset >= 55;
    final top = hasIsland ? 11.0 : topInset + 8;
    final maxW = math.min(mq.size.width - 16, 440.0);
    // Keep content below the camera when growing out of the hardware island.
    final padTop = hasIsland ? 46.0 : 16.0;
    final fullH = padTop + 146;

    return Positioned(
      top: top,
      left: 0,
      right: 0,
      child: Center(
        child: AnimatedBuilder(
          animation: expand,
          builder: (context, _) {
            final v = Curves.easeOutBack.transform(expand.value.clamp(0.0, 1.0));
            final w = lerpDouble(126, maxW, v)!;
            final h = lerpDouble(37, fullH, v)!;
            final r = lerpDouble(18.5, 46, v)!;
            final content = const Interval(0.45, 1, curve: Curves.easeOut).transform(expand.value);
            // Without a hardware island, fade the pill in instead of popping.
            final pillOpacity = hasIsland ? 1.0 : (expand.value * 3).clamp(0.0, 1.0);
            return Opacity(
              opacity: pillOpacity,
              child: GestureDetector(
                onVerticalDragEnd: (d) {
                  if ((d.primaryVelocity ?? 0) < -150) ref.read(arrivalProvider.notifier).dismiss();
                },
                child: Material(
                  type: MaterialType.transparency,
                  child: Container(
                    width: w,
                    height: h,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(r),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.28 * v.clamp(0.0, 1.0)),
                          blurRadius: 28,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: content <= 0
                        ? null
                        : Opacity(
                            opacity: content,
                            child: Transform.scale(
                              scale: lerpDouble(0.92, 1, content),
                              child: OverflowBox(
                                maxWidth: maxW,
                                maxHeight: fullH,
                                minWidth: maxW,
                                minHeight: fullH,
                                child: _IslandBody(
                                  p: shown!,
                                  timer: timer,
                                  padTop: padTop,
                                  onPark: _park,
                                  onDismiss: () => ref.read(arrivalProvider.notifier).dismiss(),
                                ),
                              ),
                            ),
                          ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _IslandBody extends StatelessWidget {
  final Property p;
  final AnimationController timer;
  final double padTop;
  final VoidCallback onPark, onDismiss;
  const _IslandBody({
    required this.p,
    required this.timer,
    required this.padTop,
    required this.onPark,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final r = p.guestRules;
    final dist = p.distanceM == null ? null : (p.inside ? 'Arrived' : '${formatDistance(p.distanceM)} away');
    return Padding(
      padding: EdgeInsets.fromLTRB(18, padTop, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const _GlowP(),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      [p.campus, ?dist, if (p.towEnforced) 'Tow zone'].join(' · ').toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0x99FFFFFF),
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'Do you want to park here?',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800, height: 1.15),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      p.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _mint, fontSize: 14.5, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _TimerRing(timer: timer, label: '${r.maxDurationHours}h'),
            ],
          ),
          const Spacer(),
          Row(
            children: [
              Expanded(
                child: _IslandButton(label: 'Not now', bg: const Color(0x26FFFFFF), fg: Colors.white, onTap: onDismiss),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: _IslandButton(
                  label: 'Park here',
                  icon: Icons.local_parking_rounded,
                  bg: _mint,
                  fg: Colors.black,
                  onTap: onPark,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Green "P" tile with a soft pulsing glow.
class _GlowP extends StatefulWidget {
  const _GlowP();
  @override
  State<_GlowP> createState() => _GlowPState();
}

class _GlowPState extends State<_GlowP> with SingleTickerProviderStateMixin {
  late final c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat(reverse: true);
  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (_, _) => Container(
      width: 46,
      height: 46,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: P.sign,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: _mint.withValues(alpha: 0.25 + 0.35 * c.value),
            blurRadius: 10 + 10 * c.value,
          ),
        ],
      ),
      child: const Text(
        'P',
        style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w900, height: 1),
      ),
    ),
  );
}

/// Ring that drains while the prompt waits, with the max stay in the middle.
class _TimerRing extends StatelessWidget {
  final AnimationController timer;
  final String label;
  const _TimerRing({required this.timer, required this.label});
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 40,
    height: 40,
    child: AnimatedBuilder(
      animation: timer,
      builder: (_, _) => Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: 1 - timer.value,
            strokeWidth: 3,
            strokeCap: StrokeCap.round,
            color: _mint,
            backgroundColor: const Color(0x22FFFFFF),
          ),
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    ),
  );
}

class _IslandButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color bg, fg;
  final VoidCallback onTap;
  const _IslandButton({required this.label, this.icon, required this.bg, required this.fg, required this.onTap});
  @override
  Widget build(BuildContext context) => PressScale(
    onTap: onTap,
    child: Container(
      height: 46,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(23)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 19, color: fg), const SizedBox(width: 6)],
          Text(
            label,
            style: TextStyle(color: fg, fontSize: 15.5, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    ),
  );
}
