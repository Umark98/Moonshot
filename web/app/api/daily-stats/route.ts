import { NextResponse } from "next/server";
import { headers } from "next/headers";
import { prisma } from "@/lib/prisma";
import { checkRateLimit } from "@/lib/rate-limit";

export const dynamic = "force-dynamic";

/** GET /api/daily-stats — Protocol daily stats for dashboard charts */
export async function GET(request: Request) {
  const hdrs = await headers();
  const ip = hdrs.get("x-forwarded-for") ?? hdrs.get("x-real-ip") ?? "unknown";
  const { allowed } = checkRateLimit(`daily-stats:${ip}`, 30, 60_000);
  if (!allowed) {
    return NextResponse.json({ error: "Rate limit exceeded" }, { status: 429 });
  }

  const { searchParams } = new URL(request.url);
  const days = Math.min(parseInt(searchParams.get("days") || "30"), 365);

  try {
    const since = new Date();
    since.setDate(since.getDate() - days);
    since.setHours(0, 0, 0, 0);

    const stats = await prisma.dailyStats.findMany({
      where: { date: { gte: since } },
      orderBy: { date: "asc" },
    });

    return NextResponse.json(
      stats.map((s) => ({
        date: s.date.toISOString().slice(0, 10),
        totalTvl: s.totalTvl,
        totalVolume: s.totalVolume,
        totalSwaps: s.totalSwaps,
        totalMints: s.totalMints,
        totalRedeems: s.totalRedeems,
        uniqueUsers: s.uniqueUsers,
        totalFees: s.totalFees,
      }))
    );
  } catch (error) {
    console.error("Failed to fetch daily stats:", error);
    return NextResponse.json([]);
  }
}
