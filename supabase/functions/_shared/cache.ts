// Read-through cache over qa_cache with stampede + failure guards (P0, from
// the worldmonitor study). The old flow was read -> compute -> upsert: N
// concurrent identical questions on a breaking story all missed and all paid a
// model call. Now the first miss upserts a {__pending} sentinel, so concurrent
// losers poll the row briefly instead of computing; a failed compute leaves a
// short-lived {__error} sentinel so a broken provider isn't hammered.
// ponytail: sentinel-poll, not a lock — a rare double-compute is accepted;
// upgrade to a pg advisory lock only if quota burn ever shows it matters.

const PENDING_MS = 30e3;      // a pending sentinel older than this = dead writer
const ERROR_MS = 2 * 60e3;    // how long a failure answers "busy" without a retry
const POLLS = 3;
const POLL_MS = 1500;

type Row = { answer_json: Record<string, unknown>; created_at: string } | null;

/** freshMs: max age of a valid hit (null = cached forever, e.g. define terms).
 *  compute: returns the answer object, or null for "providers busy".
 *  Returns the answer object, or null (caller renders its 503). */
export async function cachedAnswer(
  // deno-lint-ignore no-explicit-any
  sb: any, hash: string, freshMs: number | null,
  compute: () => Promise<Record<string, unknown> | null>,
): Promise<Record<string, unknown> | null> {
  const read = async (): Promise<Row> => {
    const { data } = await sb.from("qa_cache").select("answer_json, created_at")
      .eq("question_hash", hash).maybeSingle();
    return data ?? null;
  };
  const age = (r: Row) => Date.now() - new Date(r!.created_at).getTime();
  const valid = (r: Row) => !!r && !r.answer_json?.__pending && !r.answer_json?.__error &&
    (freshMs === null || age(r) < freshMs);

  let row = await read();
  if (valid(row)) return row!.answer_json;
  if (row?.answer_json?.__error && age(row) < ERROR_MS) return null;
  if (row?.answer_json?.__pending && age(row) < PENDING_MS) {
    for (let i = 0; i < POLLS; i++) {  // someone else is computing this answer
      await new Promise((r) => setTimeout(r, POLL_MS));
      row = await read();
      if (valid(row)) return row!.answer_json;
    }
    // writer died or is slow past our patience: compute ourselves
  }
  await sb.from("qa_cache").upsert({
    question_hash: hash, answer_json: { __pending: true }, created_at: new Date().toISOString(),
  });
  const out = await compute().catch(() => null);
  await sb.from("qa_cache").upsert({
    question_hash: hash, answer_json: out ?? { __error: true }, created_at: new Date().toISOString(),
  });
  return out;
}
