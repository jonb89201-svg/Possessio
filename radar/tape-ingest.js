// /radar/tape-ingest — the write path for the Railway tape host (board row 90).
//
// The PumpPortal subscriber moved off the Durable Object to a host that can
// hold a socket (tape/); its engine emits effect objects whose `p` arrays bind
// 1:1 to the statements below — the SAME SQL radar/pumptape.ts executed, so
// every existing query over earlies/early_cycles reads identically. This route
// only authenticates, validates shape, and executes; it authors nothing.
//
// AUTH: bearer TAPE_INGEST_TOKEN (Worker secret; same value lives on the
// Railway service). Unset => 503, the route says it is not configured rather
// than silently accepting. Wrong/missing bearer => 401, no detail.
//
// Kept dependency-free and framework-free ON PURPOSE: the root test suite
// (node 22, no radar deps) imports this file directly, so the gate that runs
// on every PR exercises this exact code.
"use strict";

// Whitelist: effect kind -> the exact statement + arity. Nothing else executes.
export const TAPE_SQL = {
  hit: {
    params: 15,
    sql: `INSERT INTO earlies
           (token_address, symbol, name, first_hit_ms, first_hit_mc, age_sec_at_hit,
            status, ws, t4k_ms, buys_hit, sells_hit, sol_net_hit, uniq_buyers_hit,
            top_buyer_share, play_outcome, play_exit_mc, play_outcome_ms)
         VALUES (?1,?2,?3,?4,?5,?6,'watching',1,?7,?8,?9,?10,?11,?12,?13,?14,?15)
         ON CONFLICT(token_address) DO UPDATE SET
           ws=1, t4k_ms=?7, buys_hit=?8, sells_hit=?9, sol_net_hit=?10,
           uniq_buyers_hit=?11, top_buyer_share=?12`,
  },
  level1: {
    params: 5,
    sql: `UPDATE earlies SET play_outcome=?2, play_exit_mc=?3, play_outcome_ms=?4, rungs_filled=?5
          WHERE token_address=?1 AND play_outcome IS NULL`,
  },
  cycle: {
    params: 7,
    sql: `INSERT INTO early_cycles (token_address, level, outcome, entry_mc, exit_value, rungs_filled, ms)
          VALUES (?1,?2,?3,?4,?5,?6,?7)`,
  },
  headline: {
    params: 3,
    sql: `UPDATE earlies SET levels=?2, compound_mult=?3 WHERE token_address=?1`,
  },
};

const MAX_EFFECTS = 500;

function constEq(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  const len = Math.max(a.length, b.length);
  let diff = a.length === b.length ? 0 : 1;
  for (let i = 0; i < len; i++) diff |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  return diff === 0;
}

function validParam(v) {
  if (v === null) return true;
  if (typeof v === "number") return Number.isFinite(v);
  if (typeof v === "string") return v.length <= 200;
  return false;
}

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });

/**
 * @param request  the incoming POST
 * @param env      { RADAR_DB, TAPE_INGEST_TOKEN }
 * @param recordScan  (env, scan, ms, err) => Promise — index.ts's feed_status
 *        writer, injected so the tape lands on the SAME health surface the
 *        console already reads (the row 90 status came from that surface).
 */
export async function handleTapeIngest(request, env, recordScan) {
  if (!env.TAPE_INGEST_TOKEN) return json({ error: "INGEST_NOT_CONFIGURED" }, 503);
  const auth = request.headers.get("authorization") || "";
  const bearer = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!constEq(bearer, env.TAPE_INGEST_TOKEN)) return json({ error: "UNAUTHORIZED" }, 401);

  let body;
  try { body = await request.json(); } catch { return json({ error: "BAD_JSON" }, 400); }
  const effects = Array.isArray(body?.effects) ? body.effects : [];
  if (effects.length > MAX_EFFECTS) return json({ error: "TOO_MANY_EFFECTS", max: MAX_EFFECTS }, 400);

  const stmts = [];
  for (const eff of effects) {
    const def = TAPE_SQL[eff?.k];
    if (!def) return json({ error: "UNKNOWN_EFFECT", k: String(eff?.k).slice(0, 40) }, 400);
    if (!Array.isArray(eff.p) || eff.p.length !== def.params || !eff.p.every(validParam)) {
      return json({ error: "BAD_PARAMS", k: eff.k }, 400);
    }
    stmts.push(env.RADAR_DB.prepare(def.sql).bind(...eff.p));
  }

  const ms = Date.now();
  try {
    if (stmts.length) await env.RADAR_DB.batch(stmts);
  } catch (e) {
    await recordScan(env, "pumptapeTrades", ms, e);
    return json({ error: "D1_WRITE_FAILED" }, 500);
  }

  // The heartbeat: the remote tape's own health verdict lands in feed_status
  // verbatim — same fingerprints as the DO era (socket_down / trades_unsubscribed /
  // trade_stream_dead), same console surface. "ok" clears the row.
  const h = body?.health;
  const healthy = h && h.status === "ok";
  await recordScan(env, "pumptapeTrades", ms,
    healthy || !h ? null : new Error(`${h.status}: ${h.detail || ""}`));

  return json({ ok: true, applied: stmts.length });
}
