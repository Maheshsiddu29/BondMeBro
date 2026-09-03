import { NextResponse } from "next/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

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

export async function POST(request: Request) {
  const body = await request.text();
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
      // Try the next provider without exposing the configured RPC URL to the browser.
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
