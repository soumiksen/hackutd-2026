import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import 'theme.dart';

/// The "P" parking-sign mark used as the logo.
class ParkMark extends StatelessWidget {
  final double size;
  final bool inverted;
  const ParkMark({super.key, this.size = 36, this.inverted = false});
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: inverted ? Colors.white : P.sign,
          borderRadius: BorderRadius.circular(size * 0.28),
          border: Border.all(color: inverted ? P.sign : Colors.white, width: size * 0.06),
          boxShadow: inverted ? null : const [BoxShadow(color: Color(0x330B6B45), blurRadius: 10, offset: Offset(0, 4))],
        ),
        alignment: Alignment.center,
        child: Text('P',
            style: TextStyle(
                color: inverted ? P.sign : Colors.white,
                fontSize: size * 0.62,
                fontWeight: FontWeight.w900,
                height: 1)),
      );
}

/// White card with a hairline border and soft shadow.
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color color;
  final Color borderColor;
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(S.lg),
    this.onTap,
    this.color = P.card,
    this.borderColor = P.line,
  });
  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(S.rLg);
    return DecoratedBox(
      decoration: BoxDecoration(
          color: color, borderRadius: radius, border: Border.all(color: borderColor), boxShadow: softShadow),
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap == null
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  onTap!();
                },
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// Section title with an optional trailing action.
class SectionHeader extends StatelessWidget {
  final String title;
  final String? action;
  final VoidCallback? onAction;
  const SectionHeader(this.title, {super.key, this.action, this.onAction});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: S.sm),
        child: Row(children: [
          Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
          if (action != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: Size.zero),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(action!),
                const SizedBox(width: 2),
                const Icon(Icons.chevron_right, size: 18),
              ]),
            ),
        ]),
      );
}

/// Small rounded label, e.g. "CHECK 1 OF 2" or "Tow enforced".
class Pill extends StatelessWidget {
  final String label;
  final Color fg, bg;
  final IconData? icon;
  final bool caps;
  const Pill(this.label, {super.key, this.fg = P.ink, this.bg = P.line, this.icon, this.caps = false});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 14, color: fg), const SizedBox(width: 5)],
          Text(caps ? label.toUpperCase() : label,
              style: TextStyle(
                  color: fg, fontWeight: FontWeight.w800, fontSize: caps ? 11.5 : 13, letterSpacing: caps ? 1 : 0)),
        ]),
      );
}

/// Icon + label + value, used for guest rules and pass details.
class InfoTile extends StatelessWidget {
  final IconData icon;
  final String label, value;
  final Color tint;
  const InfoTile({super.key, required this.icon, required this.label, required this.value, this.tint = P.sign});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(S.md),
        decoration: BoxDecoration(
            color: P.card, borderRadius: BorderRadius.circular(S.rMd), border: Border.all(color: P.line)),
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: tint.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 20, color: tint),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: const TextStyle(color: P.muted, fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(height: 1),
              Text(value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: P.ink)),
            ]),
          ),
        ]),
      );
}

/// Friendly empty or error state with an icon and optional action.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title, body;
  final String? action;
  final VoidCallback? onAction;
  final Color tint;
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.action,
    this.onAction,
    this.tint = P.sign,
  });
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(S.xl, S.xxl, S.xl, S.xl),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(S.rLg),
          border: Border.all(color: P.line, width: 1.5),
          color: P.card.withValues(alpha: 0.6),
        ),
        child: Column(children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(color: tint.withValues(alpha: 0.1), shape: BoxShape.circle),
            child: Icon(icon, color: tint, size: 28),
          ),
          const SizedBox(height: S.md),
          Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: S.xs),
          Text(body, textAlign: TextAlign.center, style: const TextStyle(color: P.muted, height: 1.4)),
          if (action != null) ...[
            const SizedBox(height: S.md),
            TextButton(onPressed: onAction, child: Text(action!)),
          ],
        ]),
      );
}

/// Pulsing grey block shown while content loads.
class Skeleton extends StatefulWidget {
  final double height;
  final double radius;
  const Skeleton({super.key, this.height = 120, this.radius = S.rLg});
  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);
  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: c,
        builder: (_, _) => Container(
          height: widget.height,
          decoration: BoxDecoration(
            color: Color.lerp(P.line, const Color(0xFFEDF0EB), c.value),
            borderRadius: BorderRadius.circular(widget.radius),
          ),
        ),
      );
}

/// License-plate badge, used wherever a car is shown.
class PlateBadge extends StatelessWidget {
  final String plate, state;
  final bool large;
  const PlateBadge(this.plate, this.state, {super.key, this.large = false});
  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(horizontal: large ? 14 : 10, vertical: large ? 6 : 4),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: P.ink, width: 2),
          borderRadius: BorderRadius.circular(large ? 9 : 7),
          boxShadow: const [BoxShadow(color: Color(0x14101A15), blurRadius: 4, offset: Offset(0, 2))],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(state.toUpperCase(),
              style: TextStyle(
                  fontSize: large ? 9.5 : 8, letterSpacing: 2.2, fontWeight: FontWeight.w800, color: P.tow, height: 1.1)),
          Text(plate,
              style: TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w800,
                  fontSize: large ? 21 : 15,
                  letterSpacing: 1.6,
                  color: P.ink,
                  height: 1.15)),
        ]),
      );
}

class StatusChip extends StatelessWidget {
  final RegistrationStatus status;
  const StatusChip(this.status, {super.key});

  static (String, Color, Color, IconData) styleOf(RegistrationStatus s) => switch (s) {
        RegistrationStatus.confirmed => ('Active', P.sign, P.signSoft, Icons.verified_rounded),
        RegistrationStatus.submitting => ('Agent working', P.agent, P.agentSoft, Icons.bolt_rounded),
        RegistrationStatus.awaitingConfirm ||
        RegistrationStatus.drafted =>
          ('Waiting for you', P.ink, P.permitSoft, Icons.schedule_rounded),
        RegistrationStatus.needsUser => ('Needs you', P.ink, P.permit, Icons.front_hand_rounded),
        RegistrationStatus.failed => ('Failed', P.tow, P.towSoft, Icons.error_rounded),
        RegistrationStatus.cancelled => ('Cancelled', P.muted, P.line, Icons.block_rounded),
        RegistrationStatus.expired => ('Expired', P.muted, P.line, Icons.history_rounded),
        RegistrationStatus.finished => ('Finished', P.muted, P.line, Icons.done_all_rounded),
      };

  @override
  Widget build(BuildContext context) {
    final (label, fg, bg, icon) = styleOf(status);
    return Pill(label, fg: fg, bg: bg, icon: icon);
  }
}

/// Live "3h 12m left" text for a pass.
class Countdown extends StatefulWidget {
  final DateTime until;
  final TextStyle? style;
  final bool compact;
  const Countdown(this.until, {super.key, this.style, this.compact = false});
  @override
  State<Countdown> createState() => _CountdownState();
}

class _CountdownState extends State<Countdown> {
  late final Timer _t;
  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final left = widget.until.difference(DateTime.now());
    final suffix = widget.compact ? '' : ' left';
    final text = left.isNegative
        ? 'Expired'
        : left.inHours > 0
            ? '${left.inHours}h ${left.inMinutes.remainder(60)}m$suffix'
            : '${left.inMinutes}m ${left.inSeconds.remainder(60).toString().padLeft(2, '0')}s$suffix';
    return Text(text, style: widget.style);
  }
}

/// Ring that drains as a pass runs out. Rebuilds every 30 s.
class TimeRing extends StatefulWidget {
  final DateTime? start;
  final DateTime until;
  final double size;
  final Color color;
  final Color track;
  final Widget? child;
  const TimeRing({
    super.key,
    this.start,
    required this.until,
    this.size = 64,
    this.color = P.sign,
    this.track = P.signSoft,
    this.child,
  });
  @override
  State<TimeRing> createState() => _TimeRingState();
}

class _TimeRingState extends State<TimeRing> {
  late final Timer _t;
  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 30), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final start = widget.start ?? now.subtract(const Duration(hours: 8));
    final total = widget.until.difference(start).inSeconds;
    final left = widget.until.difference(now).inSeconds;
    final frac = total <= 0 ? 0.0 : (left / total).clamp(0.0, 1.0);
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(alignment: Alignment.center, children: [
        SizedBox.expand(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: frac),
            duration: const Duration(milliseconds: 900),
            curve: Curves.easeOutCubic,
            builder: (_, v, _) => CircularProgressIndicator(
              value: v,
              strokeWidth: widget.size * 0.09,
              strokeCap: StrokeCap.round,
              color: widget.color,
              backgroundColor: widget.track,
            ),
          ),
        ),
        if (widget.child != null) widget.child!,
      ]),
    );
  }
}

/// Scales down slightly while pressed, for big tappable surfaces.
class PressScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  const PressScale({super.key, required this.child, this.onTap});
  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool down = false;
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTapDown: widget.onTap == null ? null : (_) => setState(() => down = true),
        onTapCancel: () => setState(() => down = false),
        onTapUp: (_) => setState(() => down = false),
        onTap: widget.onTap == null
            ? null
            : () {
                HapticFeedback.mediumImpact();
                widget.onTap!();
              },
        child: AnimatedScale(
          scale: down ? 0.97 : 1,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: widget.child,
        ),
      );
}

/// Fades and slides a child in when it first appears; [index] staggers lists.
class Appear extends StatelessWidget {
  final Widget child;
  final int index;
  const Appear({super.key, required this.child, this.index = 0});
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: Duration(milliseconds: 380 + 60 * index.clamp(0, 8)),
        curve: Curves.easeOutCubic,
        builder: (_, v, c) => Opacity(
          opacity: v,
          child: Transform.translate(offset: Offset(0, 14 * (1 - v)), child: c),
        ),
        child: child,
      );
}

String formatTime(DateTime? t) {
  if (t == null) return '';
  final l = t.toLocal();
  final h = l.hour % 12 == 0 ? 12 : l.hour % 12;
  final m = l.minute.toString().padLeft(2, '0');
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final now = DateTime.now();
  final sameDay = l.year == now.year && l.month == now.month && l.day == now.day;
  return '$h:$m ${l.hour < 12 ? 'AM' : 'PM'}${sameDay ? '' : ' ${days[l.weekday - 1]}'}';
}

String formatDistance(double? m) {
  if (m == null) return '';
  return m < 1000 ? '${m.round()} m' : '${(m / 1609).toStringAsFixed(1)} mi';
}

void showError(BuildContext context, Object e) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Row(children: [
        const Icon(Icons.error_outline_rounded, color: Colors.white, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text('$e')),
      ]),
      backgroundColor: P.tow,
    ));
}

void showToast(BuildContext context, String text, {IconData icon = Icons.check_circle_rounded}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Row(children: [
        Icon(icon, color: Colors.white, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
      ]),
    ));
}

/// Narrow, phone-shaped column so the web demo looks like the phone app.
class PhoneFrame extends StatelessWidget {
  final Widget child;
  const PhoneFrame({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: child),
      );
}
