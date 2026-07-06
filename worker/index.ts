// possessio Worker entry - routes /api/* to handlers, everything else falls
// through to the static console assets (./public via the ASSETS binding).
// Assets-first routing is Cloudflare's default for Workers+Assets, so every
// existing console path serves exactly as it did when this worker was
// assets-only; the script only ever sees requests no asset matches.
import { handleDrip } from "./drip-endpoint";

interface Env {
  ASSETS: Fetcher;
  DRIP_LIMITS: KVNamespace;
  POOL_ADDRESS: `0x${string}`;
  USDC_ADDRESS: `0x${string}`;
  BASE_SEPOLIA_RPC: string;
  TESTNET_OPERATOR_PK: `0x${string}`;
}

const ZERO = "0x0000000000000000000000000000000000000000";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const { pathname } = new URL(request.url);

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
