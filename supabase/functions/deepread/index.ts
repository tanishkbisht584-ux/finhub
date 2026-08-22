// Deep read (spec 2026-08-16): the whole story, written once, cached forever.
// POST {story_id} -> {"pages":[{heading,body}...]}; {"pages":[]} = refusal,
// returned but never cached so a later open retries.
import { createClient } from "npm:@supabase/supabase-js@2";

const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SERVICE_KEY")!,
);

// (key, model) lanes, strongest-first; same comma-separated multi-key pattern
// as the pipeline. Mirrors qa/index.ts's "smart" lane (18 Aug 2026): a deep
// read is written ONCE and cached forever, so it deserves the best free model
// even more than a throwaway answer does. gemini-3.7-flash is the newest flash
// our keys can use (pro is 429 on free keys); llama-3.3-70b was retired from
// Groq's catalog; qwen3.6-27b is the strongest live replacement.
type Lane = { provider: "groq" | "gemini"; key: string; model: string; lane: string };
const FN = "deepread";

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

const DEFAULT_ORDER: [("groq" | "gemini"), string][] = [
  ["gemini", "gemini-3.7-flash"], ["groq", "openai/gpt-oss-120b"],
  ["groq", "qwen/qwen3.6-27b"], ["gemini", "gemini-3.5-flash-lite"],
];

// Lane order is overridable from the admin (app_config.edge.lanes.deepread).
function lanes(): Lane[] {
  const groq = keysOf("GROQ_API_KEYS", "GROQ_API_KEY");
  const gemini = keysOf("GEMINI_API_KEYS", "GEMINI_API_KEY");
  return laneOrder("deepread", DEFAULT_ORDER).flatMap(([provider, model]) =>
    (provider === "groq" ? groq : gemini).map((key, i) =>
      ({ provider, key, model, lane: `${provider}/${model}#${i}` }))
  );
}

async function chat(prompt: string): Promise<string | null> {
  for (const { provider, key, model, lane } of lanes()) {
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

type Member = { headline: string; source_name: string; source_url: string | null };

// Bounded, best-effort fetch of the source article's plain text. news.google.com
// is a GNews wrapper (JS-locked, verified 2026-08-12) and must never be fetched
// here. ANY failure (network, timeout, non-text body) degrades to "" — the
// prompt still works from headline/hook/summary/cluster corroboration alone.
async function fetchArticleText(url: string): Promise<string> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 5000);
  try {
    const r = await fetch(url, { signal: ctrl.signal });
    const html = await r.text();
    return html
      .replace(/<script[\s\S]*?<\/script>/gi, "")
      .replace(/<style[\s\S]*?<\/style>/gi, "")
      .replace(/<[^>]+>/g, " ")
      .replace(/\s+/g, " ")
      .trim()
      .slice(0, 6000);
  } catch {
    return "";
  } finally {
    clearTimeout(timer);
  }
}

function isGNews(url: string | null): boolean {
  return !!url && url.includes("news.google.com");
}

function prompt(
  row: {
    headline: string; hook: string | null; summary: string | null;
    category: string | null; impact_score: number | null;
  },
  members: Member[],
  articleText: string,
): string {
  const also = members.map((m) => `${m.headline} — ${m.source_name}`).join("\n");
  return `You are FinSwipe's staff writer. Using ONLY the material below, write the
whole story for a reader who knows nothing about it, in plain easy English.
Facts only, never advice, never numbers that are not in the material.
Structure it as 4-8 newspaper pages, each 80-160 words:
"What happened", "Background", "Who is affected", "Why it matters",
and "What's next" only if the material supports it. Go deeper rather than
wider: unpack terms a beginner would not know, spell out the chain of cause
and effect, and use every relevant fact the material offers — but never pad;
a thin story honestly told in 4 pages beats a padded 8.
If the material is too thin to write honestly, return {"pages": []}.
Return ONLY JSON: {"pages": [{"heading": "...", "body": "..."}]}

HEADLINE: ${row.headline} / HOOK: ${row.hook ?? ""} / SUMMARY: ${row.summary ?? ""}
CATEGORY: ${row.category ?? ""} IMPACT: ${row.impact_score ?? ""}/10
ALSO REPORTED BY: ${also || "(no other sources)"}
ARTICLE TEXT: ${articleText || "(unavailable)"}`;
}

// A fresh Response each call — Deno.serve handles concurrent requests, and a
// Response body is a single-use stream, so a module-level constant reused
// across requests risks "body already used" (a refusal turning into a 500).
function refusal() {
  return Response.json({ pages: [] });
}

Deno.serve(async (req) => {
  // Same auth stance as qa: caller must be a signed-in user.
  const jwt = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
  const { data: userData } = await sb.auth.getUser(jwt);
  const user = userData?.user;
  if (!user) return new Response("unauthorized", { status: 401 });

  edgeCfg = await loadCfg();
  if (edgeCfg.deepread_enabled === false) return refusal(); // admin pause: honest refusal page

  const body = await req.json().catch(() => ({}));
  const storyId = Number(body?.story_id);
  if (!Number.isInteger(storyId)) return new Response("story_id required", { status: 400 });

  // Re-impose status='approved' explicitly (sb is service-role, bypasses RLS) —
  // same posture as qa's search_stories RPC. Non-approved looks identical to
  // absent so status is never leaked.
  const { data: row } = await sb.from("stories")
    .select("id, headline, hook, summary, category, impact_score, source_url, cluster_id, deep_read, status")
    .eq("id", storyId).maybeSingle();
  if (!row || row.status !== "approved") return new Response("not found", { status: 404 });

  // Already generated: return the cached read, no AI call, doesn't count
  // against the generation cap below.
  if (row.deep_read) return Response.json(row.deep_read);

  // Cost guard: 50 GENERATIONS/user/day, silent (mirrors qa's abuse guard,
  // qa/index.ts:210-217). Cached reads above are free and never reach here.
  // Type 'deep_read' matches the app's PostHog event name and 008's CHECK
  // constraint update. This is cost protection, not a security boundary: a
  // failed count/insert (network blip, unexpected error) degrades to
  // ALLOWING generation rather than blocking it — swallowed, not logged.
  if (user) {
    try {
      const midnight = new Date();
      midnight.setUTCHours(0, 0, 0, 0);
      const { count, error } = await sb.from("events")
        .select("id", { count: "exact", head: true })
        .eq("user_id", user.id).eq("type", "deep_read")
        .gte("created_at", midnight.toISOString());
      if (!error && (count ?? 0) >= (edgeCfg.daily_cap ?? 50)) return new Response("daily limit", { status: 429 });
      await sb.from("events").insert({ user_id: user.id, type: "deep_read" });
    } catch {
      // cap check/log unavailable -> proceed rather than block generation
    }
  }

  let members: Member[] = [];
  if (row.cluster_id != null) {
    const { data } = await sb.from("stories")
      .select("headline, source_name, source_url")
      .eq("cluster_id", row.cluster_id).neq("id", storyId).limit(12);
    members = data ?? [];
  }

  // Article body: the story's own URL unless it's a GNews wrapper, else the
  // first cluster member with a real, non-GNews URL (a null source_url must
  // not short-circuit past a later member that has one).
  let articleUrl = !isGNews(row.source_url) ? row.source_url : null;
  if (!articleUrl) {
    articleUrl = members.find((m) => m.source_url && !isGNews(m.source_url))?.source_url ?? null;
  }
  const articleText = articleUrl ? await fetchArticleText(articleUrl) : "";

  const raw = await chat(prompt(row, members, articleText));
  if (raw === null) return refusal(); // every lane down -> honest refusal, never a 500

  let out: unknown;
  try {
    out = JSON.parse(raw);
  } catch {
    return refusal(); // bad JSON -> refusal, not cached
  }

  const rawPages = Array.isArray((out as { pages?: unknown })?.pages)
    ? (out as { pages: unknown[] }).pages
    : [];
  const validated = rawPages
    .filter((p): p is { heading?: unknown; body: string } =>
      !!p && typeof p === "object" && typeof (p as { body?: unknown }).body === "string" &&
      (p as { body: string }).body.trim().length > 0
    )
    .slice(0, 8)
    .map((p) => ({
      heading: typeof p.heading === "string" ? p.heading : null,
      body: p.body,
    }));

  if (validated.length === 0) return refusal(); // refusal is never cached

  const deepRead = { pages: validated };
  await sb.from("stories").update({ deep_read: deepRead }).eq("id", storyId);
  return Response.json(deepRead);
});
