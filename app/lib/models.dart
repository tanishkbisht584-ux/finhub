/// One outlet that carried this story. The pipeline keeps every outlet's row
/// in the cluster, so a card can credit all of them instead of the pipeline
/// silently picking one and discarding the rest.
class Outlet {
  final String name;
  final String url;
  final DateTime? publishedAt;

  Outlet.fromJson(Map<String, dynamic> j)
      : name = j['source_name'] ?? '',
        url = j['source_url'] ?? '',
        publishedAt = DateTime.tryParse(j['published_at'] ?? '');
}

class Story {
  final int id;
  final String? hook;
  final String headline;
  final String? summary;
  final String? impactDirection;
  final int? impactStrength;
  final String? impactHorizon;
  final int? impactScore;
  final int? severityLevel;
  final String? confidence;
  final String sourceName;
  final String sourceUrl;
  final String? category;
  final List<String> sectors;

  /// Every outlet that ran this story, earliest first — so the card can credit
  /// whoever broke it rather than whichever copy the pipeline happened to
  /// process. Empty when no other outlet carried it.
  final List<Outlet> outlets;

  Story.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        hook = j['hook'],
        headline = j['headline'],
        summary = j['summary'],
        impactDirection = j['impact_direction'],
        impactStrength = j['impact_strength'],
        impactHorizon = j['impact_horizon'],
        impactScore = j['impact_score'],
        severityLevel = j['severity_level'],
        confidence = j['confidence'],
        sourceName = j['source_name'],
        sourceUrl = j['source_url'],
        category = j['category'],
        sectors = List<String>.from(j['sectors'] ?? const []),
        // Attached by the feed query and carried into the offline cache, so a
        // cached card keeps its outlet list too.
        outlets = [
          for (final o in (j['outlets'] as List? ?? const []))
            Outlet.fromJson(Map<String, dynamic>.from(o))
        ];
}

class QaSource {
  final String title;
  final String url;
  final String sourceName;
  QaSource.fromJson(Map<String, dynamic> j)
      : title = j['title'] ?? '',
        url = j['url'] ?? '',
        sourceName = j['source_name'] ?? '';
}

/// Q&A answer contract from the `qa` Edge Function. Every field defaults, so a
/// truncated provider response degrades to a partial card instead of throwing.
class QaAnswer {
  final String whatsHappening;
  final String why;
  final String whoIsAffected;
  final String whatToWatch;
  final String confidence;
  final List<QaSource> sources;
  final List<String> followups;
  final bool refused;

  QaAnswer.fromJson(Map<String, dynamic> j)
      : whatsHappening = j['whats_happening'] ?? '',
        why = j['why'] ?? '',
        whoIsAffected = j['who_is_affected'] ?? '',
        whatToWatch = j['what_to_watch'] ?? '',
        confidence = j['confidence'] ?? 'low',
        sources = ((j['sources'] ?? const []) as List)
            .map((s) => QaSource.fromJson(Map<String, dynamic>.from(s)))
            .toList(),
        followups = List<String>.from(j['followups'] ?? const []),
        refused = j['refused'] == true;
}
