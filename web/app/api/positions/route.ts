import { NextResponse } from "next/server";
import { getSuiClient } from "@/lib/sui-client";
import { prisma } from "@/lib/prisma";
import { PACKAGE_ID } from "@/lib/constants";

export const dynamic = "force-dynamic";

interface PositionFields {
  amount?: string;
  maturity_ms?: string;
  market_config_id?: { bytes: string } | string;
  pool_id?: { bytes: string } | string;
  user_interest_index?: string;
  accrued_yield?: string;
  tranche_type?: string;
  deposit_amount?: string;
  deposit_timestamp?: string;
  vault_id?: { bytes: string } | string;
}

function extractId(val: { bytes: string } | string | undefined): string {
  if (!val) return "";
  if (typeof val === "string") return val;
  return val.bytes ? `0x${val.bytes}` : "";
}

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const address = searchParams.get("address");

  if (!address) {
    return NextResponse.json(
      { error: "address parameter required" },
      { status: 400 }
    );
  }

  try {
    const client = getSuiClient();

    // Fetch all position types in parallel
    const [ptRaw, ytRaw, lpRaw, trancheRaw] = await Promise.all([
      client
        .getOwnedObjects({
          owner: address,
          filter: { StructType: `${PACKAGE_ID}::yield_tokenizer::PT` },
          options: { showContent: true, showType: true },
        })
        .catch(() => ({ data: [] })),
      client
        .getOwnedObjects({
          owner: address,
          filter: { StructType: `${PACKAGE_ID}::yield_tokenizer::YT` },
          options: { showContent: true, showType: true },
        })
        .catch(() => ({ data: [] })),
      client
        .getOwnedObjects({
          owner: address,
          filter: { StructType: `${PACKAGE_ID}::rate_market::LPToken` },
          options: { showContent: true, showType: true },
        })
        .catch(() => ({ data: [] })),
      client
        .getOwnedObjects({
          owner: address,
          filter: {
            StructType: `${PACKAGE_ID}::tranche_engine::TrancheReceipt`,
          },
          options: { showContent: true, showType: true },
        })
        .catch(() => ({ data: [] })),
    ]);

    // Load market data from DB for enrichment
    const markets = await prisma.market
      .findMany({
        select: {
          id: true,
          poolId: true,
          underlyingSymbol: true,
          maturityMs: true,
          durationMonths: true,
          impliedRate: true,
          ptPrice: true,
          isSettled: true,
        },
      })
      .catch(() => []);

    const marketMap = new Map(markets.map((m) => [m.id, m]));
    const poolMarketMap = new Map(
      markets.filter((m) => m.poolId).map((m) => [m.poolId!, m])
    );

    // Parse PT positions
    const ptPositions = ptRaw.data
      .filter((o) => o.data?.content && "fields" in o.data.content)
      .map((o) => {
        const fields = (o.data!.content as { fields: PositionFields }).fields;
        const configId = extractId(fields.market_config_id);
        const market = marketMap.get(configId);
        const amount = Number(fields.amount ?? 0);
        const maturityMs = Number(fields.maturity_ms ?? 0);
        const daysToMaturity = Math.max(
          0,
          Math.ceil((maturityMs - Date.now()) / 86_400_000)
        );

        // PT value = amount * ptPrice (in SY terms), redeemable at 1:1 at maturity
        const ptPrice = market?.ptPrice ?? 1;
        const currentValue = amount / 1e9;
        const maturityValue = amount / 1e9;
        const profit = maturityValue - currentValue * (1 / ptPrice);

        return {
          objectId: o.data!.objectId,
          type: "PT" as const,
          amount,
          amountFormatted: (amount / 1e9).toFixed(4),
          maturityMs,
          daysToMaturity,
          marketConfigId: configId,
          symbol: market?.underlyingSymbol ?? "SUI",
          duration: market?.durationMonths
            ? `${market.durationMonths}M`
            : `${daysToMaturity}d`,
          impliedRate: market?.impliedRate ?? 0,
          ptPrice,
          currentValue,
          maturityValue,
          profit,
          isSettled: market?.isSettled ?? false,
        };
      });

    // Parse YT positions
    const ytPositions = ytRaw.data
      .filter((o) => o.data?.content && "fields" in o.data.content)
      .map((o) => {
        const fields = (o.data!.content as { fields: PositionFields }).fields;
        const configId = extractId(fields.market_config_id);
        const market = marketMap.get(configId);
        const amount = Number(fields.amount ?? 0);
        const maturityMs = Number(fields.maturity_ms ?? 0);
        const daysToMaturity = Math.max(
          0,
          Math.ceil((maturityMs - Date.now()) / 86_400_000)
        );
        const accruedYield = Number(fields.accrued_yield ?? 0);

        return {
          objectId: o.data!.objectId,
          type: "YT" as const,
          amount,
          amountFormatted: (amount / 1e9).toFixed(4),
          maturityMs,
          daysToMaturity,
          marketConfigId: configId,
          symbol: market?.underlyingSymbol ?? "SUI",
          duration: market?.durationMonths
            ? `${market.durationMonths}M`
            : `${daysToMaturity}d`,
          impliedRate: market?.impliedRate ?? 0,
          ytPrice: Math.max(0, 1 - (market?.ptPrice ?? 1)),
          accruedYield,
          accruedYieldFormatted: (accruedYield / 1e9).toFixed(4),
          isSettled: market?.isSettled ?? false,
        };
      });

    // Parse LP positions
    const lpPositions = lpRaw.data
      .filter((o) => o.data?.content && "fields" in o.data.content)
      .map((o) => {
        const fields = (o.data!.content as { fields: PositionFields }).fields;
        const poolId = extractId(fields.pool_id);
        const market = poolMarketMap.get(poolId);
        const amount = Number(fields.amount ?? 0);

        return {
          objectId: o.data!.objectId,
          type: "LP" as const,
          amount,
          amountFormatted: (amount / 1e9).toFixed(4),
          poolId,
          symbol: market?.underlyingSymbol ?? "SUI",
          duration: market?.durationMonths
            ? `${market.durationMonths}M`
            : "N/A",
          impliedRate: market?.impliedRate ?? 0,
        };
      });

    // Parse tranche positions
    const tranchePositions = trancheRaw.data
      .filter((o) => o.data?.content && "fields" in o.data.content)
      .map((o) => {
        const fields = (o.data!.content as { fields: PositionFields }).fields;
        const amount = Number(fields.deposit_amount ?? fields.amount ?? 0);

        return {
          objectId: o.data!.objectId,
          type: "Tranche" as const,
          trancheType: fields.tranche_type ?? "senior",
          amount,
          amountFormatted: (amount / 1e9).toFixed(4),
          vaultId: extractId(fields.vault_id),
          depositTimestamp: Number(fields.deposit_timestamp ?? 0),
        };
      });

    // Summary stats
    const totalPtValue = ptPositions.reduce((s, p) => s + p.currentValue, 0);
    const totalYtValue = ytPositions.reduce(
      (s, p) => s + (p.amount / 1e9) * p.ytPrice,
      0
    );
    const totalLpValue = lpPositions.reduce((s, p) => s + p.amount / 1e9, 0);
    const totalAccruedYield = ytPositions.reduce(
      (s, p) => s + p.accruedYield / 1e9,
      0
    );

    // Upcoming maturities (sorted)
    const maturities = [
      ...ptPositions.map((p) => ({
        type: "PT",
        symbol: p.symbol,
        duration: p.duration,
        maturityMs: p.maturityMs,
        daysToMaturity: p.daysToMaturity,
        amount: p.amountFormatted,
        isSettled: p.isSettled,
      })),
      ...ytPositions.map((p) => ({
        type: "YT",
        symbol: p.symbol,
        duration: p.duration,
        maturityMs: p.maturityMs,
        daysToMaturity: p.daysToMaturity,
        amount: p.amountFormatted,
        isSettled: p.isSettled,
      })),
    ].sort((a, b) => a.maturityMs - b.maturityMs);

    return NextResponse.json({
      address,
      ptPositions,
      ytPositions,
      lpPositions,
      tranchePositions,
      summary: {
        totalPositions:
          ptPositions.length +
          ytPositions.length +
          lpPositions.length +
          tranchePositions.length,
        totalPtValue,
        totalYtValue,
        totalLpValue,
        totalValue: totalPtValue + totalYtValue + totalLpValue,
        totalAccruedYield,
      },
      maturities,
    });
  } catch (error) {
    console.error("Failed to fetch positions:", error);
    return NextResponse.json(
      { error: "Failed to fetch positions" },
      { status: 500 }
    );
  }
}
