// Deep read UI (spec 2026-08-16): page 0 is the card; swiping left reveals
// the writing state, then newspaper pages. Vertical feed must keep working
// (horizontal child, vertical parent — orthogonal axes never fight).
import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart' show DeepReadPages;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders headings, bodies and page dots', (tester) async {
    final d = DeepRead.fromJson({
      'pages': [
        {'heading': 'What happened', 'body': 'A thing occurred.'},
        {'heading': 'Why it matters', 'body': 'It matters a lot.'},
      ]
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: DeepReadPages(read: d, pageIndex: 0))));
    expect(find.text('What happened'), findsOneWidget);
    expect(find.text('A thing occurred.'), findsOneWidget);
  });

  testWidgets('refusal shows the honest fallback', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: DeepReadPages(read: DeepRead(const []), pageIndex: 0))));
    expect(find.textContaining('unavailable'), findsOneWidget);
    expect(find.textContaining('below'), findsNothing);
  });

  testWidgets('refusal fallback carries a tappable outlet link', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: DeepReadPages(
      read: DeepRead(const []),
      pageIndex: 0,
      sourceUrl: 'https://example.com/story',
      sourceName: 'Example Wire',
    ))));
    expect(find.text('Example Wire'), findsOneWidget);
    expect(find.text('Read original'), findsOneWidget);
    expect(find.byType(InkWell), findsOneWidget);
  });
}
