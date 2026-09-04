import { NextResponse } from "next/server";

import {
  JSON_RPC,
  normalizeRpcBody,
  rpcErrorFor,
  type NormalizedRpcRequest,
} from "@/lib/rpcProxy";

/**
 * Read-only JSON-RPC proxy.
 *
 * Three properties matter here, beyond keeping provider keys off the client:
 *
 *  1. THE ERROR CODE MUST BE TRUE. This proxy previously answered every rejection —
 *     including its own rate limit — with JSON-RPC code -32600. viem renders -32600 as
 *     "JSON is not a valid request object.", so a throttled bond-history scan surfaced in
 *     the product as a nonsense parse error. Each condition now returns its own code.
 *
 *  2. IDS MUST SURVIVE. viem matches concurrent responses by id, so a request-scoped error
 *     carries that request's id rather than null.
 *
 *  3. BATCHES ARE FANNED OUT. Incoming arrays are normalized and forwarded as individual
 *     upstream POSTs, then recombined in order. The proxy therefore does not depend on the
 *     upstream supporting batch payloads at all.
 *
 * The upstream endpoint is also verified to be the configured chain before anything is
 * returned, so wrong-chain data can never be rendered under this network's label.
 */
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const MAX_RPC_BODY_BYTES = 512 * 1024;
const RATE_WINDOW_MS = 60_000;
const CHAIN_VERIFY_TTL_MS = 5 * 60_000;

/** How many upstream requests one fanned-out batch may have in flight. */
const FANOUT_CONCURRENCY = 8;

/**
 * Requests per minute per client.
 *
 * The demo UI legitimately makes well over a hundred reads a minute: a two-second block
 * poll, a two-second reconciliation of each visible bond, a five-second quote, and balance
 * and allowance reads. The old ceiling of 120 was below that floor, so the app throttled
 * itself. Override with RPC_RATE_LIMIT.
 */
const RATE_LIMIT = Number(process.env.RPC_RATE_LIMIT ?? 1_200);

const HOOK_ADDRESS = process.env.NEXT_PUBLIC_HOOK_ADDRESS?.toLowerCase();
const EXPECTED_CHAIN_ID = process.env.NEXT_PUBLIC_CHAIN_ID ? Number(process.env.NEXT_PUBLIC_CHAIN_ID) : undefined;

const DEV = process.env.NODE_ENV !== "production";

const rateBuckets = new Map<string, { startedAt: number; count: number }>();
const verifiedChains = new Map<string, { chainId: number; checkedAt: number }>();

function rpcCandidates() {
  // No public fallback list is shipped: a hardcoded endpoint would silently resurrect a
  // stale network assumption.
  return Array.from(
    new Set([process.env.RPC_URL, process.env.NEXT_PUBLIC_RPC_URL].filter((value): value is string => Boolean(value))),
  );
}

function clientIdentity(request: Request) {
  return (
    request.headers.get("x-forwarded-for")?.split(",")[0]?.trim()
    || request.headers.get("x-real-ip")
    || "unknown"
  );
}

/**
 * One INCOMING HTTP request counts as one unit, whatever it fans out to.
 *
 * Counting per fanned-out call would make a single legitimate batch consume a client's whole
 * budget and reintroduce the throttling this change exists to remove.
 */
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

/** Forwards ONE normalized request upstream and returns its JSON-RPC response object. */
async function forwardOne(rpcUrl: string, req: NormalizedRpcRequest): Promise<unknown> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10_000);
  try {
    const upstream = await fetch(rpcUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: req.id, method: req.method, params: req.params }),
      cache: "no-store",
      signal: controller.signal,
    });

    if (!upstream.ok) {
      if (DEV) console.warn(`[rpc] ${req.method} upstream HTTP ${upstream.status}`);
      return rpcErrorFor(req.id, JSON_RPC.INTERNAL, `Upstream returned HTTP ${upstream.status}.`);
    }

    const body = (await upstream.json()) as unknown;

    // A single-request POST may still be answered with a one-element array.
    const item = Array.isArray(body) ? body[0] : body;
    if (item === undefined || item === null) {
      return rpcErrorFor(req.id, JSON_RPC.INTERNAL, "Upstream returned an empty response.");
    }

    if (DEV) {
      const err = (item as { error?: { code?: number; message?: string } }).error;
      if (err) console.warn(`[rpc] ${req.method} -> error ${err.code}: ${err.message}`);
    }

    // Force the id back to the one the caller used. An upstream that echoes a different id
    // would otherwise break viem's response matching.
    return { ...(item as Record<string, unknown>), id: req.id };
  } catch {
    if (DEV) console.warn(`[rpc] ${req.method} upstream unreachable`);
    return rpcErrorFor(req.id, JSON_RPC.INTERNAL, "Upstream timed out or is unavailable.");
  } finally {
    clearTimeout(timeout);
  }
}

/** Fans a normalized batch out to individual upstream calls, bounded in flight. */
async function forwardAll(rpcUrl: string, requests: NormalizedRpcRequest[]): Promise<unknown[]> {
  const results: unknown[] = new Array(requests.length);
  let cursor = 0;

  async function worker() {
    while (cursor < requests.length) {
      const index = cursor;
      cursor += 1;
      results[index] = await forwardOne(rpcUrl, requests[index]);
    }
  }

  await Promise.all(
    Array.from({ length: Math.min(FANOUT_CONCURRENCY, requests.length) }, () => worker()),
  );

  return results;
}

function json(body: unknown, status = 200) {
  return NextResponse.json(body, { status, headers: { "cache-control": "no-store" } });
}

export async function POST(request: Request) {
  if (!HOOK_ADDRESS || EXPECTED_CHAIN_ID === undefined) {
    return json(
      rpcErrorFor(
        null,
        JSON_RPC.INTERNAL,
        "DEPLOYMENT REQUIRED: NEXT_PUBLIC_CHAIN_ID and NEXT_PUBLIC_HOOK_ADDRESS must be configured.",
      ),
      503,
    );
  }

  if (isRateLimited(request)) {
    // -32005 is "limit exceeded". Reporting this as -32600 is what made a throttled scan
    // read as "JSON is not a valid request object" in the product.
    return json(rpcErrorFor(null, JSON_RPC.LIMIT_EXCEEDED, "RPC rate limit exceeded. Try again shortly."), 429);
  }

  const declaredLength = Number(request.headers.get("content-length") ?? 0);
  if (declaredLength > MAX_RPC_BODY_BYTES) {
    return json(rpcErrorFor(null, JSON_RPC.INVALID_REQUEST, "RPC request body is too large."), 413);
  }

  const raw = await request.text();
  if (new TextEncoder().encode(raw).byteLength > MAX_RPC_BODY_BYTES) {
    return json(rpcErrorFor(null, JSON_RPC.INVALID_REQUEST, "RPC request body is too large."), 413);
  }

  const normalized = normalizeRpcBody(raw, HOOK_ADDRESS);

  if (DEV) {
    console.info(
      `[rpc] ${normalized.isBatch ? "batch" : "single"} n=${normalized.entries.length} `
        + `methods=[${normalized.entries.map((e) => ("request" in e ? e.request.method : "invalid")).join(",")}] `
        + `ids=[${normalized.entries.map((e) => String("request" in e ? e.request.id : e.error.id)).join(",")}]`,
    );
  }

  if (normalized.fatal) return json(normalized.fatal, 200);

  const candidates = rpcCandidates();
  if (candidates.length === 0) {
    return json(
      rpcErrorFor(null, JSON_RPC.INTERNAL, `DEPLOYMENT REQUIRED: set RPC_URL for chain ${EXPECTED_CHAIN_ID}.`),
      503,
    );
  }

  // Requests rejected locally never reach the network; the rest are forwarded one by one.
  const forwardable = normalized.entries.flatMap((entry) => ("request" in entry ? [entry.request] : []));

  let answers: unknown[] = [];
  if (forwardable.length > 0) {
    let chosen: string | undefined;
    for (const rpcUrl of candidates) {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 8_000);
      try {
        if (await upstreamChainMatches(rpcUrl, controller.signal)) {
          chosen = rpcUrl;
          break;
        }
      } catch {
        // Try the next candidate.
      } finally {
        clearTimeout(timeout);
      }
    }

    if (!chosen) {
      const message = `No configured RPC endpoint is serving chain ${EXPECTED_CHAIN_ID}.`;
      answers = forwardable.map((req) => rpcErrorFor(req.id, JSON_RPC.INTERNAL, message));
    } else {
      answers = await forwardAll(chosen, forwardable);
    }
  }

  // Recombine in the caller's original order, interleaving locally rejected entries.
  let answerIndex = 0;
  const responses = normalized.entries.map((entry) =>
    "request" in entry ? answers[answerIndex++] : entry.error,
  );

  return json(normalized.isBatch ? responses : responses[0], 200);
}
