import { NextResponse } from "next/server";

/**
 * Read-only JSON-RPC proxy.
 *
 * Two properties matter for correctness, beyond keeping provider keys off the client:
 *
 *  1. The upstream endpoint is VERIFIED to be the configured chain before any response is
 *     returned. A generic `RPC_URL` pointing at another chain used to be forwarded happily,
 *     which meant wrong-chain data could be rendered under this network's label.
 *  2. `eth_getLogs` is bounded and restricted to the configured hook address, which comes
 *     from the deployment manifest rather than a shipped default.
 */
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const MAX_RPC_BODY_BYTES = 64 * 1024;
const MAX_BATCH_REQUESTS = 20;
const MAX_LOG_RANGE = 10_000n;
const RATE_WINDOW_MS = 60_000;
const RATE_LIMIT = 120;
const CHAIN_VERIFY_TTL_MS = 5 * 60_000;

const HOOK_ADDRESS = process.env.NEXT_PUBLIC_HOOK_ADDRESS?.toLowerCase();
const EXPECTED_CHAIN_ID = process.env.NEXT_PUBLIC_CHAIN_ID ? Number(process.env.NEXT_PUBLIC_CHAIN_ID) : undefined;

const rateBuckets = new Map<string, { startedAt: number; count: number }>();
const verifiedChains = new Map<string, { chainId: number; checkedAt: number }>();

const READ_ONLY_METHODS = new Set([
  "eth_blockNumber",
  "eth_chainId",
  "eth_call",
  "eth_estimateGas",
  "eth_feeHistory",
  "eth_gasPrice",
  "eth_maxPriorityFeePerGas",
  "eth_getBalance",
  "eth_getBlockByHash",
  "eth_getBlockByNumber",
  "eth_getBlockTransactionCountByHash",
  "eth_getBlockTransactionCountByNumber",
  "eth_getCode",
  "eth_getLogs",
  "eth_getProof",
  "eth_getStorageAt",
  "eth_getTransactionByBlockHashAndIndex",
  "eth_getTransactionByBlockNumberAndIndex",
  "eth_getTransactionByHash",
  "eth_getTransactionCount",
  "eth_getTransactionReceipt",
  "net_version",
  "web3_clientVersion",
]);

function rpcCandidates() {
  // No public fallback list is shipped: a hardcoded Sepolia endpoint would silently
  // resurrect the stale network assumption this remediation removed.
  return Array.from(new Set([process.env.RPC_URL, process.env.NEXT_PUBLIC_RPC_URL].filter(
    (value): value is string => Boolean(value),
  )));
}

function errorResponse(message: string, status = 400) {
  return NextResponse.json(
    { jsonrpc: "2.0", error: { code: -32600, message }, id: null },
    { status, headers: { "cache-control": "no-store" } },
  );
}

function clientIdentity(request: Request) {
  return (
    request.headers.get("x-forwarded-for")?.split(",")[0]?.trim()
    || request.headers.get("x-real-ip")
    || "unknown"
  );
}

function isRateLimited(request: Request) {
  const now = Date.now();
  const identity = clientIdentity(request);
  const bucket = rateBuckets.get(identity);
  if (!bucket || now - bucket.startedAt >= RATE_WINDOW_MS) {
    if (rateBuckets.size >= 1_000) {
      for (const [key, value] of rateBuckets) {
        if (now - value.startedAt >= RATE_WINDOW_MS) rateBuckets.delete(key);
      }
      if (rateBuckets.size >= 1_000) {
        const oldestKey = rateBuckets.keys().next().value;
        if (typeof oldestKey === "string") rateBuckets.delete(oldestKey);
      }
    }
    rateBuckets.set(identity, { startedAt: now, count: 1 });
    return false;
  }
  bucket.count += 1;
  return bucket.count > RATE_LIMIT;
}

function isHexQuantity(value: unknown): value is string {
  return typeof value === "string" && /^0x[0-9a-f]+$/i.test(value);
}

function isAllowedLogFilter(params: unknown) {
  if (!HOOK_ADDRESS) return false;
  if (!Array.isArray(params) || params.length < 1 || params[0] === null || typeof params[0] !== "object") return false;
  const filter = params[0] as { address?: unknown; fromBlock?: unknown; toBlock?: unknown; blockHash?: unknown };
  const addresses = Array.isArray(filter.address) ? filter.address : [filter.address];
  if (addresses.some((address) => typeof address !== "string" || address.toLowerCase() !== HOOK_ADDRESS)) return false;
  if (filter.blockHash !== undefined) return true;
  if (
    filter.fromBlock === undefined
    || filter.toBlock === undefined
    || !isHexQuantity(filter.fromBlock)
    || !isHexQuantity(filter.toBlock)
  ) {
    return false;
  }
  try {
    return (
      BigInt(filter.toBlock) >= BigInt(filter.fromBlock)
      && BigInt(filter.toBlock) - BigInt(filter.fromBlock) <= MAX_LOG_RANGE
    );
  } catch {
    return false;
  }
}

function isAllowedRpcPayload(payload: unknown): boolean {
  const requests = Array.isArray(payload) ? payload : [payload];
  if (requests.length === 0 || requests.length > MAX_BATCH_REQUESTS) return false;
  return requests.every((item) => {
    if (item === null || typeof item !== "object") return false;
    const request = item as { jsonrpc?: unknown; method?: unknown; params?: unknown };
    if (request.jsonrpc !== "2.0" || typeof request.method !== "string" || !READ_ONLY_METHODS.has(request.method)) {
      return false;
    }
    return request.method !== "eth_getLogs" || isAllowedLogFilter(request.params);
  });
}

/** Confirms an upstream really is the configured chain, cached briefly per endpoint. */
async function upstreamChainMatches(rpcUrl: string, signal: AbortSignal): Promise<boolean> {
  if (EXPECTED_CHAIN_ID === undefined) return false;
  const cached = verifiedChains.get(rpcUrl);
  if (cached && Date.now() - cached.checkedAt < CHAIN_VERIFY_TTL_MS) {
    return cached.chainId === EXPECTED_CHAIN_ID;
  }
  const response = await fetch(rpcUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_chainId", params: [] }),
    cache: "no-store",
    signal,
  });
  if (!response.ok) return false;
  const payload = (await response.json()) as { result?: unknown };
  if (typeof payload.result !== "string") return false;
  const chainId = Number(BigInt(payload.result));
  verifiedChains.set(rpcUrl, { chainId, checkedAt: Date.now() });
  return chainId === EXPECTED_CHAIN_ID;
}

export async function POST(request: Request) {
  if (!HOOK_ADDRESS || EXPECTED_CHAIN_ID === undefined) {
    return errorResponse(
      "DEPLOYMENT REQUIRED: NEXT_PUBLIC_CHAIN_ID and NEXT_PUBLIC_HOOK_ADDRESS must be configured before this proxy will forward anything.",
      503,
    );
  }

  if (isRateLimited(request)) return errorResponse("RPC rate limit exceeded. Try again shortly.", 429);

  const declaredLength = Number(request.headers.get("content-length") ?? 0);
  if (declaredLength > MAX_RPC_BODY_BYTES) return errorResponse("RPC request body is too large.", 413);

  const body = await request.text();
  if (new TextEncoder().encode(body).byteLength > MAX_RPC_BODY_BYTES) {
    return errorResponse("RPC request body is too large.", 413);
  }

  let payload: unknown;
  try {
    payload = JSON.parse(body);
  } catch {
    return errorResponse("RPC request must contain valid JSON.");
  }
  if (!isAllowedRpcPayload(payload)) {
    return errorResponse("Only bounded, read-only JSON-RPC methods for the configured hook are available here.", 403);
  }

  const candidates = rpcCandidates();
  if (candidates.length === 0) {
    return errorResponse(
      "DEPLOYMENT REQUIRED: set RPC_URL on the server to an endpoint for the configured chain.",
      503,
    );
  }

  let lastError = "RPC provider is unavailable";
  for (const rpcUrl of candidates) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 8_000);
    try {
      if (!(await upstreamChainMatches(rpcUrl, controller.signal))) {
        lastError = `RPC provider is not chain ${EXPECTED_CHAIN_ID}`;
        continue;
      }
      const upstream = await fetch(rpcUrl, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body,
        cache: "no-store",
        signal: controller.signal,
      });
      const responseBody = await upstream.text();
      if (upstream.ok) {
        return new NextResponse(responseBody, {
          status: upstream.status,
          headers: { "content-type": "application/json", "cache-control": "no-store" },
        });
      }
      lastError = `RPC provider returned HTTP ${upstream.status}`;
    } catch {
      lastError = "RPC provider timed out or is unavailable";
    } finally {
      clearTimeout(timeout);
    }
  }

  return NextResponse.json(
    {
      jsonrpc: "2.0",
      error: {
        code: -32000,
        message: `${lastError}. Configure RPC_URL on the server with an endpoint for chain ${EXPECTED_CHAIN_ID}.`,
      },
      id: null,
    },
    { status: 502, headers: { "cache-control": "no-store" } },
  );
}
