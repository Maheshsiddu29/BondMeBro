/**
 * JSON-RPC request normalization for the read-only proxy.
 *
 * Pure, so the proxy's contract can be pinned by tests without a server or a network.
 *
 * The error CODES here are the point of this module. viem maps a JSON-RPC code onto a
 * user-visible class, and -32600 becomes "JSON is not a valid request object." An earlier
 * version of the proxy answered every rejection with -32600, so a rate-limited bond-history
 * scan surfaced in the product as a parse error that had nothing to do with the request.
 */

/** The subset of the JSON-RPC 2.0 error codes this proxy produces. */
export const JSON_RPC = {
  /** Malformed JSON. */
  PARSE_ERROR: -32700,
  /** Valid JSON, but not a valid Request object. */
  INVALID_REQUEST: -32600,
  /** The method is not exposed by this proxy. */
  METHOD_NOT_FOUND: -32601,
  /** The method is allowed but these params are not. */
  INVALID_PARAMS: -32602,
  /** Proxy or upstream failure. */
  INTERNAL: -32603,
  /** Rate limited. NOT -32600. */
  LIMIT_EXCEEDED: -32005,
} as const;

export type RpcId = string | number | null;

export type NormalizedRpcRequest = {
  id: RpcId;
  method: string;
  params: unknown[];
};

export type RpcErrorObject = {
  jsonrpc: "2.0";
  id: RpcId;
  error: { code: number; message: string };
};

export type NormalizedEntry = { request: NormalizedRpcRequest } | { error: RpcErrorObject };

export type NormalizedBody = {
  isBatch: boolean;
  entries: NormalizedEntry[];
  /** Set when the whole body is unusable; entries is then empty. */
  fatal?: RpcErrorObject;
};

/** Builds a JSON-RPC error object that PRESERVES the caller's request id. */
export function rpcErrorFor(id: RpcId, code: number, message: string): RpcErrorObject {
  return { jsonrpc: "2.0", id, error: { code, message } };
}

export const MAX_BATCH_REQUESTS = 50;
export const MAX_LOG_RANGE = 10_000n;

/** Everything the dashboard reads. Nothing that can change state. */
export const READ_ONLY_METHODS = new Set([
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

function isHexQuantity(value: unknown): value is string {
  return typeof value === "string" && /^0x[0-9a-f]+$/i.test(value);
}

/** Log queries are restricted to the configured hook and a bounded block range. */
export function logFilterProblem(params: unknown[], hookAddress: string): string | undefined {
  if (params.length < 1 || params[0] === null || typeof params[0] !== "object") {
    return "eth_getLogs requires a filter object.";
  }
  const filter = params[0] as { address?: unknown; fromBlock?: unknown; toBlock?: unknown; blockHash?: unknown };

  const addresses = Array.isArray(filter.address) ? filter.address : [filter.address];
  if (addresses.some((a) => typeof a !== "string" || a.toLowerCase() !== hookAddress)) {
    return "eth_getLogs is restricted to the configured hook address.";
  }

  if (filter.blockHash !== undefined) return undefined;

  if (!isHexQuantity(filter.fromBlock) || !isHexQuantity(filter.toBlock)) {
    return "eth_getLogs requires hex fromBlock and toBlock.";
  }

  try {
    const from = BigInt(filter.fromBlock);
    const to = BigInt(filter.toBlock);
    if (to < from) return "eth_getLogs toBlock is before fromBlock.";
    if (to - from > MAX_LOG_RANGE) return `eth_getLogs range exceeds ${MAX_LOG_RANGE} blocks.`;
  } catch {
    return "eth_getLogs block range could not be read.";
  }

  return undefined;
}

/**
 * Normalizes one item into the canonical request shape, or into a per-item error.
 *
 * `params` is optional on the wire and becomes `[]`, which is what a well-formed upstream
 * request needs. A valid request is never reshaped into an invalid one.
 */
export function normalizeItem(raw: unknown, hookAddress: string): NormalizedEntry {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
    return { error: rpcErrorFor(null, JSON_RPC.INVALID_REQUEST, "Request must be a JSON object.") };
  }

  const item = raw as { jsonrpc?: unknown; id?: unknown; method?: unknown; params?: unknown };

  const id: RpcId =
    typeof item.id === "string" || typeof item.id === "number" ? item.id : item.id === null ? null : null;

  if (item.jsonrpc !== "2.0") {
    return { error: rpcErrorFor(id, JSON_RPC.INVALID_REQUEST, "jsonrpc must be \"2.0\".") };
  }

  if (typeof item.method !== "string" || item.method.length === 0) {
    return { error: rpcErrorFor(id, JSON_RPC.INVALID_REQUEST, "method must be a non-empty string.") };
  }

  if (item.params !== undefined && item.params !== null && !Array.isArray(item.params)) {
    return { error: rpcErrorFor(id, JSON_RPC.INVALID_REQUEST, "params must be an array when present.") };
  }

  const params: unknown[] = Array.isArray(item.params) ? item.params : [];

  if (!READ_ONLY_METHODS.has(item.method)) {
    return {
      error: rpcErrorFor(
        id,
        JSON_RPC.METHOD_NOT_FOUND,
        `Method ${item.method} is not available through this read-only proxy.`,
      ),
    };
  }

  if (item.method === "eth_getLogs") {
    const problem = logFilterProblem(params, hookAddress);
    if (problem) return { error: rpcErrorFor(id, JSON_RPC.INVALID_PARAMS, problem) };
  }

  return { request: { id, method: item.method, params } };
}

/**
 * Parses and normalizes a whole request body.
 *
 * A batch arrives as an array and leaves as an array of entries in the SAME ORDER, so the
 * caller can recombine responses positionally while every id is preserved.
 */
export function normalizeRpcBody(rawBody: string, hookAddress: string): NormalizedBody {
  let parsed: unknown;
  try {
    parsed = JSON.parse(rawBody);
  } catch {
    return {
      isBatch: false,
      entries: [],
      fatal: rpcErrorFor(null, JSON_RPC.PARSE_ERROR, "Request body is not valid JSON."),
    };
  }

  if (Array.isArray(parsed)) {
    if (parsed.length === 0) {
      return {
        isBatch: true,
        entries: [],
        fatal: rpcErrorFor(null, JSON_RPC.INVALID_REQUEST, "A batch must contain at least one request."),
      };
    }
    if (parsed.length > MAX_BATCH_REQUESTS) {
      return {
        isBatch: true,
        entries: [],
        fatal: rpcErrorFor(
          null,
          JSON_RPC.INVALID_REQUEST,
          `A batch may contain at most ${MAX_BATCH_REQUESTS} requests.`,
        ),
      };
    }
    return { isBatch: true, entries: parsed.map((item) => normalizeItem(item, hookAddress)) };
  }

  return { isBatch: false, entries: [normalizeItem(parsed, hookAddress)] };
}
