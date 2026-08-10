import 'package:flutter_test/flutter_test.dart';
import 'package:finswipe/models.dart';

void main() {
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
