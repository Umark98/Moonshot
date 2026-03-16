import { NextResponse } from "next/server";
import { headers } from "next/headers";
import { prisma } from "@/lib/prisma";
import { PACKAGE_ID } from "@/lib/constants";
import { checkRateLimit } from "@/lib/rate-limit";

export const dynamic = "force-dynamic";

export async function GET() {
  const hdrs = await headers();
  const ip = hdrs.get("x-forwarded-for") ?? hdrs.get("x-real-ip") ?? "unknown";
  const { allowed } = checkRateLimit(`stats:${ip}`, 30, 60_000);
  if (!allowed) {
    return NextResponse.json({ error: "Rate limit exceeded" }, { status: 429 });
  }

  try {
    const isDeployed = PACKAGE_ID && !PACKAGE_ID.startsWith("0x00000000");
    if (!isDeployed) {
      return NextResponse.json({
        totalTvl: 0,
        totalVolume24h: 0,
        totalMarkets: 0,
        activeMarkets: 0,
        totalUsers: 0,
        totalFees24h: 0,
      });
    }

    // Try DB first — fast path
    const [markets, userCount, recentSwaps, recentFees] = await Promise.all([
      prisma.market.findMany({
        select: {
          tvl: true,
          volume24h: true,
          isSettled: true,
        },
      }),
      prisma.user.count(),
      prisma.swap.aggregate({
        _sum: { amountIn: true },
        where: {
          timestampMs: { gte: BigInt(Date.now() - 86_400_000) },
        },
      }),
      prisma.feeCollection.aggregate({
        _sum: { amount: true },
        where: {
          timestampMs: { gte: BigInt(Date.now() - 86_400_000) },
        },
      }),
    ]);

    // If no markets in DB yet, fall back to on-chain API
    if (markets.length === 0) {
      const origin =
        process.env.VERCEL_URL || process.env.NEXT_PUBLIC_VERCEL_URL || "localhost:3000";
      const protocol = origin.includes("localhost") ? "http" : "https";
      const marketsRes = await fetch(`${protocol}://${origin}/api/markets`, {
        cache: "no-store",
      });
      const onChainMarkets = await marketsRes.json();

      return NextResponse.json({
        totalTvl: Array.isArray(onChainMarkets)
          ? onChainMarkets.reduce((s: number, m: { tvl: number }) => s + m.tvl, 0)
          : 0,
        totalVolume24h: 0,
        totalMarkets: Array.isArray(onChainMarkets) ? onChainMarkets.length : 0,
        activeMarkets: Array.isArray(onChainMarkets)
          ? onChainMarkets.filter((m: { isSettled: boolean }) => !m.isSettled).length
          : 0,
        totalUsers: 0,
        totalFees24h: 0,
      });
    }

    const totalTvl = markets.reduce((s, m) => s + m.tvl, 0);
    const totalVolume24h = Number(recentSwaps._sum.amountIn ?? 0n) / 1e9;
    const totalFees24h = Number(recentFees._sum.amount ?? 0n) / 1e9;

    return NextResponse.json({
      totalTvl,
      totalVolume24h,
      totalMarkets: markets.length,
      activeMarkets: markets.filter((m) => !m.isSettled).length,
      totalUsers: userCount,
      totalFees24h,
    });
  } catch (error) {
    console.error("Failed to fetch stats:", error);
    return NextResponse.json({
      totalTvl: 0,
      totalVolume24h: 0,
      totalMarkets: 0,
      activeMarkets: 0,
      totalUsers: 0,
      totalFees24h: 0,
    });
  }
}
