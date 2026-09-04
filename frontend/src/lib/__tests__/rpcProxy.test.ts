import { describe, expect, it } from "vitest";

import {
  JSON_RPC,
  MAX_BATCH_REQUESTS,
  logFilterProblem,
  normalizeItem,
  normalizeRpcBody,
  rpcErrorFor,
} from "@/lib/rpcProxy";

const HOOK = "0x2a07b25994fde4c772f00d6b89e05e8ad62650c4";

function req(method: string, params: unknown[] = [], id: unknown = 1) {
  return JSON.stringify({ jsonrpc: "2.0", id, method, params });
}

/**
 * THE BUG THIS FILE EXISTS FOR.
 *
 * The proxy used to answer every rejection — including its own rate limit — with JSON-RPC
 * code -32600. viem renders -32600 as "JSON is not a valid request object.", so a throttled
 * bond-history scan surfaced in the product as a nonsense parse error. Codes are now
 * specific, and these tests pin each one.
 */
describe("error codes are truthful", () => {
  it("never uses -32600 for a rate limit", () => {
    const limited = rpcErrorFor(7, JSON_RPC.LIMIT_EXCEEDED, "RPC rate limit exceeded.");
    expect(limited.error.code).toBe(-32005);
    expect(limited.error.code).not.toBe(JSON_RPC.INVALID_REQUEST);
    // And it keeps the caller's id rather than collapsing to null.
    expect(limited.id).toBe(7);
  });

  it("uses -32700 for unparseable JSON", () => {
    const body = normalizeRpcBody("{not json", HOOK);
    expect(body.fatal?.error.code).toBe(JSON_RPC.PARSE_ERROR);
  });

  it("uses -32601 for a method this proxy does not expose", () => {
    const entry = normalizeItem(JSON.parse(req("eth_sendRawTransaction", ["0x00"])), HOOK);
    expect("error" in entry && entry.error.error.code).toBe(JSON_RPC.METHOD_NOT_FOUND);
  });

  it("uses -32602 for a disallowed eth_getLogs filter", () => {
    const entry = normalizeItem(
      JSON.parse(req("eth_getLogs", [{ address: "0x00000000000000000000000000000000000000ff", fromBlock: "0x1", toBlock: "0x2" }])),
      HOOK,
    );
    expect("error" in entry && entry.error.error.code).toBe(JSON_RPC.INVALID_PARAMS);
  });

  it("uses -32600 ONLY for a genuinely malformed request object", () => {
    for (const raw of [null, 42, "hello", [], { jsonrpc: "1.0", id: 1, method: "eth_chainId" }]) {
      const entry = normalizeItem(raw, HOOK);
      expect("error" in entry && entry.error.error.code).toBe(JSON_RPC.INVALID_REQUEST);
    }
  });
});

describe("single requests", () => {
  it("normalizes and preserves the id", () => {
    const body = normalizeRpcBody(req("eth_blockNumber", [], 42), HOOK);
    expect(body.isBatch).toBe(false);
    expect(body.entries).toHaveLength(1);
    const entry = body.entries[0];
    if (!("request" in entry)) throw new Error("expected a forwardable request");
    expect(entry.request).toEqual({ id: 42, method: "eth_blockNumber", params: [] });
  });

  it("supplies [] when params are omitted, without reshaping a valid request", () => {
    const entry = normalizeItem({ jsonrpc: "2.0", id: 1, method: "eth_blockNumber" }, HOOK);
    if (!("request" in entry)) throw new Error("expected a forwardable request");
    expect(entry.request.params).toEqual([]);
  });

  it("accepts a string id and a null id", () => {
    for (const id of ["abc", null]) {
      const body = normalizeRpcBody(req("eth_chainId", [], id), HOOK);
      const entry = body.entries[0];
      if (!("request" in entry)) throw new Error("expected a forwardable request");
      expect(entry.request.id).toBe(id);
    }
  });

  it("passes eth_call, eth_estimateGas and eth_getLogs", () => {
    const call = normalizeItem(JSON.parse(req("eth_call", [{ to: HOOK, data: "0x" }, "latest"])), HOOK);
    expect("request" in call).toBe(true);

    const estimate = normalizeItem(JSON.parse(req("eth_estimateGas", [{ to: HOOK, data: "0x" }])), HOOK);
    expect("request" in estimate).toBe(true);

    const logs = normalizeItem(
      JSON.parse(req("eth_getLogs", [{ address: HOOK, fromBlock: "0x3AC0000", toBlock: "0x3AC0064" }])),
      HOOK,
    );
    expect("request" in logs).toBe(true);
  });
});

describe("batches are normalized for fan-out", () => {
  const batch = JSON.stringify([
    { jsonrpc: "2.0", id: 1, method: "eth_blockNumber", params: [] },
    { jsonrpc: "2.0", id: "two", method: "eth_chainId" },
    { jsonrpc: "2.0", id: 3, method: "eth_call", params: [{ to: HOOK, data: "0x" }, "latest"] },
  ]);

  it("splits a batch into individually forwardable requests", () => {
    const body = normalizeRpcBody(batch, HOOK);
    expect(body.isBatch).toBe(true);
    expect(body.entries).toHaveLength(3);

    // Each entry is a SINGLE request object. Nothing here is an array, so the upstream is
    // never handed a raw batch payload.
    for (const entry of body.entries) {
      if (!("request" in entry)) throw new Error("expected a forwardable request");
      expect(Array.isArray(entry.request)).toBe(false);
      expect(typeof entry.request.method).toBe("string");
      expect(Array.isArray(entry.request.params)).toBe(true);
    }
  });

  it("preserves every id, in order", () => {
    const body = normalizeRpcBody(batch, HOOK);
    const ids = body.entries.map((entry) => ("request" in entry ? entry.request.id : entry.error.id));
    expect(ids).toEqual([1, "two", 3]);
  });

  it("rejects one bad item locally while forwarding the rest", () => {
    const mixed = JSON.stringify([
      { jsonrpc: "2.0", id: 1, method: "eth_blockNumber", params: [] },
      { jsonrpc: "2.0", id: 2, method: "eth_sendTransaction", params: [] },
      { jsonrpc: "2.0", id: 3, method: "eth_chainId", params: [] },
    ]);
    const body = normalizeRpcBody(mixed, HOOK);

    expect("request" in body.entries[0]).toBe(true);
    expect("error" in body.entries[1]).toBe(true);
    expect("request" in body.entries[2]).toBe(true);

    // The rejected item keeps its own id so the caller can match it.
    const rejected = body.entries[1];
    if (!("error" in rejected)) throw new Error("expected a local rejection");
    expect(rejected.error.id).toBe(2);
    expect(rejected.error.error.code).toBe(JSON_RPC.METHOD_NOT_FOUND);
  });

  it("refuses an empty batch and an oversized one", () => {
    expect(normalizeRpcBody("[]", HOOK).fatal?.error.code).toBe(JSON_RPC.INVALID_REQUEST);

    const huge = JSON.stringify(
      Array.from({ length: MAX_BATCH_REQUESTS + 1 }, (_, i) => ({
        jsonrpc: "2.0",
        id: i,
        method: "eth_chainId",
        params: [],
      })),
    );
    expect(normalizeRpcBody(huge, HOOK).fatal?.error.code).toBe(JSON_RPC.INVALID_REQUEST);
  });
});

describe("eth_getLogs stays bounded and hook-scoped", () => {
  it("allows the demo's own scan window", () => {
    expect(
      logFilterProblem([{ address: HOOK, fromBlock: "0x3AC0000", toBlock: "0x3AC270F" }], HOOK),
    ).toBeUndefined();
  });

  it("refuses another address", () => {
    expect(
      logFilterProblem([{ address: "0x00000000000000000000000000000000000000ff", fromBlock: "0x1", toBlock: "0x2" }], HOOK),
    ).toMatch(/configured hook/);
  });

  it("refuses an unbounded range", () => {
    expect(logFilterProblem([{ address: HOOK, fromBlock: "0x0", toBlock: "0xFFFFFF" }], HOOK)).toMatch(/exceeds/);
  });

  it("allows a blockHash filter", () => {
    expect(logFilterProblem([{ address: HOOK, blockHash: `0x${"11".repeat(32)}` }], HOOK)).toBeUndefined();
  });
});
