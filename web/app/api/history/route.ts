import { NextResponse } from "next/server";
import { headers } from "next/headers";
import { prisma } from "@/lib/prisma";
import { checkRateLimit } from "@/lib/rate-limit";

export const dynamic = "force-dynamic";

/** Rate history for a specific market (for charts) */
export async function GET(request: Request) {
  const hdrs = await headers();
  const ip = hdrs.get("x-forwarded-for") ?? hdrs.get("x-real-ip") ?? "unknown";
  const { allowed } = checkRateLimit(`history:${ip}`, 30, 60_000);
  if (!allowed) {
    return NextResponse.json({ error: "Rate limit exceeded" }, { status: 429 });
  }

  const { searchParams } = new URL(request.url);
  const marketId = searchParams.get("marketId");
  const period = searchParams.get("period") || "7d"; // 1d, 7d, 30d, all
  const type = searchParams.get("type") || "rate"; // rate | volume | tvl

  if (!marketId) {
    return NextResponse.json({ error: "marketId required" }, { status: 400 });
  }

  try {
    const now = Date.now();
    const periodMs: Record<string, number> = {
      "1d": 86_400_000,
      "7d": 7 * 86_400_000,
      "30d": 30 * 86_400_000,
      all: now,
    };
    const since = BigInt(now - (periodMs[period] ?? periodMs["7d"]));

    if (type === "rate") {
      const snapshots = await prisma.impliedRateSnapshot.findMany({
        where: {
          marketId,
          timestamp: { gte: new Date(Number(since)) },
        },
        orderBy: { timestamp: "asc" },
        select: {
          impliedRate: true,
          ptPrice: true,
          tvl: true,
          timestamp: true,
        },
      });

      return NextResponse.json(
        snapshots.map((s) => ({
          impliedRate: s.impliedRate,
          ptPrice: s.ptPrice,
          tvl: s.tvl,
          timestamp: s.timestamp.toISOString(),
        }))
      );
    }

    if (type === "volume") {
      const snapshots = await prisma.volumeSnapshot.findMany({
        where: {
          marketId,
          timestamp: { gte: new Date(Number(since)) },
        },
        orderBy: { timestamp: "asc" },
        select: {
          volume: true,
          swapCount: true,
          fees: true,
          timestamp: true,
        },
      });

      return NextResponse.json(snapshots);
    }

    return NextResponse.json({ error: "Invalid type" }, { status: 400 });
  } catch (error) {
    console.error("Failed to fetch history:", error);
    return NextResponse.json([]);
  }
}
