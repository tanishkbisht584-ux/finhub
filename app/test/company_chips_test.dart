import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart' show StoryPager;
import 'package:finswipe/ticks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  chipTests();
  test('Story carries companies attached by the feed query', () {
    final s = Story.fromJson({
      'id': 1, 'headline': 'h', 'source_name': 'ET', 'source_url': 'u',
      'companies': [
        {'id': 7, 'name': 'Reliance Industries', 'nse_symbol': 'RELIANCE'}
      ],
    });
    expect(s.companies.single.nseSymbol, 'RELIANCE');
  });

  test('Story without companies key parses to empty list', () {
    final s = Story.fromJson(
        {'id': 1, 'headline': 'h', 'source_name': 'ET', 'source_url': 'u'});
    expect(s.companies, isEmpty);
  });
}

// Live % on the chip comes from the shared `ticks` map (no per-card state):
// present -> "$SYM ▲x.x%", absent -> the plain chip. Pumped through StoryPager
// like feed_tree_test so the real card tree is what renders.
void chipTests() {
  final story = Story.fromJson({
    'id': 1, 'headline': 'h', 'hook': 'k', 'source_name': 'ET', 'source_url': 'u',
    'sectors': const <String>[],
    'companies': [
      {'id': 7, 'name': 'Tata Consultancy', 'nse_symbol': 'TCS'}
    ],
  });
  Widget app() => ProviderScope(
      child: MaterialApp(home: Scaffold(body: StoryPager(story: story))));

  testWidgets('chip shows the live % once ticks has the symbol', (tester) async {
    ticks.value = {};
    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('\$TCS'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);
    ticks.value = {
      'TCS': Tick.fromJson({'symbol': 'TCS', 'price': 2302, 'change_pct': 1.23})
    };
    await tester.pump();
    expect(find.text('▲1.2%'), findsOneWidget);
    ticks.value = {};
  });
}
