import { NextResponse } from "next/server";
import { headers } from "next/headers";
import { prisma } from "@/lib/prisma";
import { checkRateLimit, isValidSuiAddress } from "@/lib/rate-limit";

export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  const hdrs = await headers();
  const ip = hdrs.get("x-forwarded-for") ?? hdrs.get("x-real-ip") ?? "unknown";
  const { allowed } = checkRateLimit(`swaps:${ip}`, 30, 60_000);
  if (!allowed) {
    return NextResponse.json({ error: "Rate limit exceeded" }, { status: 429 });
  }

  const { searchParams } = new URL(request.url);
  const marketId = searchParams.get("marketId");
  const trader = searchParams.get("trader");
  const limit = Math.min(parseInt(searchParams.get("limit") || "50"), 200);
  const offset = parseInt(searchParams.get("offset") || "0");

  if (trader && !isValidSuiAddress(trader)) {
    return NextResponse.json({ error: "Invalid Sui address" }, { status: 400 });
  }

  try {
    const where: Record<string, unknown> = {};
    if (marketId) where.marketId = marketId;
    if (trader) where.trader = trader;

    const [swaps, total] = await Promise.all([
      prisma.swap.findMany({
        where,
        orderBy: { timestampMs: "desc" },
        take: limit,
        skip: offset,
        include: {
          market: {
            select: {
              underlyingSymbol: true,
              maturityMs: true,
              durationMonths: true,
            },
          },
        },
      }),
      prisma.swap.count({ where }),
    ]);

    return NextResponse.json({
      swaps: swaps.map((s) => ({
        id: s.id,
        txDigest: s.txDigest,
        marketId: s.marketId,
        poolId: s.poolId,
        trader: s.trader,
        direction: s.direction,
        amountIn: s.amountIn.toString(),
        amountOut: s.amountOut.toString(),
        fee: s.fee.toString(),
        impliedRate: Number(s.impliedRate) / 1e18,
        ptPrice: s.ptPrice,
        timestampMs: s.timestampMs.toString(),
        market: s.market,
      })),
      total,
      limit,
      offset,
    });
  } catch (error) {
    console.error("Failed to fetch swaps:", error);
    return NextResponse.json({ swaps: [], total: 0, limit, offset });
  }
}
