import 'dart:ui';

import 'package:flutter/material.dart';

/// Liquid glass (spec §8): category-tinted static aurora gradients, frosted
/// cards, severity/impact accents riding on top.

const categoryTints = <String, Color>{
  'Markets': Color(0xFF1B2A4A),
  'Economy': Color(0xFF1F3A2E),
  'IPO': Color(0xFF3A2A1F),
  'Global': Color(0xFF2A1F3A),
  'Commodities': Color(0xFF3A331F),
  'Corporate': Color(0xFF1F2F3A),
  'Policy': Color(0xFF33203A),
  'Geopolitics': Color(0xFF3A1F26),
};

const positive = Color(0xFF6EE7B7); // mint
const negative = Color(0xFFFCA5A5); // coral
const emberL1 = Color(0xFFF87171);

Color impactColor(String? direction) => switch (direction) {
      'positive' => positive,
      'negative' => negative,
      'mixed' => const Color(0xFFFCD34D),
      _ => const Color(0xFF9CA3AF),
    };

/// Static aurora background — pre-computed gradient, never live blur.
BoxDecoration aurora(String? category) {
  final tint = categoryTints[category] ?? categoryTints['Markets']!;
  return BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [tint, const Color(0xFF0B0F1A), Color.lerp(tint, Colors.black, 0.5)!],
    ),
  );
}

/// One of the at-most-two live blur surfaces per screen.
class GlassCard extends StatelessWidget {
  const GlassCard({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            color: Colors.white.withValues(alpha: 0.08),
            border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
          ),
          child: child,
        ),
      ),
    );
  }
}

final appTheme = ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: const Color(0xFF0B0F1A),
  colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF6366F1), brightness: Brightness.dark),
  useMaterial3: true,
);
