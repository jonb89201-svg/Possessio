// possessio Worker entry - routes /api/* to handlers, everything else falls
// through to the static console assets (./public via the ASSETS binding).
// Assets-first routing is Cloudflare's default for Workers+Assets, so every
// existing console path serves exactly as it did when this worker was
// assets-only; the script only ever sees requests no asset matches.
import { handleDrip } from "./drip-endpoint";
import { recoverTypedDataAddress, getAddress, isAddress } from "viem";

interface Env {
  ASSETS: Fetcher;
  DRIP_LIMITS: KVNamespace;
  POOL_ADDRESS: `0x${string}`;
  USDC_ADDRESS: `0x${string}`;
  BASE_SEPOLIA_RPC: string;
  TESTNET_OPERATOR_PK: `0x${string}`;
  COUNCIL_DB: D1Database;      // the council communication ledger (radar DB)
  COUNCIL_SEATS?: string;      // optional comma-separated seat allowlist
}

const ZERO = "0x0000000000000000000000000000000000000000";

const json = (obj: unknown, status = 200) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });

// Off-chain statement attribution — MUST match the connector's STATEMENT_DOMAIN
// (config.js). Deliberately has no verifyingContract so a statement signature can
// never be replayed as an on-chain vote.
const STATEMENT_DOMAIN = { name: "PossessioCouncilStatement", version: "1" } as const;
const STATEMENT_TYPES = {
  Statement: [
    { name: "body", type: "string" },
    { name: "nonce", type: "uint256" },
  ],
} as const;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const { pathname } = new URL(request.url);

    // Radar feed proxy — the AI Assisted Trading desk (public/index.html,
    // #desk-view) fetches its live coin list from here. The radar runs on a
    // separate worker with no CORS headers, so a browser fetch cross-origin
    // would be blocked; this same-origin proxy fetches it server-side. Read-
    // only passthrough of the public /radar/candidates JSON; 5s edge cache to
    // match the desk's poll cadence and shield the radar from fan-out.
    if (pathname === "/api/radar/candidates") {
      const RADAR = "https://possessio-radar.jonb89201.workers.dev/radar/candidates";
      try {
        const r = await fetch(RADAR, {
          cf: { cacheTtl: 5, cacheEverything: true },
        } as any);
        const body = await r.text();
        return new Response(body, {
          status: r.status,
          headers: { "content-type": "application/json", "cache-control": "no-store" },
        });
      } catch {
        return new Response(JSON.stringify({ error: "RADAR_UNREACHABLE" }), {
          status: 502,
          headers: { "content-type": "application/json" },
        });
      }
    }

    // Council communication ledger (SPEC_CouncilSigner_v3 §8). The end-to-end
    // channel: a seat POSTs a signed statement (over MCP or the console) -> we
    // verify the EIP-712 signature recovers to the claimed seat (and, if a seat
    // allowlist is configured, that it IS a seat) -> append to D1. GET is public
    // read (any seat / the console viewer polls it). Every row is attributable;
    // an unsigned or spoofed message never lands.
    if (pathname === "/api/council/ledger") {
      const db = env.COUNCIL_DB;
      if (!db) return json({ error: "COUNCIL_DB_UNBOUND" }, 503);

      if (request.method === "GET") {
        const since = Number(new URL(request.url).searchParams.get("since") || "0") || 0;
        const { results } = await db
          .prepare("SELECT id, ts_ms, seat, kind, body, nonce, signature, ref FROM council_ledger WHERE ts_ms > ?1 ORDER BY ts_ms ASC LIMIT 200")
          .bind(since)
          .all();
        return json({ rows: results || [] });
      }

      if (request.method === "POST") {
        let b: any;
        try { b = await request.json(); } catch { return json({ error: "BAD_JSON" }, 400); }
        const seat = b?.seat, body = b?.body, nonce = b?.nonce, signature = b?.signature;
        const kind = typeof b?.kind === "string" ? b.kind : "statement";
        const ref = typeof b?.ref === "string" ? b.ref : null;
        if (!seat || !isAddress(seat) || typeof body !== "string" || body.length === 0 || body.length > 8000 || nonce == null || typeof signature !== "string")
          return json({ error: "BAD_FIELDS" }, 400);

        let recovered: string;
        try {
          recovered = await recoverTypedDataAddress({
            domain: STATEMENT_DOMAIN,
            types: STATEMENT_TYPES,
            primaryType: "Statement",
            message: { body, nonce: BigInt(nonce) },
            signature: signature as `0x${string}`,
          });
        } catch { return json({ error: "BAD_SIGNATURE" }, 400); }
        if (getAddress(recovered) !== getAddress(seat)) return json({ error: "SIGNER_MISMATCH" }, 401);

        const allow = (env.COUNCIL_SEATS || "").split(",").map((s) => s.trim()).filter(Boolean)
          .map((s) => { try { return getAddress(s); } catch { return ""; } });
        if (allow.length && !allow.includes(getAddress(seat))) return json({ error: "NOT_A_SEAT" }, 403);

        const ts = Date.now();
        const r = await db
          .prepare("INSERT INTO council_ledger (ts_ms, seat, kind, body, nonce, signature, ref) VALUES (?1,?2,?3,?4,?5,?6,?7)")
          .bind(ts, getAddress(seat), kind, body, String(nonce), signature, ref)
          .run();
        return json({ ok: true, id: r.meta.last_row_id, ts_ms: ts });
      }
      return json({ error: "METHOD" }, 405);
    }

    if (pathname === "/api/testnet/drip") {
      const deployed = env.POOL_ADDRESS && env.POOL_ADDRESS.toLowerCase() !== ZERO;

      // GET = config read for the console's technical info layer (pool
      // address + the honest facts of the drip). No secrets, no state.
      if (request.method === "GET") {
        return new Response(
          JSON.stringify({
            pool: deployed ? env.POOL_ADDRESS : null,
            usdc: env.USDC_ADDRESS,
            chainId: 84532,
          }),
          { status: 200, headers: { "content-type": "application/json" } },
        );
      }

      // Pool not deployed yet (POOL_ADDRESS still the placeholder): answer
      // honestly instead of letting the RPC call fail opaquely.
      if (!deployed) {
        return new Response(JSON.stringify({ error: "POOL_NOT_DEPLOYED" }), {
          status: 503,
          headers: { "content-type": "application/json" },
        });
      }
      return handleDrip(request, env);
    }

    return env.ASSETS.fetch(request);
  },
};
