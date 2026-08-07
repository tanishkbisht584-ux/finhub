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
