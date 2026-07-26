create table sources (
  id            bigint generated always as identity primary key,
  name          text not null,
  type          text not null check (type in ('rss','google_news_query','nse','bse','sebi','rbi')),
  feed_url      text not null,          -- for google_news_query this is the query string
  authority     int not null default 5 check (authority between 1 and 10),
  is_active     boolean not null default true,
  last_fetched_at timestamptz
);

create table companies (
  id          bigint generated always as identity primary key,
  name        text not null,
  nse_symbol  text unique,
  bse_code    text,
  sector      text,
  logo_url    text,
  is_nifty50  boolean not null default false,
  aliases     text[] default '{}'
);

create table stories (
  id               bigint generated always as identity primary key,
  url              text not null,
  url_hash         text not null unique,
  cluster_id       uuid not null,
  hook             text,               -- billboard line, <=8 words, factual
  headline         text not null,
  summary          text,
  impact_direction text check (impact_direction in ('positive','negative','mixed','neutral')),
  impact_strength  int  check (impact_strength between 1 and 3),
  impact_horizon   text check (impact_horizon in ('short_term','long_term','both')),
  impact_score     int  check (impact_score between 1 and 10),
  severity_level   int generated always as (
                     case when impact_score >= 9 then 1
                          when impact_score >= 7 then 2
                          when impact_score >= 4 then 3
                          when impact_score is not null then 4
                     end) stored,   -- L1 highest priority ... L4 lowest
  confidence       text check (confidence in ('high','medium','low')),
  source_name      text not null,
  source_url       text not null,
  image_url        text,
  published_at     timestamptz,
  category         text check (category in ('Markets','Economy','IPO','Global','Commodities','Corporate','Policy','Geopolitics')),
  sectors          text[] default '{}',
  status           text not null default 'pending'
                   check (status in ('pending','approved','rejected','flagged','duplicate')),
  is_featured      boolean not null default false,
  alerted_at       timestamptz,
  raw_ai_error     text,                -- populated when status='flagged'
  created_at       timestamptz not null default now()
);
create index stories_status_idx     on stories (status, published_at desc);
create index stories_cluster_idx    on stories (cluster_id);
create index stories_created_idx    on stories (created_at desc);
create index stories_category_idx   on stories (category, status, published_at desc);

create table story_companies (
  story_id   bigint references stories(id) on delete cascade,
  company_id bigint references companies(id) on delete cascade,
  primary key (story_id, company_id)
);
