// Q&A: the app's only runtime AI (spec §5). Groq-first per 2026-08-08 decision —
// chat never competes with the pipeline's Gemini pool. Tier 1: our stories via
// FTS. Tier 2: Tavily over whitelisted domains. The model must never answer
// from its own knowledge.
import { createClient } from "npm:@supabase/supabase-js@2";

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
// app_config.edge is the admin's kill switch / daily cap / lane order for this
// function. {} (table missing, row missing, any error) = the defaults below.
type EdgeCfg = {
  qa_enabled?: boolean; deepread_enabled?: boolean; daily_cap?: number;
  lanes?: Record<string, [string, string][]>;
};
let edgeCfg: EdgeCfg = {}; // set per request; identical for every concurrent request
async function loadCfg(): Promise<EdgeCfg> {
  try {
    const { data } = await sb.from("app_config").select("value").eq("key", "edge").maybeSingle();
    return (data?.value as EdgeCfg) ?? {};
  } catch {
    return {};
  }
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

// Lane order is overridable per kind from the admin (app_config.edge.lanes.smart / .fast).
function lanes(kind: "smart" | "fast"): Lane[] {
  const groq = keysOf("GROQ_API_KEYS", "GROQ_API_KEY");
  const gemini = keysOf("GEMINI_API_KEYS", "GEMINI_API_KEY");
  return laneOrder(kind, DEFAULT_ORDER[kind]).flatMap(([provider, model]) =>
    (provider === "groq" ? groq : gemini).map((key, i) =>
      ({ provider, key, model, lane: `${provider}/${model}#${i}` }))
  );
}

async function chat(prompt: string, kind: "smart" | "fast" = "fast"): Promise<string | null> {
  for (const { provider, key, model, lane } of lanes(kind)) {
    const t0 = Date.now();
    try {
      if (provider === "groq") {
        const r = await fetch("https://api.groq.com/openai/v1/chat/completions", {
          method: "POST",
          headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
          body: JSON.stringify({
            model, temperature: 0.2,
            response_format: { type: "json_object" },
            messages: [{ role: "user", content: prompt }],
          }),
        });
        if (!r.ok) { // 429/503/retired model/anything -> next lane
          await logCall(lane, false, r.status, await r.text(), Date.now() - t0);
          continue;
        }
        const text = (await r.json()).choices[0].message.content;
        await logCall(lane, true, 200, null, Date.now() - t0);
        return text;
      }
      const r = await fetch(
        `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`,
        {
          method: "POST",
          headers: { "x-goog-api-key": key, "Content-Type": "application/json" },
          body: JSON.stringify({
            contents: [{ parts: [{ text: prompt }] }],
            generationConfig: { response_mime_type: "application/json", temperature: 0.2 },
          }),
        },
      );
      if (!r.ok) {
        await logCall(lane, false, r.status, await r.text(), Date.now() - t0);
        continue;
      }
      const text = (await r.json()).candidates[0].content.parts[0].text;
      await logCall(lane, true, 200, null, Date.now() - t0);
      return text;
    } catch (e) {
      await logCall(lane, false, null, String(e), Date.now() - t0);
      continue; // a provider outage must never surface as a 500
    }
  }
  await logCall("none", false, null, "all lanes failed", 0);
  return null;
}

function prompt(question: string, sources: Source[]): string {
  const listing = sources.map((s, i) => `[${i + 1}] ${s.title}\n${s.body}`).join("\n\n");
  return `You explain Indian market news to retail investors. Answer ONLY from the numbered sources below. Never use outside knowledge. If the sources do not clearly answer the question, set refused=true.
HARD RULE: if the question asks for investment advice, a recommendation, or a prediction (should I buy/sell, will it rise, price targets, which stock to pick), set refused=true no matter what the sources say. Describing news about a company is not permission to advise on it.

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
  "concept" - asks what something IS or HOW it works: a term, abbreviation,
              product, rule, process or institution. "what is X" is concept even
              when X is unfamiliar to you - never refuse a term just because it
              is ambiguous or misspelled.
  "news"    - asks what happened, or why something moved.

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

async function tier2(question: string): Promise<Source[]> {
  const key = Deno.env.get("TAVILY_API_KEY");
  if (!key) return [];
  try {
    const r = await fetch("https://api.tavily.com/search", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        api_key: key, query: question, max_results: 5, include_domains: WHITELIST,
      }),
    });
    if (!r.ok) return [];
    const results = (await r.json()).results ?? [];
    return results.map((x: { title: string; content: string; url: string }) => ({
      title: x.title, body: x.content, source_name: new URL(x.url).hostname, url: x.url,
    }));
  } catch {
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

async function answer(question: string) {
  const plan_ = await plan(question);
  if (plan_?.kind === "refuse") return refusal(); // advice/off-topic: no second call
  const terms = plan_?.terms ?? [];

  if (plan_?.kind === "concept") {
    const out = await conceptAnswer(question, terms);
    if (out) return out; // null -> explainer declined; the news lanes still get a go
  }

  for (const tier of [1, 2] as const) {
    const sources = tier === 1 ? await tier1(question, terms) : await tier2(question);
    if (!sources.length) continue;
    const raw = await chat(prompt(question, sources), "smart");
    if (raw === null) return { error: 503 as const };
    let out;
    try {
      out = JSON.parse(raw);
    } catch {
      continue; // bad JSON -> try next tier
    }
    if (out.refused) continue; // tier 1 refusal -> try web
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
  return refusal();
}

Deno.serve(async (req) => {
  const jwt = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
  const { data: userData } = await sb.auth.getUser(jwt);
  const user = userData?.user;
  if (!user) return new Response("unauthorized", { status: 401 });

  edgeCfg = await loadCfg();
  if (edgeCfg.qa_enabled === false) return new Response("paused by admin", { status: 503 });

  const question = String((await req.json().catch(() => ({}))).question ?? "")
    .trim().slice(0, 300);
  if (!question) return new Response("question required", { status: 400 });

  // Abuse guard: 50/user/day, silent (spec §5.5).
  const midnight = new Date();
  midnight.setUTCHours(0, 0, 0, 0);
  const { count } = await sb.from("events")
    .select("id", { count: "exact", head: true })
    .eq("user_id", user.id).eq("type", "qa_ask")
    .gte("created_at", midnight.toISOString());
  if ((count ?? 0) >= (edgeCfg.daily_cap ?? 50)) return new Response("daily limit", { status: 429 });

  // Cache: identical question inside 15 min costs zero AI (market panic guard).
  const norm = question.toLowerCase().replace(/[^a-z0-9 ]/g, "").replace(/\s+/g, " ");
  const hashBuf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(norm));
  const hash = [...new Uint8Array(hashBuf)].map((b) => b.toString(16).padStart(2, "0")).join("");
  const fresh = new Date(Date.now() - 15 * 60e3).toISOString();
  const { data: hit } = await sb.from("qa_cache").select("answer_json, created_at")
    .eq("question_hash", hash).gte("created_at", fresh).maybeSingle();

  // qa_ask logged for cache hits too — the guard counts questions, not AI calls.
  await sb.from("events").insert({ user_id: user.id, type: "qa_ask" });

  if (hit) return Response.json(hit.answer_json);

  const out = await answer(question);
  if ("error" in out) return new Response("all providers busy", { status: 503 });

  await sb.from("qa_cache").upsert({
    question_hash: hash, answer_json: out, created_at: new Date().toISOString(),
  });
  return Response.json(out);
});
