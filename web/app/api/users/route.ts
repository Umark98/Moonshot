import { NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";

export const dynamic = "force-dynamic";

/** User activity stats — individual or leaderboard */
export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const address = searchParams.get("address");

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
