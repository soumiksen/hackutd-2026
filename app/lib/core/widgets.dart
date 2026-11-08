import 'dart:async';

import 'package:flutter/material.dart';

import '../models/models.dart';
import 'theme.dart';

/// License-plate badge, used wherever a car is shown.
class PlateBadge extends StatelessWidget {
  final String plate, state;
  const PlateBadge(this.plate, this.state, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: P.ink, width: 2),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(plate,
              style: const TextStyle(
                  fontFamily: 'monospace', fontWeight: FontWeight.w800, fontSize: 16, letterSpacing: 1.5, color: P.ink)),
          Text(state.toUpperCase(),
              style: const TextStyle(fontSize: 9, letterSpacing: 2, fontWeight: FontWeight.w700, color: P.muted)),
        ]),
      );
}

class StatusChip extends StatelessWidget {
  final RegistrationStatus status;
  const StatusChip(this.status, {super.key});

  static (String, Color, Color) styleOf(RegistrationStatus s) => switch (s) {
        RegistrationStatus.confirmed => ('Active', P.sign, P.signSoft),
        RegistrationStatus.submitting => ('Agent working', P.agent, P.agentSoft),
        RegistrationStatus.awaitingConfirm || RegistrationStatus.drafted => ('Waiting for you', P.ink, P.permitSoft),
        RegistrationStatus.needsUser => ('Needs you', P.ink, P.permit),
        RegistrationStatus.failed => ('Failed', P.tow, P.towSoft),
        RegistrationStatus.cancelled => ('Cancelled', P.muted, P.line),
        RegistrationStatus.expired => ('Expired', P.muted, P.line),
        RegistrationStatus.finished => ('Finished', P.muted, P.line),
      };

  @override
  Widget build(BuildContext context) {
    final (label, fg, bg) = styleOf(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
      child: Text(label, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 13)),
    );
  }
}

/// Live "3h 12m left" text for a pass.
class Countdown extends StatefulWidget {
  final DateTime until;
  final TextStyle? style;
  const Countdown(this.until, {super.key, this.style});
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
    final text = left.isNegative
        ? 'Expired'
        : left.inHours > 0
            ? '${left.inHours}h ${left.inMinutes.remainder(60)}m left'
            : '${left.inMinutes}m ${left.inSeconds.remainder(60).toString().padLeft(2, '0')}s left';
    return Text(text, style: widget.style);
  }
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

void showError(BuildContext context, Object e) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text('$e'), backgroundColor: P.tow, behavior: SnackBarBehavior.floating));
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
