import { NextResponse } from "next/server";
import { headers } from "next/headers";
import { prisma } from "@/lib/prisma";
import { checkRateLimit, isValidSuiAddress } from "@/lib/rate-limit";

export const dynamic = "force-dynamic";

/** User activity stats — individual or leaderboard */
export async function GET(request: Request) {
  const hdrs = await headers();
  const ip = hdrs.get("x-forwarded-for") ?? hdrs.get("x-real-ip") ?? "unknown";
  const { allowed } = checkRateLimit(`users:${ip}`, 30, 60_000);
  if (!allowed) {
    return NextResponse.json({ error: "Rate limit exceeded" }, { status: 429 });
  }

  const { searchParams } = new URL(request.url);
  const address = searchParams.get("address");

  if (address && !isValidSuiAddress(address)) {
    return NextResponse.json({ error: "Invalid Sui address" }, { status: 400 });
  }

  try {
    // Single user lookup
    if (address) {
      const [user, recentSwaps, recentMints] = await Promise.all([
        prisma.user.findUnique({ where: { id: address } }),
        prisma.swap.findMany({
          where: { trader: address },
          orderBy: { timestampMs: "desc" },
          take: 10,
          include: {
            market: {
              select: { underlyingSymbol: true, durationMonths: true },
            },
          },
        }),
        prisma.pyMint.findMany({
          where: { minter: address },
          orderBy: { timestampMs: "desc" },
          take: 10,
        }),
      ]);

      return NextResponse.json({
        user: user
          ? {
              address: user.id,
              firstSeenAt: user.firstSeenAt.toISOString(),
              lastActiveAt: user.lastActiveAt.toISOString(),
              totalDeposited: user.totalDeposited.toString(),
              totalSwapVol: user.totalSwapVol.toString(),
              swapCount: user.swapCount,
              mintCount: user.mintCount,
            }
          : null,
        recentSwaps: recentSwaps.map((s) => ({
          txDigest: s.txDigest,
          direction: s.direction,
          amountIn: s.amountIn.toString(),
          amountOut: s.amountOut.toString(),
          ptPrice: s.ptPrice,
          timestampMs: s.timestampMs.toString(),
          market: s.market,
        })),
        recentMints: recentMints.map((m) => ({
          txDigest: m.txDigest,
          syConsumed: m.syConsumed.toString(),
          ptMinted: m.ptMinted.toString(),
          ytMinted: m.ytMinted.toString(),
          timestampMs: m.timestampMs.toString(),
        })),
      });
    }

    // Leaderboard
    const topUsers = await prisma.user.findMany({
      orderBy: { totalSwapVol: "desc" },
      take: 20,
    });

    return NextResponse.json({
      leaderboard: topUsers.map((u) => ({
        address: u.id,
        totalSwapVol: u.totalSwapVol.toString(),
        swapCount: u.swapCount,
        mintCount: u.mintCount,
        lastActiveAt: u.lastActiveAt.toISOString(),
      })),
    });
  } catch (error) {
    console.error("Failed to fetch users:", error);
    return NextResponse.json({ error: "Failed to fetch users" }, { status: 500 });
  }
}
