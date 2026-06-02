import { NextResponse } from "next/server";

export const dynamic = "force-dynamic";

/**
 * Server-side proxy to the Coinbase Paymaster (CDP). Keeps the paymaster URL +
 * any embedded key off the client; the browser points its paymasterService at
 * /api/paymaster. Forwards the ERC-4337 JSON-RPC body verbatim.
 */
export async function POST(req: Request) {
  const url = process.env.PAYMASTER_SERVICE_URL;
  if (!url) {
    return NextResponse.json({ error: "Paymaster is not configured" }, { status: 503 });
  }
  const bodyText = await req.text();
  try {
    const upstream = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: bodyText,
    });
    const text = await upstream.text();
    return new NextResponse(text, {
      status: upstream.status,
      headers: { "content-type": "application/json" },
    });
  } catch {
    return NextResponse.json({ error: "Paymaster upstream unreachable" }, { status: 502 });
  }
}
