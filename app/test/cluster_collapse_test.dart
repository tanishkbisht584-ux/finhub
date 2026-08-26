// One card per event: the pipeline's cluster collapse is best-effort, so
// approved siblings can ship. collapseClusters keeps the first occurrence
// (pages are newest-first) and outlet credits already carry the rest.
import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart' show collapseClusters;
import 'package:flutter_test/flutter_test.dart';

Story _s(int id, {String? cluster}) => Story.fromJson({
      'id': id,
      'headline': 'Headline $id',
      'hook': 'Hook $id',
      'summary': 'S.',
      'sectors': const [],
      if (cluster != null) 'cluster_id': cluster,
    });

List<int> _ids(List<Story> l) => [for (final s in l) s.id];

void main() {
  test('clusterId parses from json and defaults null', () {
    expect(_s(1, cluster: 'c1').clusterId, 'c1');
    expect(_s(2).clusterId, isNull);
  });

  test('first (newest) sibling wins, later ones drop', () {
    final l = [_s(1, cluster: 'a'), _s(2, cluster: 'b'), _s(3, cluster: 'a')];
    expect(_ids(collapseClusters(l)), [1, 2]);
  });

  test('null clusterId stories are all kept', () {
    final l = [_s(1), _s(2), _s(3)];
    expect(_ids(collapseClusters(l)), [1, 2, 3]);
  });

  test('have drops siblings of cards already in the feed', () {
    final l = [_s(4, cluster: 'a'), _s(5, cluster: 'c')];
    expect(_ids(collapseClusters(l, have: {'a'})), [5]);
  });

  test('empty input, empty output', () {
    expect(collapseClusters(const []), isEmpty);
  });
}
