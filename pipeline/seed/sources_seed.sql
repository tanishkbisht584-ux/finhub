insert into sources (name, type, feed_url, authority) values
('ET Markets',        'rss', 'https://economictimes.indiatimes.com/markets/rssfeeds/1977021501.cms', 8),
('ET Top Stories',    'rss', 'https://economictimes.indiatimes.com/rssfeedstopstories.cms', 8),
('LiveMint Markets',  'rss', 'https://www.livemint.com/rss/markets', 8),
('SEBI',              'rss', 'https://www.sebi.gov.in/sebirss.xml', 10),
('RBI Press',         'rss', 'https://www.rbi.org.in/pressreleases_rss.xml', 10),
('Yahoo Finance',     'rss', 'https://finance.yahoo.com/news/rssindex', 6),
('MarketWatch',       'rss', 'https://feeds.content.dowjones.io/public/rss/mw_topstories', 7),
('CNBC World',        'rss', 'https://search.cnbc.com/rs/search/combinedcms/view.xml?partnerId=wrss01&id=100003114', 7),
('BBC Business',      'rss', 'https://feeds.bbci.co.uk/news/business/rss.xml', 8),
('Investing.com',     'rss', 'https://www.investing.com/rss/news.rss', 6),
('ET Economy',        'rss', 'https://economictimes.indiatimes.com/news/economy/rssfeeds/1373380680.cms', 8),
('ET IPO',            'rss', 'https://economictimes.indiatimes.com/markets/ipos/fpos/rssfeeds/14655708.cms', 8),
('TOI Business',      'rss', 'https://timesofindia.indiatimes.com/rssfeeds/1898055.cms', 7),
('Business Today',    'rss', 'https://www.businesstoday.in/rssfeeds/?id=home', 7),
('Inc42',             'rss', 'https://inc42.com/feed/', 6),
('Zerodha Z-Connect', 'rss', 'https://zerodha.com/z-connect/feed', 7),
('WSJ Markets',       'rss', 'https://feeds.content.dowjones.io/public/rss/RSSMarketsMain', 8),
('Guardian Business', 'rss', 'https://www.theguardian.com/uk/business/rss', 7),
('OilPrice',          'rss', 'https://oilprice.com/rss/main', 6),
('GNews Moneycontrol','google_news_query', 'site:moneycontrol.com', 8),
('GNews Breaking-IN', 'google_news_query', 'nifty OR sensex OR RBI OR SEBI when:1h', 5),
('GNews IPO',         'google_news_query', 'ipo india when:6h', 5),
('GNews Brokerages',  'google_news_query', '"Nuvama" OR "Motilal Oswal" OR "Jefferies India" when:6h', 5),
('GNews Geopolitics', 'google_news_query', 'geopolitics oil sanctions tariff india market when:6h', 5);

-- Added 2026-08-08: outlets whose native RSS is dead (spec §4) reached via
-- Google News site: queries. All verified fresh <7h at seed time.
insert into sources (name, type, feed_url, authority) values
('Business Standard',  'google_news_query', 'site:business-standard.com', 8),
('Financial Express',  'google_news_query', 'site:financialexpress.com', 7),
('Hindu BusinessLine', 'google_news_query', 'site:thehindubusinessline.com', 8),
('NDTV Profit',        'google_news_query', 'site:ndtvprofit.com', 7),
('Zee Business',       'google_news_query', 'site:zeebiz.com', 6),
('CNBC-TV18',          'google_news_query', 'site:cnbctv18.com', 7),
('Mint Companies',     'google_news_query', 'site:livemint.com companies', 8),
('Reuters India',      'google_news_query', 'site:reuters.com india markets', 9);

-- Added 2026-08-09: 26 feeds, each probed live before inclusion (>=3 items
-- inside run.py's 48h freshness window at seed time). Chosen to fill the two
-- thinnest categories (Commodities, Economy) and to reach outlets directly that
-- were only available through the Google News proxy. Every name here is mapped
-- in run.py's PUBLISHER dict — a newsroom's section feeds must not be mistaken
-- for independent corroboration by the alert gate.
insert into sources (name, type, feed_url, authority) values
-- regulators / government primary
('RBI Notifications',   'rss', 'https://www.rbi.org.in/notifications_rss.xml', 10),
('RBI Speeches',        'rss', 'https://www.rbi.org.in/Speeches_rss.xml', 9),
('PIB Finance Ministry','rss', 'https://www.pib.gov.in/RssMain.aspx?ModId=6&Lang=1&Regid=3', 9),
-- BusinessLine direct (was Google-News-only; native RSS is alive again)
('BusinessLine Markets',  'rss', 'https://www.thehindubusinessline.com/markets/feeder/default.rss', 8),
('BusinessLine Economy',  'rss', 'https://www.thehindubusinessline.com/economy/feeder/default.rss', 8),
('BusinessLine Companies','rss', 'https://www.thehindubusinessline.com/companies/feeder/default.rss', 8),
('The Hindu Business',    'rss', 'https://www.thehindu.com/business/feeder/default.rss', 7),
-- Business Standard direct RSS is deliberately NOT here. The feeds answer fine
-- from an Indian residential IP but never once fetched from the GitHub Actions
-- runner — they block datacenter IPs, which is the real reason BS was on the
-- Google News proxy to begin with. Don't "restore" them: probing from a laptop
-- will keep saying they work.
-- ET sections; ET Commodities alone roughly doubles the thinnest category
('ET Commodities', 'rss', 'https://economictimes.indiatimes.com/markets/commodities/rssfeeds/1977021501.cms', 8),
('ET Stocks News', 'rss', 'https://economictimes.indiatimes.com/markets/stocks/news/rssfeeds/2146842.cms', 8),
('ET Banking',     'rss', 'https://economictimes.indiatimes.com/industry/banking/finance/rssfeeds/13358259.cms', 8),
('ET MF',          'rss', 'https://economictimes.indiatimes.com/mf/rssfeeds/359241701.cms', 7),
-- LiveMint sections
('LiveMint Money',     'rss', 'https://www.livemint.com/rss/money', 8),
('LiveMint Companies', 'rss', 'https://www.livemint.com/rss/companies', 8),
('LiveMint Industry',  'rss', 'https://www.livemint.com/rss/industry', 7),
('LiveMint Economy',   'rss', 'https://www.livemint.com/rss/economy', 8),
-- commodities + macro depth
('Investing Commodities', 'rss', 'https://www.investing.com/rss/news_11.rss', 6),
('Investing Economy',     'rss', 'https://www.investing.com/rss/news_14.rss', 6),
('Mining.com',            'rss', 'https://www.mining.com/feed/', 6),
-- global / geopolitics, weighted to Asia where India relevance is highest
('Nikkei Asia',        'rss', 'https://asia.nikkei.com/rss/feed/nar', 8),
('Al Jazeera Economy', 'rss', 'https://www.aljazeera.com/xml/rss/all.xml', 7),
('FT Companies',       'rss', 'https://www.ft.com/companies?format=rss', 8),
('SCMP Business',      'rss', 'https://www.scmp.com/rss/92/feed', 7),
-- startups
('YourStory', 'rss', 'https://yourstory.com/feed', 6);

-- 2026-08-11..2026-08-23: five type='youtube' broadcaster channels lived here
-- (M8 video matching). The video feature was retired on 2026-08-23 (pictures
-- only); the pipeline now filters type=neq.youtube everywhere and the rows
-- were set is_active=false in prod. Seed block removed so a fresh DB never
-- gets them.

-- Added 2026-08-12 (M9): direct feeds for outlets previously reached only via
-- Google News site: proxies. Google's rss/articles links are JS-locked (no
-- redirect, opaque tokens), so proxied cards can never carry the outlet's
-- image or a direct link; these feeds fix both. All three verified live
-- (fresh entries; CNBC/NDTV carry media_content images 10/10). Their proxies
-- stay active as safety net — clustering + the editor merge fold the dupes.
-- NOT replaceable (verified 2026-08-12): Moneycontrol RSS frozen since
-- Apr 2024, Financial Express 410 Gone, Zee Business WAF 403, Reuters retired.
insert into sources (name, type, feed_url, authority) values
  ('Business Standard Markets', 'rss', 'https://www.business-standard.com/rss/markets-106.rss', 6),
  ('CNBC-TV18 Markets',         'rss', 'https://www.cnbctv18.com/commonfeeds/v1/cne/rss/market.xml', 7),
  ('NDTV Profit Latest',        'rss', 'https://feeds.feedburner.com/ndtvprofit-latest', 6)
on conflict do nothing;

-- Added 2026-08-22 (markets upgrade, phase 2): keyed JSON news APIs. Free
-- tiers are metered per day, so run.py polls these on POLL_MIN intervals
-- rather than every loop. Real article URLs + images (unlike Google News
-- proxies). Needs GNEWS_API_KEY / NEWSDATA_API_KEY / MARKETAUX_API_KEY in
-- pipeline/.env and the repo secrets; an unset key just logs FEED FAIL and
-- the row is retired/revived by self-heal like any dead feed.
insert into sources (name, type, feed_url, authority) values
  ('GNews.io Markets IN',  'gnews_api', 'nifty OR sensex OR rbi OR sebi', 6),
  ('GNews.io Stocks IN',   'gnews_api', 'stock market india', 5),
  ('NewsData Business IN', 'newsdata',  'business', 5),
  ('NewsData Markets IN',  'newsdata',  'stock market', 5),
  ('MarketAux India',      'marketaux', '', 6)
on conflict do nothing;

-- 2026-09-04: Global layer (worldmonitor follow-up). World markets +
-- geopolitics coverage; every RSS URL probed live same day (WSJ dropped -
-- its public feed froze Jan 2025). Reuters/Bloomberg ride google_news_query
-- (their own feeds are dead/paywalled). Authority 6: the round-robin in
-- prioritized() gives them a seat without starving India sources.
insert into sources (name, type, feed_url, authority) values
  ('BBC Business',        'rss', 'https://feeds.bbci.co.uk/news/business/rss.xml', 6),
  ('BBC World',           'rss', 'https://feeds.bbci.co.uk/news/world/rss.xml', 6),
  ('Al Jazeera',          'rss', 'https://www.aljazeera.com/xml/rss/all.xml', 6),
  ('Guardian World',      'rss', 'https://www.theguardian.com/world/rss', 6),
  ('Guardian Business',   'rss', 'https://www.theguardian.com/uk/business/rss', 6),
  ('CNBC World',          'rss', 'https://www.cnbc.com/id/100727362/device/rss/rss.html', 6),
  ('MarketWatch Top',     'rss', 'https://feeds.content.dowjones.io/public/rss/mw_topstories', 6),
  ('FT World',            'rss', 'https://www.ft.com/world?format=rss', 6),
  ('GNews Reuters',       'google_news_query', 'site:reuters.com', 6),
  ('GNews Bloomberg',     'google_news_query', 'site:bloomberg.com', 6)
on conflict do nothing;

-- 2026-09-04: beat feeds (worldmonitor residue). Derivatives, SEBI enforcement
-- and FPI/hedge-fund flow desks that no single outlet feed covers; each query
-- answered 44-100 items with <4 h freshness when probed. Zero fetch code.
insert into sources (name, type, feed_url, authority) values
  ('GNews Derivatives-IN',   'google_news_query', 'nifty options OR "open interest" OR "put call ratio" OR "F&O" when:2d', 6),
  ('GNews SEBI-Enforcement', 'google_news_query', 'SEBI order OR SEBI penalty OR SEBI bars OR SEBI settlement when:3d', 6),
  ('GNews FPI-Flows',        'google_news_query', '"FPI" OR "FII outflow" OR "FII inflow" OR "hedge fund" India when:3d', 6)
on conflict do nothing;
