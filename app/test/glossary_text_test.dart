import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:finswipe/glossary.dart';

void main() {
  testWidgets('terms get a dotted underline; tap opens the define sheet',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: GlossaryText('RBI held the repo rate steady.',
                style: TextStyle(fontSize: 15)))));

    final rich = tester.widget<Text>(find.byType(Text).first);
    final spans = (rich.textSpan! as TextSpan).children!;
    final term = spans.whereType<TextSpan>().firstWhere(
        (s) => s.text == 'repo rate',
        orElse: () => throw StateError('term span missing'));
    expect(term.style!.decoration, TextDecoration.underline);
    expect(term.style!.decorationStyle, TextDecorationStyle.dotted);
    expect(term.recognizer, isNotNull);

    // Fire the term's recognizer -> sheet with the term header. Supabase is
    // uninitialized here, so the lookup fails and the honest fallback
    // renders — offline behavior tested for free.
    (term.recognizer! as dynamic).onTap();
    await tester.pumpAndSettle();
    expect(find.text('REPO RATE'), findsOneWidget);
    expect(find.textContaining('No definition right now'), findsOneWidget);
  });

  testWidgets('plain text renders no underline spans', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: GlossaryText('Nothing jargony here.'))));
    final rich = tester.widget<Text>(find.byType(Text).first);
    final spans = (rich.textSpan! as TextSpan).children!;
    expect(
        spans
            .whereType<TextSpan>()
            .where((s) => s.style?.decoration == TextDecoration.underline),
        isEmpty);
  });
}
