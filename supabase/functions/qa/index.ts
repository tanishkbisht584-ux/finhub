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

// (key, model) lanes, Groq-first; same comma-separated multi-key pattern as the
// pipeline. Order = preference: strongest chat model across every key first.
function lanes(): { url: string; key: string; model: string }[] {
  const out: { url: string; key: string; model: string }[] = [];
  const groqKeys = (Deno.env.get("GROQ_API_KEYS") ?? Deno.env.get("GROQ_API_KEY") ?? "")
    .split(",").map((k) => k.trim()).filter(Boolean);
  for (const model of ["openai/gpt-oss-120b", "llama-3.3-70b-versatile"]) {
    for (const key of groqKeys) {
      out.push({ url: "https://api.groq.com/openai/v1/chat/completions", key, model });
    }
  }
  return out;
}

async function chat(prompt: string): Promise<string | null> {
  for (const { url, key, model } of lanes()) {
    try {
      const r = await fetch(url, {
        method: "POST",
        headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          model, temperature: 0.2,
          response_format: { type: "json_object" },
          messages: [{ role: "user", content: prompt }],
        }),
      });
      if (!r.ok) continue; // 429/503/anything -> next lane
      return (await r.json()).choices[0].message.content;
    } catch {
      continue; // a provider outage must never surface as a 500
    }
  }
  // Gemini depth: only reached when every Groq lane is down.
  for (
    const key of (Deno.env.get("GEMINI_API_KEYS") ?? Deno.env.get("GEMINI_API_KEY") ?? "")
      .split(",").map((k) => k.trim()).filter(Boolean)
  ) {
    try {
      const r = await fetch(
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent",
        {
          method: "POST",
          headers: { "x-goog-api-key": key, "Content-Type": "application/json" },
          body: JSON.stringify({
            contents: [{ parts: [{ text: prompt }] }],
            generationConfig: { response_mime_type: "application/json", temperature: 0.2 },
          }),
        },
      );
      if (!r.ok) continue;
      return (await r.json()).candidates[0].content.parts[0].text;
    } catch {
      continue;
    }
  }
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
{"whats_happening": "1-2 sentences", "why": "1-2 sentences", "who_is_affected": "1-2 sentences", "what_to_watch": "1 sentence", "confidence": "high|medium|low", "cited": [1], "followups": ["question", "question"], "refused": false}
cited = source numbers you actually used. followups = 2 short related questions answerable from these sources.`;
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

async function tier1(question: string): Promise<Source[]> {
  const tsq = tsQuery(question);
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

async function answer(question: string) {
  for (const [tier, fetchSources] of [[1, tier1], [2, tier2]] as const) {
    const sources = await fetchSources(question);
    if (!sources.length) continue;
    const raw = await chat(prompt(question, sources));
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
      tier,
      refused: false,
    };
  }
  return {
    whats_happening: REFUSAL, why: "", who_is_affected: "", what_to_watch: "",
    confidence: "low", sources: [], followups: [], tier: 2, refused: true,
  };
}

Deno.serve(async (req) => {
  const jwt = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
  const { data: userData } = await sb.auth.getUser(jwt);
  const user = userData?.user;
  if (!user) return new Response("unauthorized", { status: 401 });

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
  if ((count ?? 0) >= 50) return new Response("daily limit", { status: 429 });

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
