import 'package:finswipe/models.dart';
import 'package:finswipe/screens/ask.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _full = {
  'whats_happening': 'NIFTY fell 2%.',
  'why': 'Global selloff.',
  'who_is_affected': 'IT exporters.',
  'what_to_watch': 'US CPI tonight.',
  'confidence': 'medium',
  'sources': [
    {'title': 'Markets slide', 'url': 'https://e.co/1', 'source_name': 'ET'}
  ],
  'followups': ['Why are FIIs selling?'],
  'tier': 1,
  'refused': false,
};

const _refusal = {
  'whats_happening': "Our sources don't clearly explain this yet.",
  'why': '',
  'who_is_affected': '',
  'what_to_watch': '',
  'confidence': 'low',
  'sources': [],
  'followups': [],
  'tier': 2,
  'refused': true,
};

void main() {
  test('QaAnswer parses the edge function contract', () {
    final a = QaAnswer.fromJson(Map<String, dynamic>.from(_full));
    expect(a.whatsHappening, 'NIFTY fell 2%.');
    expect(a.sources.single.sourceName, 'ET');
    expect(a.followups, ['Why are FIIs selling?']);
    expect(a.refused, isFalse);
  });

  test('QaAnswer tolerates a refusal payload', () {
    final a = QaAnswer.fromJson(Map<String, dynamic>.from(_refusal));
    expect(a.refused, isTrue);
    expect(a.sources, isEmpty);
  });

  test('QaAnswer survives a truncated payload', () {
    // A provider can return valid JSON missing fields; the app must render
    // something rather than throw on a null.
    final a = QaAnswer.fromJson({'whats_happening': 'Partial.'});
    expect(a.whatsHappening, 'Partial.');
    expect(a.why, isEmpty);
    expect(a.confidence, 'low');
    expect(a.sources, isEmpty);
    expect(a.refused, isFalse);
  });

  testWidgets('AnswerCard renders sections, sources, follow-ups', (tester) async {
    final answer = QaAnswer.fromJson(Map<String, dynamic>.from(_full));
    String? tapped;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: AnswerCard(
                    answer: answer, onFollowup: (q) => tapped = q)))));
    expect(find.text('NIFTY fell 2%.'), findsOneWidget);
    expect(find.text('Markets slide'), findsOneWidget);
    expect(find.text('confidence: medium'), findsOneWidget);
    await tester.tap(find.text('Why are FIIs selling?'));
    expect(tapped, 'Why are FIIs selling?');
  });

  testWidgets('AnswerCard refusal shows only the refusal line', (tester) async {
    final answer = QaAnswer.fromJson(Map<String, dynamic>.from(_refusal));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: AnswerCard(answer: answer, onFollowup: (_) {}))));
    expect(
        find.text("Our sources don't clearly explain this yet."), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });
}
