import { NextResponse } from "next/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const rpcUrl = process.env.SEPOLIA_RPC_URL ?? process.env.RPC_URL ?? "https://ethereum-sepolia-rpc.publicnode.com";

  try {
    const body = await request.text();
    const upstream = await fetch(rpcUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body,
      cache: "no-store",
    });

    const responseBody = await upstream.text();
    return new NextResponse(responseBody, {
      status: upstream.status,
      headers: { "content-type": "application/json" },
    });
  } catch {
    return NextResponse.json(
      {
        jsonrpc: "2.0",
        error: {
          code: -32000,
          message: "RPC provider is unavailable. Configure SEPOLIA_RPC_URL on the server.",
        },
        id: null,
      },
      { status: 502 },
    );
  }
}
