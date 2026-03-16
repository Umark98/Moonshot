import { NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";
import { PACKAGE_ID } from "@/lib/constants";

export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const asset = searchParams.get("asset") ?? "SUI";

  try {
    const isDeployed = PACKAGE_ID && !PACKAGE_ID.startsWith("0x00000000");
    if (!isDeployed) return NextResponse.json([]);

    // Try DB first
    const dbMarkets = await prisma.market.findMany({
      where: {
        underlyingSymbol: asset,
        isSettled: false,
      },
      orderBy: { maturityMs: "asc" },
      select: {
        maturityMs: true,
        impliedRate: true,
        ptPrice: true,
      },
    });

    if (dbMarkets.length > 0) {
      const curve = dbMarkets.map((m) => {
        const daysToMaturity = Math.max(
          0,
          Math.ceil((Number(m.maturityMs) - Date.now()) / 86400000)
        );
        let label = `${daysToMaturity}d`;
        if (daysToMaturity >= 330) label = "1Y";
        else if (daysToMaturity >= 150) label = "6M";
        else if (daysToMaturity >= 60) label = "3M";
        else if (daysToMaturity >= 20) label = "1M";

        return {
          maturityMs: Number(m.maturityMs),
          impliedRate: m.impliedRate,
          ptPrice: m.ptPrice,
          daysToMaturity,
          label,
        };
      });

      return NextResponse.json(curve);
    }

    // Fallback: fetch from on-chain markets API
    const origin =
      process.env.VERCEL_URL || process.env.NEXT_PUBLIC_VERCEL_URL || "localhost:3000";
    const protocol = origin.includes("localhost") ? "http" : "https";
    const marketsRes = await fetch(
      `${protocol}://${origin}/api/markets`,
      { cache: "no-store" }
    );
    const allMarkets = await marketsRes.json();

    if (!Array.isArray(allMarkets)) return NextResponse.json([]);

    const curve = allMarkets
      .filter(
        (m: { underlyingSymbol: string; isSettled: boolean }) =>
          m.underlyingSymbol === asset && !m.isSettled
      )
      .sort(
        (a: { maturityMs: number }, b: { maturityMs: number }) =>
          a.maturityMs - b.maturityMs
      )
      .map(
        (m: {
          maturityMs: number;
          impliedRate: number;
          ptPrice: number;
        }) => {
          const daysToMaturity = Math.max(
            0,
            Math.ceil((m.maturityMs - Date.now()) / 86400000)
          );
          let label = `${daysToMaturity}d`;
          if (daysToMaturity >= 330) label = "1Y";
          else if (daysToMaturity >= 150) label = "6M";
          else if (daysToMaturity >= 60) label = "3M";
          else if (daysToMaturity >= 20) label = "1M";

          return {
            maturityMs: m.maturityMs,
            impliedRate: m.impliedRate,
            ptPrice: m.ptPrice,
            daysToMaturity,
            label,
          };
        }
      );

    return NextResponse.json(curve);
  } catch (error) {
    console.error("Failed to build yield curve:", error);
    return NextResponse.json([]);
  }
}
