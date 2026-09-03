import { NextResponse } from "next/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const MAX_RPC_BODY_BYTES = 64 * 1024;
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
  "eth_getUncleByBlockHashAndIndex",
  "eth_getUncleByBlockNumberAndIndex",
  "eth_getUncleCountByBlockHash",
  "eth_getUncleCountByBlockNumber",
  "net_version",
  "web3_clientVersion",
]);

const PUBLIC_SEPOLIA_RPCS = [
  "https://ethereum-sepolia-rpc.publicnode.com",
  "https://rpc.sepolia.org",
  "https://sepolia.drpc.org",
];

function rpcCandidates() {
  return Array.from(new Set([
    process.env.SEPOLIA_RPC_URL,
    process.env.RPC_URL,
    ...PUBLIC_SEPOLIA_RPCS,
  ].filter((value): value is string => Boolean(value))));
}

function errorResponse(message: string, status = 400) {
  return NextResponse.json(
    { jsonrpc: "2.0", error: { code: -32600, message }, id: null },
    { status, headers: { "cache-control": "no-store" } },
  );
}

function isAllowedRpcPayload(payload: unknown): boolean {
  const requests = Array.isArray(payload) ? payload : [payload];
  if (requests.length === 0) return false;
  return requests.every((item) => {
    if (item === null || typeof item !== "object") return false;
    const request = item as { jsonrpc?: unknown; method?: unknown };
    return request.jsonrpc === "2.0" && typeof request.method === "string" && READ_ONLY_METHODS.has(request.method);
  });
}

export async function POST(request: Request) {
  const declaredLength = Number(request.headers.get("content-length") ?? 0);
  if (declaredLength > MAX_RPC_BODY_BYTES) return errorResponse("RPC request body is too large.", 413);

  const body = await request.text();
  if (new TextEncoder().encode(body).byteLength > MAX_RPC_BODY_BYTES) return errorResponse("RPC request body is too large.", 413);

  let payload: unknown;
  try {
    payload = JSON.parse(body);
  } catch {
    return errorResponse("RPC request must contain valid JSON.");
  }
  if (!isAllowedRpcPayload(payload)) return errorResponse("Only read-only Sepolia JSON-RPC methods are available through this route.", 403);

  let lastError = "RPC provider is unavailable";
  for (const rpcUrl of rpcCandidates()) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 8_000);
    try {
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
        message: `${lastError}. Configure SEPOLIA_RPC_URL on the server if public fallbacks are unavailable.`,
      },
      id: null,
    },
    { status: 502, headers: { "cache-control": "no-store" } },
  );
}
