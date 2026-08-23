import 'package:flutter/material.dart';

import 'analytics.dart';
import 'theme.dart';

/// Cold-start intro: a finger shadow swipes up the clay-black screen and
/// "brings" the first real screen with it — sign-in for a new user, the feed
/// for a signed-in one (AuthGate wraps whichever it resolves). Runs once per
/// process; a tap anywhere skips to the end. Pure CustomPainter, no assets.
class SwipeIntro extends StatefulWidget {
  const SwipeIntro(
      {super.key,
      required this.child,
      this.onDone,
      this.duration = const Duration(milliseconds: 1500)});
  final Widget child;
  final VoidCallback? onDone;
  final Duration duration;

  @override
  State<SwipeIntro> createState() => _SwipeIntroState();
}

class _SwipeIntroState extends State<SwipeIntro>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: widget.duration)
        ..addStatusListener((s) {
          if (s == AnimationStatus.completed) _finish();
        })
        ..forward();
  bool _done = false;
  bool _skipped = false;

  void _finish() {
    if (_done) return;
    setState(() => _done = true);
    track(_skipped ? 'intro_skipped' : 'intro_seen');
    widget.onDone?.call();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;
    // The destination slides up under the finger over the back 65% of the run.
    final slide = Tween(begin: const Offset(0, 1), end: Offset.zero).animate(
        CurvedAnimation(
            parent: _c,
            curve: const Interval(0.35, 1, curve: Curves.easeOutCubic)));
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        _skipped = true;
        _c.value = 1.0; // jumps the controller to completed -> _finish
      },
      child: Stack(fit: StackFit.expand, children: [
        const ColoredBox(color: bg),
        SlideTransition(position: slide, child: widget.child),
        IgnorePointer(
          child: AnimatedBuilder(
            animation: _c,
            builder: (_, __) => CustomPaint(
                key: const ValueKey('intro-finger'),
                painter: _FingerPainter(_c.value)),
          ),
        ),
      ]),
    );
  }
}

/// The finger: a blurred shadow blob, a capsule "finger" with a fingertip
/// circle and a green ring (the house monogram language), rising from 82% to
/// 12% of the screen and fading out over the last quarter.
class _FingerPainter extends CustomPainter {
  _FingerPainter(this.p);
  final double p;

  @override
  void paint(Canvas canvas, Size size) {
    if (p >= 1) return;
    final rise = Curves.easeInOutCubic.transform(p.clamp(0.0, 1.0));
    final x = size.width / 2;
    final y = size.height * (0.82 - 0.70 * rise);
    final fade = p < 0.75 ? 1.0 : (1 - (p - 0.75) / 0.25).clamp(0.0, 1.0);
    if (fade == 0) return;
    // Motion trail back toward where the swipe began.
    final trail = Paint()
      ..color = ink.withValues(alpha: 0.08 * fade)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(x, size.height * 0.82), Offset(x, y + 26), trail);
    // Soft shadow under the hand.
    final shadow = Paint()
      ..color = Colors.black.withValues(alpha: 0.35 * fade)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 24);
    canvas.drawOval(
        Rect.fromCenter(center: Offset(x, y + 14), width: 96, height: 130),
        shadow);
    // Finger capsule + fingertip.
    final finger = Paint()
      ..color = ink.withValues(alpha: 0.20 * fade)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset(x, y + 72), width: 44, height: 150),
            const Radius.circular(22)),
        finger);
    canvas.drawCircle(
        Offset(x, y),
        26,
        Paint()
          ..color = ink.withValues(alpha: 0.30 * fade)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    canvas.drawCircle(
        Offset(x, y),
        26,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = green.withValues(alpha: 0.5 * fade));
  }

  @override
  bool shouldRepaint(_FingerPainter old) => old.p != p;
}
