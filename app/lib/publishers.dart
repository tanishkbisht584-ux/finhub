/// Which newsroom is behind a feed name.
///
/// Several feeds belong to one newspaper — LiveMint has five section feeds and
/// is also reached through a Google News proxy called "Mint Companies". Listing
/// those as separate outlets on a card fakes the very corroboration the outlet
/// list exists to prove: one paper agreeing with itself is not two sources.
///
/// Grouping by the story's URL would be the obvious trick, but it fails on
/// exactly the cases that matter — Google-News-proxied outlets all resolve to
/// news.google.com, so Mint, Business Standard and Moneycontrol would collapse
/// into one imaginary publisher.
///
/// MIRRORS `PUBLISHER` in pipeline/run.py, which is the source of truth (the
/// alert gate counts newsrooms with it). `test_pipeline.py` reads this file and
/// fails if the two ever disagree, so adding a feed in one place without the
/// other cannot pass CI.
const publisherOf = <String, String>{
  'BusinessLine Companies': 'BusinessLine',
  'BusinessLine Economy': 'BusinessLine',
  'BusinessLine Markets': 'BusinessLine',
  'Hindu BusinessLine': 'BusinessLine',
  'The Hindu Business': 'BusinessLine',
  'ET Banking': 'Economic Times',
  'ET Commodities': 'Economic Times',
  'ET Economy': 'Economic Times',
  'ET IPO': 'Economic Times',
  'ET MF': 'Economic Times',
  'ET Markets': 'Economic Times',
  'ET Stocks News': 'Economic Times',
  'ET Top Stories': 'Economic Times',
  'Investing Commodities': 'Investing.com',
  'Investing Economy': 'Investing.com',
  'Investing.com': 'Investing.com',
  'LiveMint Companies': 'LiveMint',
  'LiveMint Economy': 'LiveMint',
  'LiveMint Industry': 'LiveMint',
  'LiveMint Markets': 'LiveMint',
  'LiveMint Money': 'LiveMint',
  'Mint Companies': 'LiveMint',
  'GNews Moneycontrol': 'Moneycontrol',
  'GNews.io Markets IN': 'GNews.io',
  'GNews.io Stocks IN': 'GNews.io',
  'NewsData Business IN': 'NewsData',
  'NewsData Markets IN': 'NewsData',
  'RBI Notifications': 'RBI',
  'RBI Press': 'RBI',
  'RBI Speeches': 'RBI',
};

/// The newsroom behind [feedName]. Anything unlisted is its own publisher —
/// a new source is a new outlet until someone says otherwise.
String publisher(String feedName) => publisherOf[feedName] ?? feedName;

/// Outlet favicon via Google's s2 service, keyed on the article's host. Null
/// when there is no usable host — Google-News-proxied links all live on
/// news.google.com and would show Google's icon for every outlet, so those
/// (and anything unparseable) fall back to the letter monogram.
String? faviconUrl(String articleUrl) {
  final host = Uri.tryParse(articleUrl)?.host ?? '';
  if (host.isEmpty || host.endsWith('news.google.com') || host.endsWith('google.com')) {
    return null;
  }
  return 'https://www.google.com/s2/favicons?domain=$host&sz=64';
}
