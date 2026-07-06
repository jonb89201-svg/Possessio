// Possessio Solana MCP - remote MCP server (streamable HTTP) on Cloudflare
// Workers. READ-ONLY plane: proxies an allowlisted subset of Solana JSON-RPC
// to the QuickNode endpoint (SOLANA_RPC secret) plus Jupiter GET /quote.
// No signing, no sendTransaction, no keys beyond the RPC URL - and that URL
// never leaves the worker.
//
// Auth = capability URL: every route lives under /<ACCESS_KEY>/. claude.ai
// custom connectors support OAuth-or-nothing (no static bearer field), so
// the key rides in the connector URL instead of a header. ACCESS_KEY must be
// long random (>= 32 chars); rotate by re-setting the secret. Wrong or
// missing key gets a bare 404 - the worker never confirms it exists.
//
// Secrets (wrangler secret put): SOLANA_RPC, ACCESS_KEY.
// Optional var: JUPITER_BASE (default https://public.jupiterapi.com - the
// public mirror injects ~20bps platform fee; quote-only here, RULEBOOK Sec5
// note still applies to any net-return math built on it).
"use strict";

const SERVER_INFO = { name: "possessio-solana-mcp", version: "0.1.0" };
const PROTOCOL_VERSIONS = ["2024-11-05", "2025-03-26", "2025-06-18"];
const LATEST_PROTOCOL = "2025-06-18";
const MAX_SLIPPAGE_BPS = 200; // LAW ceiling (config.js) - quotes stay consistent with it

// Solana JSON-RPC methods this plane will forward. Read-only by construction:
// nothing here can submit a transaction or move funds (simulateTransaction
// executes nothing on-chain).
const READ_METHODS = new Set([
  "getAccountInfo", "getBalance", "getBlock", "getBlockHeight",
  "getBlockProduction", "getBlockTime", "getBlocks", "getBlocksWithLimit",
  "getClusterNodes", "getEpochInfo", "getEpochSchedule", "getFeeForMessage",
  "getFirstAvailableBlock", "getGenesisHash", "getHealth",
  "getHighestSnapshotSlot", "getIdentity", "getInflationGovernor",
  "getInflationRate", "getInflationReward", "getLargestAccounts",
  "getLatestBlockhash", "getLeaderSchedule", "getMaxRetransmitSlot",
  "getMaxShredInsertSlot", "getMinimumBalanceForRentExemption",
  "getMultipleAccounts", "getProgramAccounts", "getRecentPerformanceSamples",
  "getRecentPrioritizationFees", "getSignatureStatuses",
  "getSignaturesForAddress", "getSlot", "getSlotLeader", "getSlotLeaders",
  "getStakeMinimumDelegation", "getSupply", "getTokenAccountBalance",
  "getTokenAccountsByDelegate", "getTokenAccountsByOwner",
  "getTokenLargestAccounts", "getTokenSupply", "getTransaction",
  "getTransactionCount", "getVersion", "getVoteAccounts", "isBlockhashValid",
  "minimumLedgerSlot", "simulateTransaction",
]);

const TOOLS = [
  {
    name: "solana_rpc_request",
    description:
      "Read-only Solana mainnet JSON-RPC via the project's QuickNode endpoint. " +
      "Allowlisted read methods only (getHealth, getSlot, getBalance, " +
      "getAccountInfo, getTransaction, getTokenAccountsByOwner, ...). " +
      "Transaction submission is rejected.",
    inputSchema: {
      type: "object",
      properties: {
        method: { type: "string", description: "Solana JSON-RPC method name (read-only allowlist)" },
        params: { type: "array", description: "JSON-RPC params array (default [])" },
      },
      required: ["method"],
    },
  },
  {
    name: "jupiter_quote",
    description:
      "Live Jupiter aggregator quote (GET /quote, read-only - nothing is " +
      "signed or sent). Mirrors mcp/xtrade/adapters/jupiter.js param names. " +
      "amountAtomic is in the input mint's smallest units.",
    inputSchema: {
      type: "object",
      properties: {
        inputMint: { type: "string", description: "input token mint address" },
        outputMint: { type: "string", description: "output token mint address" },
        amountAtomic: { type: "string", description: "input amount, atomic units (string)" },
        slippageBps: { type: "number", description: "slippage bps (default 50, capped at " + MAX_SLIPPAGE_BPS + ")" },
      },
      required: ["inputMint", "outputMint", "amountAtomic"],
    },
  },
];

// Constant-time-ish key compare (length leak is fine for a random 32+ char key).
function keyMatches(given, expected) {
  const enc = new TextEncoder();
  const a = enc.encode(given), b = enc.encode(expected);
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

async function solanaRpc(env, method, params) {
  if (!READ_METHODS.has(method)) {
    throw new Error("method not allowed on this read-only plane: " + method);
  }
  const r = await fetch(env.SOLANA_RPC, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params: params || [] }),
  });
  if (!r.ok) throw new Error("solana rpc HTTP " + r.status);
  const j = await r.json();
  if (j.error) throw new Error("solana rpc error: " + JSON.stringify(j.error));
  return j.result;
}

async function jupiterQuote(env, { inputMint, outputMint, amountAtomic, slippageBps }) {
  const base = env.JUPITER_BASE || "https://public.jupiterapi.com";
  const bps = Math.min(Number(slippageBps) > 0 ? Number(slippageBps) : 50, MAX_SLIPPAGE_BPS);
  const u = new URL(base + "/quote");
  u.searchParams.set("inputMint", String(inputMint));
  u.searchParams.set("outputMint", String(outputMint));
  u.searchParams.set("amount", String(amountAtomic));
  u.searchParams.set("slippageBps", String(bps));
  const r = await fetch(u, { headers: { accept: "application/json" } });
  if (!r.ok) throw new Error("jupiter quote " + r.status);
  return r.json();
}

async function callTool(env, name, args) {
  if (name === "solana_rpc_request") {
    return solanaRpc(env, args && args.method, args && args.params);
  }
  if (name === "jupiter_quote") {
    return jupiterQuote(env, args || {});
  }
  throw new Error("unknown tool: " + name);
}

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function rpcResult(id, result) { return jsonResponse({ jsonrpc: "2.0", id, result }); }
function rpcError(id, code, message, status = 200) {
  return jsonResponse({ jsonrpc: "2.0", id: id === undefined ? null : id, error: { code, message } }, status);
}

async function handleMcp(env, msg) {
  const { id, method, params } = msg;
  const isNotification = id === undefined || id === null;

  if (isNotification) return new Response(null, { status: 202 }); // e.g. notifications/initialized

  switch (method) {
    case "initialize": {
      const asked = params && params.protocolVersion;
      const protocolVersion = PROTOCOL_VERSIONS.includes(asked) ? asked : LATEST_PROTOCOL;
      return rpcResult(id, {
        protocolVersion,
        capabilities: { tools: {} },
        serverInfo: SERVER_INFO,
      });
    }
    case "ping":
      return rpcResult(id, {});
    case "tools/list":
      return rpcResult(id, { tools: TOOLS });
    case "tools/call": {
      const name = params && params.name;
      const args = (params && params.arguments) || {};
      try {
        const out = await callTool(env, name, args);
        return rpcResult(id, {
          content: [{ type: "text", text: JSON.stringify(out) }],
          isError: false,
        });
      } catch (e) {
        // Tool failures are results, not protocol errors (MCP spec).
        return rpcResult(id, {
          content: [{ type: "text", text: "error: " + (e && e.message || String(e)) }],
          isError: true,
        });
      }
    }
    default:
      return rpcError(id, -32601, "method not found: " + method);
  }
}

export default {
  async fetch(request, env) {
    if (!env.ACCESS_KEY || env.ACCESS_KEY.length < 16 || !env.SOLANA_RPC) {
      return jsonResponse({ error: "worker not configured (secrets missing)" }, 503);
    }

    const parts = new URL(request.url).pathname.split("/").filter(Boolean);
    // Expected shapes: /<key>/mcp and /<key>/health - anything else is 404.
    if (parts.length !== 2 || !keyMatches(parts[0], env.ACCESS_KEY)) {
      return new Response("not found", { status: 404 });
    }
    const route = parts[1];

    if (route === "health") {
      try {
        const health = await solanaRpc(env, "getHealth", []);
        return jsonResponse({ ok: health === "ok", upstream: health });
      } catch (e) {
        return jsonResponse({ ok: false, error: e.message }, 502);
      }
    }

    if (route !== "mcp") return new Response("not found", { status: 404 });
    if (request.method !== "POST") {
      // Stateless server: no GET event stream, no session to DELETE.
      return new Response("method not allowed", { status: 405, headers: { allow: "POST" } });
    }

    let msg;
    try { msg = await request.json(); } catch { return rpcError(null, -32700, "parse error", 400); }
    if (Array.isArray(msg)) return rpcError(null, -32600, "batching not supported", 400);
    if (!msg || typeof msg.method !== "string") return rpcError(msg && msg.id, -32600, "invalid request", 400);

    return handleMcp(env, msg);
  },
};
