// drip-endpoint.ts — reference implementation for the `possessio` Worker
// Route: POST /api/testnet/drip   Body: { "address": "0x...", "asset": "eth" | "usdc" }
//
// Chain of custody: console button -> this endpoint -> pool.drawEth/drawToken
// The Worker key holds ONLY OPERATOR_ROLE on the testnet pool. Blast radius if it
// leaks: testnet ETH/USDC drained at stipend rate, on 84532, nothing else. It is a
// throwaway key — never the wave PK, never anything mainnet-privileged.
//
// Bindings required in wrangler config (Claude Code wires these):
//   [[kv_namespaces]]
//   binding = "DRIP_LIMITS"
//   id = "49f2f2c858424605a9e90efc11e5e5f7"   // possessio-testnet-drip-limits (provisioned)
//
//   [vars]
//   POOL_ADDRESS = "0x..."                     // filled after pool deploy
//   USDC_ADDRESS = "0x036CbD53842c5426634e7929541eC2318f3dCF7e"
//   BASE_SEPOLIA_RPC = "https://sepolia.base.org"  // or a QuickNode Base Sepolia endpoint
//
// Secret (Architect sets it, never chat/repo):
//   wrangler secret put TESTNET_OPERATOR_PK
//
// deps: viem (runs fine in Workers)

import {
  createWalletClient,
  createPublicClient,
  http,
  isAddress,
  BaseError,
  ContractFunctionRevertedError,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { baseSepolia } from "viem/chains";

const POOL_ABI = [
  {
    type: "function",
    name: "drawEth",
    stateMutability: "nonpayable",
    inputs: [{ name: "to", type: "address" }],
    outputs: [],
  },
  {
    type: "function",
    name: "drawToken",
    stateMutability: "nonpayable",
    inputs: [
      { name: "token", type: "address" },
      { name: "to", type: "address" },
    ],
    outputs: [],
  },
  { type: "error", name: "PoolEmpty", inputs: [] },
  {
    type: "error",
    name: "CooldownActive",
    inputs: [{ name: "readyAt", type: "uint256" }],
  },
  { type: "error", name: "TokenNotEnabled", inputs: [{ name: "token", type: "address" }] },
] as const;

const COOLDOWN_SECS = 12 * 60 * 60; // keep in lockstep with the contract's cooldownSecs
const ALLOWED_ORIGIN = "https://possessio.io";

interface Env {
  DRIP_LIMITS: KVNamespace;
  POOL_ADDRESS: `0x${string}`;
  USDC_ADDRESS: `0x${string}`;
  BASE_SEPOLIA_RPC: string;
  TESTNET_OPERATOR_PK: `0x${string}`;
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json",
      "access-control-allow-origin": ALLOWED_ORIGIN,
    },
  });
}

export async function handleDrip(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") return json(405, { error: "POST only" });

  let body: { address?: string; asset?: string };
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "invalid JSON" });
  }

  const to = body.address ?? "";
  const asset = (body.asset ?? "eth").toLowerCase();
  if (!isAddress(to)) return json(400, { error: "invalid address" });
  if (asset !== "eth" && asset !== "usdc") return json(400, { error: "asset must be eth|usdc" });

  // Belt: KV rate limit per (asset, address) and per (asset, IP).
  // Suspenders: the contract enforces its own cooldown regardless of this layer.
  const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
  const addrKey = `drip:${asset}:${to.toLowerCase()}`;
  const ipKey = `drip:${asset}:ip:${ip}`;
  const [addrHit, ipHit] = await Promise.all([
    env.DRIP_LIMITS.get(addrKey),
    env.DRIP_LIMITS.get(ipKey),
  ]);
  if (addrHit || ipHit) {
    return json(429, { error: "COOLDOWN_ACTIVE", layer: "worker" });
  }

  const account = privateKeyToAccount(env.TESTNET_OPERATOR_PK);
  const transport = http(env.BASE_SEPOLIA_RPC);
  const wallet = createWalletClient({ account, chain: baseSepolia, transport });
  const pub = createPublicClient({ chain: baseSepolia, transport });

  try {
    const { request: sim } = await pub.simulateContract({
      account,
      address: env.POOL_ADDRESS,
      abi: POOL_ABI,
      functionName: asset === "eth" ? "drawEth" : "drawToken",
      args: asset === "eth" ? [to] : [env.USDC_ADDRESS, to],
    });
    const txHash = await wallet.writeContract(sim);

    // Stamp KV only after a successful send; TTL mirrors the contract cooldown.
    await Promise.all([
      env.DRIP_LIMITS.put(addrKey, "1", { expirationTtl: COOLDOWN_SECS }),
      env.DRIP_LIMITS.put(ipKey, "1", { expirationTtl: COOLDOWN_SECS }),
    ]);

    return json(200, { txHash, asset, to });
  } catch (err) {
    // Surface the contract's honest reverts as honest API errors.
    if (err instanceof BaseError) {
      const revert = err.walk((e) => e instanceof ContractFunctionRevertedError);
      if (revert instanceof ContractFunctionRevertedError) {
        const name = revert.data?.errorName ?? "REVERTED";
        if (name === "PoolEmpty") {
          return json(503, {
            error: "POOL_EMPTY",
            hint: "Pool needs refilling — send Base Sepolia ETH/USDC to the pool address.",
          });
        }
        if (name === "CooldownActive") {
          return json(429, { error: "COOLDOWN_ACTIVE", layer: "chain" });
        }
        if (name === "TokenNotEnabled") {
          return json(503, { error: "TOKEN_NOT_ENABLED" });
        }
        return json(502, { error: name });
      }
    }
    return json(502, { error: "DRIP_FAILED" });
  }
}
