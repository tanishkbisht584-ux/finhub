// Q&A: the app's only runtime AI (spec §5). Groq-first per 2026-08-08 decision —
// chat never competes with the pipeline's Gemini pool. Tier 1: our stories via
// FTS. Tier 2: Tavily over whitelisted domains. The model must never answer
// from its own knowledge.
//
// 2026-09-13 (1000-user readiness): auth/config/cap reads run in parallel, the
// config is memoised, every provider attempt is bounded and rotated, a global
// daily budget sits above the per-user cap (over it, cached answers still
// serve), Tavily is metered against its monthly free tier, and "ask about this"
// context (story_id / symbol) skips the planner call altogether.
import { createClient } from "npm:@supabase/supabase-js@2";
import { cachedAnswer, peekAnswer } from "../_shared/cache.ts";

const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SERVICE_KEY")!,
);

const WHITELIST = [
  "reuters.com", "economictimes.indiatimes.com", "livemint.com",
  "moneycontrol.com", "business-standard.com", "nseindia.com",
  "bseindia.com", "rbi.org.in", "sebi.gov.in",
];

const REFUSAL = "Our sources don't clearly explain this yet.";

type Source = { title: string; body: string; source_name: string; url: string };

// Two lane orders over the same providers (measured against our keys 18 Aug):
//  "smart" — user-facing answers: gemini-3.7-flash first (newest free flash, a
//            quota bucket the pipeline never draws from; gemini-pro is 429 on
//            free keys), then Groq's best, then flash-lite as the last resort.
//  "fast"  — the planner: routing needs speed, not brains, so Groq (sub-second)
//            leads. llama-3.3-70b was retired from Groq's catalog (gone 18 Aug);
//            qwen3.6-27b is the strongest live replacement.
// Same comma-separated multi-key pattern as the pipeline throughout.
type Lane = { provider: "groq" | "gemini"; key: string; model: string; lane: string };
const FN = "qa";

// ---------- admin cockpit: remote config + call log ----------
// app_config.edge is the admin's kill switch / caps / lane order for this
// function. {} (table missing, row missing, any error) = the defaults below.
// Two flags gate Ask: app_config.app.flags.qa_enabled is the app's SOFT
// pre-check (saves the round trip, shows maintenance copy); this row's
// qa_enabled is the HARD switch (503 "paused by admin"). The admin flips both.
type EdgeCfg = {
  qa_enabled?: boolean; deepread_enabled?: boolean; daily_cap?: number;
  global_cap?: number; tavily_cap?: number;
  lanes?: Record<string, [string, string][]>;
};
let edgeCfg: EdgeCfg = {};
let cfgAt = 0;
const CFG_MS = 60e3; // ponytail: 60 s admin-flag latency per warm isolate; one select a minute, not one per request
async function loadCfg(): Promise<EdgeCfg> {
  if (Date.now() - cfgAt < CFG_MS) return edgeCfg;
  try {
    const { data } = await sb.from("app_config").select("value").eq("key", "edge").maybeSingle();
    edgeCfg = (data?.value as EdgeCfg) ?? {};
  } catch {
    edgeCfg = {};
  }
  cfgAt = Date.now();
  return edgeCfg;
}
// edge_log: one row per lane attempt, so the admin can see which provider is
// failing and why instead of a silent "all lanes down". Never blocks, never throws.
async function logCall(lane: string, ok: boolean, status: number | null, error: string | null, ms: number) {
  try {
    await sb.from("edge_log").insert({ fn: FN, lane, ok, status, error: error?.slice(0, 300) ?? null, ms });
  } catch { /* logging must never break the answer */ }
}
function laneOrder<K extends string>(kind: K, defaults: [("groq" | "gemini"), string][]) {
  const o = edgeCfg.lanes?.[kind];
  const valid = Array.isArray(o) && o.length > 0 && o.every((p) =>
    Array.isArray(p) && (p[0] === "groq" || p[0] === "gemini") && typeof p[1] === "string" && p[1]);
  return valid ? (o as [("groq" | "gemini"), string][]) : defaults;
}

function keysOf(...envs: string[]): string[] {
  for (const e of envs) {
    const v = (Deno.env.get(e) ?? "").split(",").map((k) => k.trim()).filter(Boolean);
    if (v.length) return v;
  }
  return [];
}

const DEFAULT_ORDER: Record<"smart" | "fast", [("groq" | "gemini"), string][]> = {
  smart: [["gemini", "gemini-3.7-flash"], ["groq", "openai/gpt-oss-120b"],
          ["groq", "qwen/qwen3.6-27b"], ["gemini", "gemini-3.5-flash-lite"]],
  fast: [["groq", "openai/gpt-oss-120b"], ["groq", "qwen/qwen3.6-27b"],
         ["gemini", "gemini-3.5-flash-lite"]],
};

// Lanes used to be walked strictly in order: key #0 of the first model absorbed
// every request until it 429'd, then each request tried all 16 (key × model)
// lanes with no timeout. Now keys rotate per call, a lane that failed sits out
// BENCH_MS, each attempt is bounded, and a request gives up after MAX_ATTEMPTS.
// ponytail: rr/bench live per warm isolate — a cold start forgets; edge_log
// is the durable record. chat() is duplicated in deepread; extract to
// _shared/llm.ts when a third function needs it.
let rr = 0;
const bench = new Map<string, number>(); // lane -> benched until (ms)
const LANE_MS = 12e3, BENCH_MS = 60e3, MAX_ATTEMPTS = 6;

// Lane order is overridable per kind from the admin (app_config.edge.lanes.smart / .fast).
function lanes(kind: "smart" | "fast"): Lane[] {
  const groq = keysOf("GROQ_API_KEYS", "GROQ_API_KEY");
  const gemini = keysOf("GEMINI_API_KEYS", "GEMINI_API_KEY");
  return laneOrder(kind, DEFAULT_ORDER[kind]).flatMap(([provider, model]) => {
    const keys = provider === "groq" ? groq : gemini;
    return keys.map((_, j) => {
      const i = (j + rr) % keys.length;
      return { provider, key: keys[i], model, lane: `${provider}/${model}#${i}` };
    });
  });
}

async function chat(prompt: string, kind: "smart" | "fast" = "fast"): Promise<string | null> {
  rr++;
  let attempts = 0;
  for (const { provider, key, model, lane } of lanes(kind)) {
    if ((bench.get(lane) ?? 0) > Date.now()) continue;
    if (++attempts > MAX_ATTEMPTS) break;
    const t0 = Date.now();
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), LANE_MS);
    try {
      const r = provider === "groq"
        ? await fetch("https://api.groq.com/openai/v1/chat/completions", {
          method: "POST",
          signal: ctrl.signal,
          headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
          body: JSON.stringify({
            model, temperature: 0.2,
            response_format: { type: "json_object" },
            messages: [{ role: "user", content: prompt }],
          }),
        })
        : await fetch(
          `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`,
          {
            method: "POST",
            signal: ctrl.signal,
            headers: { "x-goog-api-key": key, "Content-Type": "application/json" },
            body: JSON.stringify({
              contents: [{ parts: [{ text: prompt }] }],
              generationConfig: { response_mime_type: "application/json", temperature: 0.2 },
            }),
          },
        );
      if (!r.ok) { // 429/503/retired model/anything -> bench it, next lane
        bench.set(lane, Date.now() + BENCH_MS);
        await logCall(lane, false, r.status, await r.text(), Date.now() - t0);
        continue;
      }
      const j = await r.json();
      const text = provider === "groq"
        ? j.choices[0].message.content
        : j.candidates[0].content.parts[0].text;
      await logCall(lane, true, 200, null, Date.now() - t0);
      return text;
    } catch (e) {
      bench.set(lane, Date.now() + BENCH_MS); // timeout, network, odd body: sit out
      await logCall(lane, false, null, String(e), Date.now() - t0);
      continue; // a provider outage must never surface as a 500
    } finally {
      clearTimeout(timer);
    }
  }
  await logCall("none", false, null, "all lanes failed", 0);
  return null;
}

function prompt(question: string, sources: Source[]): string {
  const listing = sources.map((s, i) => `[${i + 1}] ${s.title}\n${s.body}`).join("\n\n");
  return `You explain Indian market news to retail investors. Answer ONLY from the numbered sources below. Never use outside knowledge. If the sources do not clearly answer the question, set refused=true.
A source starting with "Live:" carries current market data — price, day move, and an Analysis line with ratios (P/E, P/B, ROE), holdings, RSI and trend. A source starting with "Screener:" carries the company's fundamentals and returns. A question asking for one of those current numbers IS fully answered by that source: state the number plainly, never refuse it.
HARD RULE: if the question asks for investment advice, a recommendation, or a prediction (should I buy/sell, will it rise, price targets, which stock to pick), set refused=true no matter what the sources say. Describing news about a company is not permission to advise on it. Reporting a current measured number (price, P/E, RSI, overbought/oversold state) is data, not advice.

Question: ${question}

Sources:
${listing}

Return JSON exactly:
{"whats_happening": "2-4 sentences", "why": "2-4 sentences", "who_is_affected": "2-4 sentences", "what_to_watch": "1-2 sentences", "confidence": "high|medium|low", "cited": [1], "followups": ["question", "question"], "refused": false}
cited = source numbers you actually used. followups = 2 short related questions answerable from these sources.`;
}

// ---------- planner: one cheap call that routes the question ----------
// Two failures shared one cause: a concept question ("what is a CAS?") can never
// match a news archive, and a news question phrased in other words ("what did the
// central bank decide?") missed the story that says "RBI". Classifying and
// expanding the query up front fixes both, and lets an advice question refuse
// before we spend a second call on it.
type Plan = { kind: "news" | "concept" | "refuse"; terms: string[] };

function plannerPrompt(question: string): string {
  return `Classify one question from an Indian markets app, and extract search terms.

The asker is an Indian retail investor typing on a phone: expect typos and
shorthand ("wht is cas"). Interpret charitably before classifying.

kind:
  "refuse"  - investment advice, a recommendation, a prediction or a price target;
              OR clearly not about finance, markets, banking, tax or economics;
              OR unknowable (a private person's opinion, the future).
              NOT a question about a CURRENT, measurable number or state - "is X
              overbought", "what is X's P/E", "where is the nifty" ask what IS,
              not what WILL BE; those are "news".
  "concept" - asks what something IS or HOW it works: a term, abbreviation,
              product, rule, process or institution. "what is X" is concept even
              when X is unfamiliar to you - never refuse a term just because it
              is ambiguous or misspelled. BUT when the question asks that term's
              value FOR a named company or index ("P/E of TCS", "TCS RSI"), it
              is "news" - the asker wants the number, not the definition.
  "news"    - asks what happened, why something moved, or for a current number:
              price, level, ratio (P/E, P/B), RSI, overbought/oversold, FII/DII
              flows - live market data answers these.

terms: 3-10 lowercase words to search a news archive with. INCLUDE synonyms and
  expansions the question did not use itself ("central bank" -> rbi, reserve;
  "borrowing cost" -> repo, rate, policy). Single words only, letters and digits
  only, no phrases. Empty list when kind is "refuse".

Question: ${question}

Return JSON exactly: {"kind": "news", "terms": ["rbi", "repo", "rate"]}`;
}

async function plan(question: string): Promise<Plan | null> {
  const raw = await chat(plannerPrompt(question));
  if (raw === null) return null; // every provider down -> caller degrades
  try {
    const p = JSON.parse(raw);
    return {
      // An unrecognised kind must not silently refuse a real question — the news
      // path is the safe default because it can only answer from sources.
      kind: ["news", "concept", "refuse"].includes(p.kind) ? p.kind : "news",
      // Sanitised as hard as tsQuery: these reach to_tsquery, which throws on
      // its own syntax characters.
      terms: (Array.isArray(p.terms) ? p.terms : [])
        .map((t: unknown) => String(t).toLowerCase().replace(/[^a-z0-9]/g, ""))
        .filter((t: string) => t.length > 1)
        .slice(0, 10),
    };
  } catch {
    return null;
  }
}

// The explainer lane. This one IS allowed to use the model's own knowledge —
// the deliberate exception to the sourced-answer contract, because no news story
// will ever contain "what is a Consolidated Account Statement". The hard rules
// below are what keeps that exception honest.
function conceptPrompt(question: string, sources: Source[]): string {
  const listing = sources.length
    ? `\n\nRecent stories from our feed. Mention them only if they are directly relevant:\n` +
      sources.map((s, i) => `[${i + 1}] ${s.title}\n${s.body}`).join("\n\n")
    : "";
  return `You explain finance to Indian retail investors who know nothing about the topic. Explain the question fully and plainly, in as much detail as it deserves. Short sentences, no jargon without unpacking it.

HARD RULES:
- Finance, markets, banking, tax and economics ONLY. Anything else, set refused=true.
- Never give advice, a recommendation, a prediction or a price target. A question like "what should I buy" or "which fund is best" sets refused=true even though it sounds like a concept question.
- Do NOT state specific rates, fees, limits or thresholds as current fact — they change and your knowledge is dated. Explain how the thing works, and say the current figure should be checked with the provider or regulator.
- The question may have typos or shorthand — answer what was clearly meant.
- Ambiguous term or abbreviation: explain the meaning an Indian retail investor most likely wants (CAS = Consolidated Account Statement, not other expansions), and note other common meanings in one sentence at the end. NEVER invent an expansion for an abbreviation you do not actually know — a wrong confident expansion is the worst possible answer. If you genuinely do not know the term, set refused=true.

Question: ${question}${listing}

Return JSON exactly:
{"sections": [{"heading": "short heading", "body": "2-5 sentences"}], "confidence": "high|medium|low", "followups": ["question", "question"], "refused": false}
3 to 6 sections, ordered so a beginner can follow. followups = 2 short related finance questions.`;
}

// Question words that carry no search signal. websearch mode ANDs every term,
// so "What did the RBI decide recently?" demanded decide AND recently in the
// story text and matched nothing — 7 of 10 answerable eval questions refused
// on a feed that demonstrably covered them.
const FILLER = new Set([
  "what", "which", "who", "whom", "whose", "why", "how", "when", "where",
  "is", "are", "was", "were", "be", "being", "been", "am", "do", "does",
  "did", "doing", "has", "have", "had", "will", "would", "can", "could",
  "should", "shall", "may", "might", "the", "a", "an", "of", "to", "in",
  "on", "for", "and", "or", "as", "at", "by", "with", "about", "against",
  "any", "some", "this", "that", "these", "those", "there", "here", "it",
  "its", "my", "me", "i", "we", "our", "you", "your", "they", "their",
  "recently", "today", "yesterday", "week", "now", "right", "latest",
  "currently", "going", "happening", "mean", "means", "decide", "decided",
  "announced", "move", "moved", "doing",
]);

/** Question -> `a | b | c` tsquery. Strictly [a-z0-9] so to_tsquery can never
 *  be handed syntax it throws on. */
function tsQuery(question: string): string {
  const words = question.toLowerCase().match(/[a-z0-9]+/g) ?? [];
  const terms = words.filter((w) => w.length > 1 && !FILLER.has(w));
  return (terms.length ? terms : words).join(" | ");
}

/** `terms` come from the planner and already carry synonyms; tsQuery is the
 *  fallback for when that call failed, so a provider outage costs answer
 *  quality and not the search itself. */
async function tier1(question: string, terms: string[] = []): Promise<Source[]> {
  const tsq = terms.length ? terms.join(" | ") : tsQuery(question);
  if (!tsq) return [];
  // Ranked retrieval lives in Postgres (search_stories, migration 005):
  // PostgREST cannot order by ts_rank, and without ranking the OR-match handed
  // the model five stories that merely shared a common word — it then refused,
  // correctly, and the whole feature looked broken.
  const { data } = await sb.rpc("search_stories", { tsq, max_rows: 5 });
  return (data ?? []).map((s: Record<string, string>) => ({
    title: s.headline,
    body: s.summary ?? "",
    source_name: s.source_name,
    url: s.source_url,
  }));
}

// Words the planner emits for almost any market question; matching them against
// `quotes.name` would drag in every row. Instrument words (nifty, tcs, gold,
// bitcoin, rupee, fed) are what we want.
const QUOTE_STOP = new Set([
  "market", "markets", "stock", "stocks", "india", "indian", "today", "price",
  "prices", "share", "shares", "news", "latest", "move", "moved", "why", "what",
  "how", "much", "now", "right", "current", "level", "value",
]);

const QUOTE_ALIAS: Record<string, string> = {
  sensex: "^BSESN", nifty: "^NSEI", banknifty: "^NSEBANK", rupee: "USDINR=X",
  dollar: "USDINR=X", usdinr: "USDINR=X", gold: "GOLD_INR_10G", silver: "SI=F",
  crude: "CL=F", oil: "CL=F", btc: "bitcoin", eth: "ethereum", sol: "solana",
  fed: "MACRO:FEDFUNDS", treasury: "MACRO:DGS10",
};

function quoteUrl(q: Record<string, unknown>): string {
  const sym = String(q.symbol);
  if (q.kind === "crypto") return `https://www.coingecko.com/en/coins/${sym}`;
  if (q.kind === "mf") return `https://api.mfapi.in/mf/${sym.slice(3)}`;
  if (q.kind === "macro") return `https://fred.stlouisfed.org/series/${sym.slice(6)}`;
  if (sym === "GOLD_INR_10G") return "https://finance.yahoo.com/quote/GC=F";
  return `https://finance.yahoo.com/quote/${encodeURIComponent(q.kind === "equity" ? sym + ".NS" : sym)}`;
}

/** Live numbers from the pipeline's `quotes` table (market.py) as sources the
 *  model can cite — "what is the Nifty at?" gets the real level, not a
 *  refusal or a two-day-old headline. One DB query, no AI call; the qa_cache
 *  TTL bounds staleness. Empty when nothing matches. */
async function liveQuotes(terms: string[]): Promise<Source[]> {
  const words = terms.filter((t) => t.length >= 3 && !QUOTE_STOP.has(t));
  if (!words.length) return [];
  const syms = new Set(words.map((w) => QUOTE_ALIAS[w]).filter(Boolean));
  const ors = [
    ...words.map((w) => `symbol.ilike.${w}`),
    ...words.map((w) => `name.ilike.*${w}*`),
    ...[...syms].map((s) => `symbol.eq.${s}`),
  ];
  try {
    const { data } = await sb.from("quotes")
      .select("symbol,kind,name,price,prev_close,change_pct,currency,as_of,meta")
      .or(ors.join(","))
      .limit(5);
    // Fundamentals/technicals (market.py writes meta.f / meta.t on equities):
    // ride the same source so "is TCS expensive?" can cite P/E, not vibes.
    const analysisOf = (meta: Record<string, unknown>): string => {
      const f = (meta.f ?? {}) as Record<string, unknown>;
      const t = (meta.t ?? {}) as Record<string, unknown>;
      const bits: string[] = [];
      if (f.pe != null) bits.push(`P/E ${f.pe}${f.fwd_pe != null ? ` (fwd ${f.fwd_pe})` : ""}`);
      if (f.pb != null) bits.push(`P/B ${f.pb}`);
      if (f.roe != null) bits.push(`ROE ${f.roe}%`);
      if (f.margin != null) bits.push(`net margin ${f.margin}%`);
      if (f.rev_growth != null) bits.push(`revenue growth ${f.rev_growth}% YoY`);
      if (f.promoter_pct != null) bits.push(`promoter holding ${f.promoter_pct}%`);
      if (f.rec != null && f.rec !== "none") bits.push(`analyst view ${String(f.rec).replace("_", " ")}${f.target != null ? ` (target ${f.target})` : ""}`);
      if (t.rsi14 != null) bits.push(`RSI-14 ${t.rsi14}${Number(t.rsi14) >= 70 ? " (overbought)" : Number(t.rsi14) <= 30 ? " (oversold)" : ""}`);
      if (t.trend != null) bits.push(`trend ${t.trend}${t.above200 === true ? ", above 200-DMA" : t.above200 === false ? ", below 200-DMA" : ""}`);
      if (t.pos52 != null) bits.push(`at ${Math.round(Number(t.pos52) * 100)}% of its 52-week range`);
      return bits.length ? ` Analysis: ${bits.join("; ")}.` : "";
    };
    return (data ?? []).map((q: Record<string, unknown>) => {
      const meta = (q.meta ?? {}) as Record<string, unknown>;
      const units = String(meta.units ?? q.currency ?? "");
      const price = Number(q.price).toLocaleString("en-IN", { maximumFractionDigits: 2 });
      const pct = q.change_pct == null ? "" :
        ` (${Number(q.change_pct) >= 0 ? "▲" : "▼"}${Math.abs(Number(q.change_pct)).toFixed(2)}% on the day)`;
      // Date only: Yahoo's daily bars are stamped at session open, so a
      // clock time would read as "09:15" for what is really that day's close.
      const asOf = q.as_of ? new Date(String(q.as_of)).toLocaleString("en-IN",
        { timeZone: "Asia/Kolkata", day: "numeric", month: "short", year: "numeric" }) + " (last session)" : "";
      const src = q.kind === "crypto" ? "CoinGecko" : q.kind === "mf" ? "mfapi.in (AMFI NAV)" :
        q.kind === "macro" ? "FRED" : "Yahoo Finance (delayed)";
      const label = meta.label ? ` — ${meta.label}` : "";
      const period = meta.period ? ` (period ${meta.period})` : "";
      return {
        title: `Live: ${q.name} ${price} ${units}${pct}`,
        body: `${q.name}: ${price} ${units}${pct}${label}${period}` +
          (q.prev_close != null ? `; previous ${Number(q.prev_close).toLocaleString("en-IN", { maximumFractionDigits: 2 })}` : "") +
          (asOf ? `. As of ${asOf} IST.` : ".") + ` Source: ${src}.` +
          analysisOf((q.meta ?? {}) as Record<string, unknown>),
        source_name: src,
        url: quoteUrl(q),
      };
    });
  } catch {
    return [];
  }
}

/** The symbol's screener_metrics row (stockanalysis + NSE filings, ~3.2k NSE
 *  symbols) as one citable source — the fundamentals grounding the stock page
 *  already shows, so "is TCS expensive?" from that page can cite sector P/E. */
async function screenerSource(symbol: string): Promise<Source | null> {
  try {
    const { data } = await sb.from("screener_metrics")
      .select("name,sector,price,mcap_cr,pe,sector_pe,pb,roe,roce,de,opm,div_yield,promoter_pct," +
        "sales_cagr_3y,profit_cagr_3y,ret_1m,ret_1y,ath_pct,f_score")
      .eq("symbol", symbol).maybeSingle();
    const m = data as Record<string, unknown> | null;
    if (!m) return null;
    const n = (v: unknown) => Number(v).toLocaleString("en-IN", { maximumFractionDigits: 2 });
    const bits: string[] = [];
    if (m.price != null) bits.push(`price ₹${n(m.price)}`);
    if (m.mcap_cr != null) bits.push(`market cap ₹${n(m.mcap_cr)} cr`);
    if (m.pe != null) bits.push(`P/E ${n(m.pe)}${m.sector_pe != null ? ` (sector P/E ${n(m.sector_pe)})` : ""}`);
    if (m.pb != null) bits.push(`P/B ${n(m.pb)}`);
    if (m.roe != null) bits.push(`ROE ${n(m.roe)}%`);
    if (m.roce != null) bits.push(`ROCE ${n(m.roce)}%`);
    if (m.de != null) bits.push(`debt/equity ${n(m.de)}`);
    if (m.opm != null) bits.push(`operating margin ${n(m.opm)}%`);
    if (m.div_yield != null) bits.push(`dividend yield ${n(m.div_yield)}%`);
    if (m.promoter_pct != null) bits.push(`promoter holding ${n(m.promoter_pct)}%`);
    if (m.sales_cagr_3y != null) bits.push(`3-year sales CAGR ${n(m.sales_cagr_3y)}%`);
    if (m.profit_cagr_3y != null) bits.push(`3-year profit CAGR ${n(m.profit_cagr_3y)}%`);
    if (m.ret_1m != null) bits.push(`1-month return ${n(m.ret_1m)}%`);
    if (m.ret_1y != null) bits.push(`1-year return ${n(m.ret_1y)}%`);
    if (m.ath_pct != null) bits.push(`${n(m.ath_pct)}% from its all-time high`);
    if (m.f_score != null) bits.push(`Piotroski F-score ${n(m.f_score)}`);
    if (!bits.length) return null;
    return {
      title: `Screener: ${m.name ?? symbol} (${symbol})`,
      body: `${m.name ?? symbol}${m.sector ? `, ${m.sector} sector` : ""}: ${bits.join("; ")}. ` +
        "Source: FinFlick screener (Stock Analysis, NSE filings).",
      source_name: "FinFlick screener",
      url: `https://finance.yahoo.com/quote/${encodeURIComponent(symbol)}.NS`,
    };
  } catch {
    return null;
  }
}

// Tavily's free tier is 1,000 searches/month and nothing counted them. Every
// call is now an edge_log row (lane 'tavily', kept 30 d), and past the cap
// tier 2 simply returns nothing — Ask degrades to our own stories.
let tavilyAt = 0, tavilyN = 0;
const TAVILY_MS = 5 * 60e3;
async function tavilyUsed(): Promise<number> {
  if (Date.now() - tavilyAt < TAVILY_MS) return tavilyN;
  try {
    const first = new Date();
    first.setUTCDate(1);
    first.setUTCHours(0, 0, 0, 0);
    const { count } = await sb.from("edge_log").select("fn", { count: "exact", head: true })
      .eq("fn", FN).eq("lane", "tavily").gte("created_at", first.toISOString());
    tavilyN = count ?? 0; // ponytail: 30 d log vs a 31 d month — off by <= 1 day; the cap has slack
  } catch {
    tavilyN = 0;
  }
  tavilyAt = Date.now();
  return tavilyN;
}

async function tier2(question: string): Promise<Source[]> {
  const key = Deno.env.get("TAVILY_API_KEY");
  if (!key) return [];
  if (await tavilyUsed() >= (edgeCfg.tavily_cap ?? 800)) return [];
  const t0 = Date.now();
  try {
    const r = await fetch("https://api.tavily.com/search", {
      method: "POST",
      signal: AbortSignal.timeout(8000),
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        api_key: key, query: question, max_results: 5, include_domains: WHITELIST,
      }),
    });
    tavilyN++;
    await logCall("tavily", r.ok, r.status, r.ok ? null : await r.text(), Date.now() - t0);
    if (!r.ok) return [];
    const results = (await r.json()).results ?? [];
    return results.map((x: { title: string; content: string; url: string }) => ({
      title: x.title, body: x.content, source_name: new URL(x.url).hostname, url: x.url,
    }));
  } catch (e) {
    await logCall("tavily", false, null, String(e), Date.now() - t0);
    return [];
  }
}

function refusal() {
  return {
    whats_happening: REFUSAL, why: "", who_is_affected: "", what_to_watch: "",
    confidence: "low", sources: [], followups: [], sections: [], tier: 2,
    refused: true,
  };
}

/** The explainer answer. `sections` is the new field; `whats_happening` is filled
 *  from the first section so an app build that predates sections still renders a
 *  real answer instead of four blanks. */
async function conceptAnswer(question: string, terms: string[]) {
  const sources = await tier1(question, terms); // free: a DB query, not an AI call
  const raw = await chat(conceptPrompt(question, sources), "smart");
  if (raw === null) return { error: 503 as const };
  let out;
  try {
    out = JSON.parse(raw);
  } catch {
    return null; // bad JSON -> caller falls through to the news lane
  }
  if (out.refused) return null;
  const sections = (Array.isArray(out.sections) ? out.sections : [])
    .filter((s: { body?: unknown }) =>
      !!s && typeof s.body === "string" && s.body.trim().length > 0
    )
    .slice(0, 8)
    .map((s: { heading?: unknown; body: string }) => ({
      heading: typeof s.heading === "string" ? s.heading : "",
      body: s.body,
    }));
  if (!sections.length) return null;
  return {
    whats_happening: sections[0].body,
    why: "", who_is_affected: "", what_to_watch: "",
    confidence: ["high", "medium", "low"].includes(out.confidence) ? out.confidence : "low",
    // Attached as further reading, never as the basis of the explanation — so
    // they are not run through the citation contract the news lane uses.
    sources: sources.slice(0, 3).map(({ title, url, source_name }) => ({
      title, url, source_name,
    })),
    followups: (Array.isArray(out.followups) ? out.followups : []).slice(0, 3).map(String),
    sections,
    tier: 0,
    refused: false,
  };
}

/** One sourced "smart" call over `sources`. null = the model refused or
 *  returned bad JSON (caller tries the next tier); {error: 503} = every lane
 *  down. Shared by the planner-routed path and the context path. */
async function askSources(question: string, sources: Source[], tier: 1 | 2) {
  const raw = await chat(prompt(question, sources), "smart");
  if (raw === null) return { error: 503 as const };
  let out;
  try {
    out = JSON.parse(raw);
  } catch {
    return null; // bad JSON -> try next tier
  }
  if (out.refused) return null; // tier 1 refusal -> try web
  // Models (gpt-oss especially) often answer well but leave `cited` empty.
  // The answer was generated ONLY from these sources, so attaching them is
  // honest — an empty citation list on a real answer would break the
  // "every claim sourced" promise the whole Q&A design rests on.
  const cited: number[] = (Array.isArray(out.cited) ? out.cited : [])
    .map(Number).filter((i: number) => Number.isInteger(i));
  // Guard the resolved list, not just `cited.length`: models also cite
  // numbers that don't exist ([4,5] for three sources), which filtered down
  // to nothing and shipped a sourceless answer — the exact failure the
  // citation contract is meant to prevent.
  const resolved = cited.map((i) => sources[i - 1]).filter(Boolean);
  const picked = resolved.length ? resolved : sources.slice(0, 3);
  return {
    whats_happening: String(out.whats_happening ?? ""),
    why: String(out.why ?? ""),
    who_is_affected: String(out.who_is_affected ?? ""),
    what_to_watch: String(out.what_to_watch ?? ""),
    confidence: ["high", "medium", "low"].includes(out.confidence) ? out.confidence : "low",
    sources: picked.map(({ title, url, source_name }) => ({ title, url, source_name })),
    followups: (Array.isArray(out.followups) ? out.followups : []).slice(0, 3).map(String),
    // Empty on this lane: sections are what marks an answer as an explainer,
    // and the app picks its disclaimer off exactly that.
    sections: [],
    tier,
    refused: false,
  };
}

async function answer(question: string) {
  const plan_ = await plan(question);
  if (plan_?.kind === "refuse") return refusal(); // advice/off-topic: no second call
  const terms = plan_?.terms ?? [];

  if (plan_?.kind === "concept") {
    const out = await conceptAnswer(question, terms);
    if (out) return out; // null -> explainer declined; the news lanes still get a go
  }

  // Live quotes ride along with whichever tier answers: a price question gets
  // the number first, a news question gets the number as context. They are
  // never enough on their own to skip the sourced-answer contract — the model
  // still cites [n], and a quote-only answer is still an answer from sources.
  // Two independent DB reads: one round trip, not two.
  const [live, ours] = await Promise.all([liveQuotes(terms), tier1(question, terms)]);
  for (const tier of [1, 2] as const) {
    const sources = [...live, ...(tier === 1 ? ours : await tier2(question))];
    if (!sources.length) continue;
    const out = await askSources(question, sources, tier);
    if (out === null) continue; // refused / bad JSON -> next tier
    return out;
  }
  return refusal();
}

// ---------- "ask about this" (2026-09-13) ----------
// The app sends story_id from the deep-read pages or symbol from the stock
// page. The planner call is skipped — the context already says what the
// question is about — and the sources are the story's own cluster, or the
// symbol's live quote + screener row, plus our archive. One smart call.
const SYMBOL_RE = /^[A-Z0-9][A-Z0-9&-]{0,19}$/; // migration 018's symbol shape
const NAME_STOP = new Set(["ltd", "limited", "india", "the", "and", "company", "corporation"]);

/** null = the context is unusable (unknown or unpublished story): the caller
 *  falls back to the plain path, so status is never leaked. */
async function contextAnswer(question: string, storyId: number | null, symbol: string | null) {
  const own: Source[] = [];
  let terms: string[] = [];
  let archive: Promise<Source[]> = Promise.resolve([]);
  if (storyId !== null) {
    const { data: row } = await sb.from("stories")
      .select("id, headline, summary, source_name, source_url, cluster_id, status")
      .eq("id", storyId).maybeSingle();
    if (!row || row.status !== "approved") return null;
    const [{ data: members }, { data: links }] = await Promise.all([
      row.cluster_id
        ? sb.from("stories").select("headline, summary, source_name, source_url")
          .eq("cluster_id", row.cluster_id).neq("id", storyId)
          .in("status", ["approved", "duplicate"]).limit(12)
        : Promise.resolve({ data: [] as Record<string, string>[] }),
      sb.from("story_companies").select("companies(nse_symbol)").eq("story_id", storyId),
    ]);
    for (const s of [row, ...(members ?? [])]) {
      own.push({ title: s.headline, body: s.summary ?? "", source_name: s.source_name, url: s.source_url });
    }
    // supabase-js types a many-to-one embed as an array; at runtime it is one object. Take either.
    terms = ((links ?? []) as { companies?: unknown }[])
      .map((l) => Array.isArray(l.companies) ? l.companies[0] : l.companies)
      .map((c) => String((c as { nse_symbol?: string } | null)?.nse_symbol ?? "").toLowerCase())
      .filter(Boolean);
  } else if (symbol !== null) {
    const scr = await screenerSource(symbol);
    if (scr) own.push(scr);
    terms = [symbol.toLowerCase()];
    const nameWords = (scr?.title.toLowerCase().match(/[a-z0-9]+/g) ?? [])
      .filter((w) => w.length > 2 && !NAME_STOP.has(w) && w !== "screener" && w !== symbol.toLowerCase());
    archive = tier1(question, [...terms, ...nameWords]);
  }
  const [live, ours] = await Promise.all([terms.length ? liveQuotes(terms) : [], archive]);
  const sources = [...live, ...own, ...ours];
  if (!sources.length) return refusal();
  return (await askSources(question, sources, 1)) ?? refusal();
}

// Jargon glossary (2026-08-28): the CANONICAL term whitelist — the app ships a
// copy for highlighting, but this set is what the server accepts. Bounded on
// purpose: with ~40 terms cached in qa_cache, the glossary costs at most ~40
// AI calls per retention window, globally, so defines can skip the per-user cap.
const DEFINE_TERMS = new Set([
  "crr", "slr", "repo rate", "reverse repo", "mclr", "basis points",
  "qip", "ofs", "fpo", "buyback", "rights issue", "bonus issue",
  "stock split", "open offer", "delisting", "anchor investor", "green shoe",
  "lock-in", "gmp", "listing gains", "fii", "dii", "promoter holding",
  "pledge", "stake sale", "nbfc", "npa", "casa", "ebitda", "pat", "yoy",
  "qoq", "capex", "upper circuit", "lower circuit", "f&o", "derivatives",
  "margin call", "market cap", "pe ratio", "book value", "face value",
  "dividend yield", "sip", "elss", "reit", "invit", "esop", "arbitrage",
  // Markets/Stock-page jargon (2026-09-05): the tap-to-explain layer now
  // covers KvTable metric names and section footnotes too.
  "pcr", "open interest", "oi", "g-sec", "t-bill", "roce", "roe", "opm",
  "rsi", "macd", "sma", "golden cross", "death cross", "advance decline",
  "beta", "cagr", "promoter pledge", "vix", "lpr", "breadth", "bulk deal",
  "block deal", "circuit filter", "oversubscription", "grey market",
  "p/e", "p/b", "p/s", "sharpe", "sortino", "atr", "piotroski", "graham number", "ev/ebitda",
  "roic", "interest cover", "fcf yield", "earnings yield", "all-time high",
  "max pain", "record date",
  "golden cross", "death cross", "52-week breakout", "52-week breakdown", "volume spike", "gap up", "gap down",
  "nr7", "inside bar", "hammer candle", "shooting star", "bullish engulfing", "bearish engulfing", "doji",
  // 26 Sep 2026: every term the app underlines or the screener defines (033)
  "10-year return", "52-week", "52-week high", "52-week low", "all-time low", "altman z", "analyst coverage", "asset turnover", "average pe", "average true range", "average volume", "borrowings", "buyback yield", "camarilla", "cash and equivalents", "cash conversion", "cash conversion cycle", "change from open", "consensus", "correlation", "current ratio", "debt to ebitda", "debt to equity", "debt to free cash flow", "debtor days", "delivery", "depreciation", "dii holding", "dilution", "dividend growth", "dividend growth years", "dividend payment years", "dividend payout", "dma", "dupont", "ebitda margin", "effective tax rate", "employees", "enterprise value", "eps", "eps growth", "ev/ebit", "ev/fcf", "ev/sales", "ex-date", "fcf margin", "fibonacci", "fii holding", "forward pe", "free cash flow", "free cash flow per share", "free float", "fwd pe", "gap up", "gross margin", "industry pe", "institutional holding", "interest cost", "interest coverage", "inventory days", "leverage", "long build-up", "lot size", "lynch fair value", "margin trend", "max drawdown", "moving average", "net cash", "net cash to market cap", "net debt to ebitda", "net margin", "net profit", "net worth", "oi build-up", "operating cash flow", "operating margin", "operating profit", "other income", "payable days", "pb", "pe", "peg ratio", "piotroski f-score", "pivot", "position in range", "pretax margin", "price target", "price to ebitda", "price to free cash flow", "price to operating cash flow", "price to sales", "profit growth", "profitable years", "promoter", "public holding", "put/call ratio", "quarterly growth", "quick ratio", "relative volume", "reserves", "return", "return on assets", "return on capital employed", "return on equity", "revenue", "revenue growth years", "revenue per employee", "sales growth", "seasonality", "sector pe", "shareholder yield", "shareholders", "sharpe ratio", "short covering", "sortino ratio", "strike", "surprise", "tangible book value", "total assets", "total return", "trades", "ttm", "turning bearish", "turning bullish", "turnover", "up days", "volatility", "vwap", "wacc", "working capital days", "z-score",
]);

async function questionHash(norm: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(norm));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// ---------- cost guards ----------
// Caps reset at IST midnight (was UTC = 05:30 IST, mid-morning for the market
// open). Both counts fail OPEN — a failed count allows the call, mirroring
// deepread: this is cost protection, not a security boundary.
function istMidnightIso(): string {
  const d = new Date(Date.now() + 5.5 * 3600e3);
  d.setUTCHours(0, 0, 0, 0);
  return new Date(d.getTime() - 5.5 * 3600e3).toISOString();
}
async function asksSince(since: string, userId?: string): Promise<number> {
  try {
    let q = sb.from("events").select("id", { count: "exact", head: true })
      .eq("type", "qa_ask").gte("created_at", since);
    if (userId) q = q.eq("user_id", userId);
    const { count } = await q;
    return count ?? 0;
  } catch {
    return 0;
  }
}
// The whole free pool is shared by every user, so a per-user cap alone lets
// 1,000 users × 50 ask 50,000 times against ~2,000 free calls a day. One
// count a minute (per warm isolate) is plenty for a budget with slack in it.
let globalAt = 0, globalN = 0;
async function globalAsks(since: string): Promise<number> {
  if (Date.now() - globalAt < 60e3) return globalN;
  globalN = await asksSince(since);
  globalAt = Date.now();
  return globalN;
}

// How long a cached answer stays valid depends on what it is: an explainer
// doesn't age, a Tavily-backed answer is scarce (metered), news moves.
const freshOf = (a: Record<string, unknown>): number =>
  Array.isArray(a.sections) && a.sections.length ? 24 * 3600e3
  : a.tier === 2 ? 60 * 60e3
  : 30 * 60e3;

Deno.serve(async (req) => {
  const jwt = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
  // Three independent reads, one round trip.
  const [{ data: userData }, , reqBody] = await Promise.all([
    sb.auth.getUser(jwt), loadCfg(), req.json().catch(() => ({})),
  ]);
  const user = userData?.user;
  if (!user) return new Response("unauthorized", { status: 401 });
  if (edgeCfg.qa_enabled === false) return new Response("paused by admin", { status: 503 });

  const question = String(reqBody?.question ?? "").trim().slice(0, 300);
  if (!question) return new Response("question required", { status: 400 });

  // mode:"define" — a tapped glossary term. No daily-cap count (a term tap
  // must not burn one of the reader's 50 questions), no qa_ask event, and no
  // TTL: one AI call per term per retention window, then qa_cache serves it
  // to every user.
  if (reqBody?.mode === "define") {
    const term = question.toLowerCase().replace(/\s+/g, " ");
    if (!DEFINE_TERMS.has(term)) return new Response("unknown term", { status: 400 });
    const hash = await questionHash(`define::${term}`);
    const out = await cachedAnswer(sb, hash, null, async () => {
      const a = await conceptAnswer(
        `What is ${term} in Indian markets? Explain briefly for a beginner.`, [term]);
      return !a || "error" in a ? null : a;
    });
    if (!out) return new Response("all providers busy", { status: 503 });
    return Response.json(out);
  }

  // Context, when the app sends it. Number(null) is 0, hence the null check.
  const storyId = reqBody?.story_id != null && Number.isInteger(Number(reqBody.story_id))
    ? Number(reqBody.story_id) : null;
  const symbol = typeof reqBody?.symbol === "string" && SYMBOL_RE.test(reqBody.symbol)
    ? reqBody.symbol : null;

  // Abuse guard: 50/user/day, silent (spec §5.5) — plus the global budget.
  const since = istMidnightIso();
  const [mine, all] = await Promise.all([asksSince(since, user.id), globalAsks(since)]);
  if (mine >= (edgeCfg.daily_cap ?? 50)) return new Response("daily limit", { status: 429 });

  // Cache: identical question inside the TTL costs zero AI (market panic guard).
  // cachedAnswer adds the stampede guard: N concurrent misses on a breaking
  // story cost one model call, not N; a failure answers "busy" for 2 min.
  // A context question is keyed with its context so it never collides with
  // the bare question.
  const norm = question.toLowerCase().replace(/[^a-z0-9 ]/g, "").replace(/\s+/g, " ");
  const ctx = storyId !== null ? `story:${storyId}::` : symbol !== null ? `sym:${symbol}::` : "";
  const hash = await questionHash(ctx + norm);

  if (all >= (edgeCfg.global_cap ?? 1500)) {
    // Budget spent for the day: what is already answered still serves; nothing new is computed.
    const hit = await peekAnswer(sb, hash, freshOf);
    return hit ? Response.json(hit) : new Response("busy today", { status: 503 });
  }
  globalN++; // count ourselves until the next memo refresh

  const compute = async () => {
    const a = storyId !== null || symbol !== null
      ? (await contextAnswer(question, storyId, symbol)) ?? await answer(question)
      : await answer(question);
    return "error" in a ? null : a;
  };
  // qa_ask logged for cache hits too — the guard counts questions, not AI
  // calls. The insert and the cache read do not depend on each other.
  const [, out] = await Promise.all([
    sb.from("events").insert({ user_id: user.id, type: "qa_ask" }),
    cachedAnswer(sb, hash, freshOf, compute),
  ]);
  if (!out) return new Response("all providers busy", { status: 503 });
  return Response.json(out);
});
