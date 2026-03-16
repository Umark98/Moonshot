import { NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";
import { getSuiClient, RPC_URL } from "@/lib/sui-client";
import { PACKAGE_ID } from "@/lib/constants";

export const dynamic = "force-dynamic";

/** Direct JSON-RPC call */
async function rpcCall(method: string, params: unknown[]) {
  const resp = await fetch(RPC_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    cache: "no-store",
  });
  const data = await resp.json();
  return data.result;
}

function extractCoinType(fullType: string): string {
  const match = fullType.match(/<(.+)>/);
  return match ? match[1] : "";
}

function symbolFromCoinType(coinType: string): string {
  const parts = coinType.split("::");
  return parts[parts.length - 1] ?? coinType;
}

/**
 * POST /api/sync — Sync on-chain state to database.
 * Called manually or by a cron job to bootstrap/refresh DB state.
 */
export async function POST() {
  try {
    const isDeployed = PACKAGE_ID && !PACKAGE_ID.startsWith("0x00000000");
    if (!isDeployed) {
      return NextResponse.json({ synced: false, reason: "not deployed" });
    }

    const client = getSuiClient();
    const registryId = process.env.NEXT_PUBLIC_REGISTRY_ID;
    if (!registryId) {
      return NextResponse.json({ synced: false, reason: "no registry ID" });
    }

    // 1. Read MaturityRegistry
    const registryObj = await rpcCall("sui_getObject", [
      registryId,
      { showContent: true },
    ]);
    const registryFields = registryObj?.data?.content?.fields;
    if (!registryFields) {
      return NextResponse.json({ synced: false, reason: "registry not found" });
    }

    const activeMaturities = registryFields.active_maturities as Array<{
      fields?: Record<string, string>;
    }> | undefined;

    if (!activeMaturities || activeMaturities.length === 0) {
      return NextResponse.json({ synced: true, markets: 0 });
    }

    // Parse entries
    const entries = activeMaturities.map((m) => {
      const f = m.fields ?? (m as unknown as Record<string, string>);
      return {
        marketConfigId: String(f.market_config_id),
        maturityMs: BigInt(f.maturity_ms),
        durationMonths: Number(f.duration_months),
        isSettled: Boolean(f.is_settled),
      };
    });

    // 2. Fetch YieldMarketConfig objects
    const uniqueConfigIds = [...new Set(entries.map((e) => e.marketConfigId))];
    const configTypeMap = new Map<string, string>();
    const configFieldsMap = new Map<string, Record<string, unknown>>();

    await Promise.all(
      uniqueConfigIds.map(async (id) => {
        try {
          const obj = await client.getObject({
            id,
            options: { showContent: true },
          });
          if (obj.data?.content && "fields" in obj.data.content) {
            configTypeMap.set(id, (obj.data.content as { type: string }).type);
            configFieldsMap.set(
              id,
              obj.data.content.fields as Record<string, unknown>
            );
          }
        } catch {
          /* skip */
        }
      })
    );

    // 3. Discover pools via events
    const poolIdMap = new Map<string, string>();
    try {
      const events = await client.queryEvents({
        query: {
          MoveEventType: `${PACKAGE_ID}::rate_market::PoolCreated`,
        },
        limit: 50,
      });
      for (const ev of events.data) {
        const p = ev.parsedJson as Record<string, string> | undefined;
        if (p?.market_config_id && p?.pool_id) {
          poolIdMap.set(p.market_config_id, p.pool_id);
        }
      }
    } catch {
      /* events query failed */
    }

    // 4. Fetch pool data
    const poolDataMap = new Map<string, Record<string, unknown>>();
    await Promise.all(
      Array.from(poolIdMap.entries()).map(async ([configId, poolId]) => {
        try {
          const obj = await client.getObject({
            id: poolId,
            options: { showContent: true },
          });
          if (obj.data?.content && "fields" in obj.data.content) {
            poolDataMap.set(
              configId,
              obj.data.content.fields as Record<string, unknown>
            );
          }
        } catch {
          /* skip */
        }
      })
    );

    // 5. Upsert SY Vault (deduce from first config)
    const firstConfig = configFieldsMap.values().next().value as Record<string, unknown> | undefined;
    const syVaultId = String(firstConfig?.sy_vault_id ?? "unknown");
    const firstType = configTypeMap.values().next().value ?? "";
    const coinType = extractCoinType(firstType);
    const symbol = symbolFromCoinType(coinType) || "SUI";

    await prisma.syVault.upsert({
      where: { id: syVaultId },
      create: {
        id: syVaultId,
        coinType: coinType || "0x2::sui::SUI",
        underlyingSymbol: symbol,
      },
      update: { underlyingSymbol: symbol },
    });

    // 6. Upsert markets
    let synced = 0;
    for (const entry of entries) {
      const fullType = configTypeMap.get(entry.marketConfigId) ?? "";
      const ct = extractCoinType(fullType);
      const sym = symbolFromCoinType(ct) || "SUI";
      const poolFields = poolDataMap.get(entry.marketConfigId);
      const poolId = poolIdMap.get(entry.marketConfigId) ?? null;
      const configFields = configFieldsMap.get(entry.marketConfigId);
      const vaultId = String(configFields?.sy_vault_id ?? syVaultId);

      let impliedRate = 0;
      let ptPrice = 1;
      let tvl = 0;

      if (poolFields) {
        const ptReserve = Number(poolFields.pt_reserve ?? 0);
        const syReserve = Number(poolFields.sy_reserve ?? 0);
        const currentImpliedRate = Number(
          poolFields.current_implied_rate ?? 0
        );

        if (currentImpliedRate > 0) impliedRate = currentImpliedRate / 1e18;
        if (ptReserve > 0 && syReserve > 0) ptPrice = syReserve / ptReserve;
        tvl = (ptReserve + syReserve) / 1e9;
      }

      // Ensure vault exists for this market
      await prisma.syVault.upsert({
        where: { id: vaultId },
        create: {
          id: vaultId,
          coinType: ct || "0x2::sui::SUI",
          underlyingSymbol: sym,
        },
        update: {},
      });

      await prisma.market.upsert({
        where: { id: entry.marketConfigId },
        create: {
          id: entry.marketConfigId,
          vaultId,
          poolId,
          coinType: ct || "0x2::sui::SUI",
          underlyingSymbol: sym,
          maturityMs: entry.maturityMs,
          durationMonths: entry.durationMonths,
          impliedRate,
          ptPrice,
          ytPrice: Math.max(0, 1 - ptPrice),
          tvl,
          isSettled: entry.isSettled,
        },
        update: {
          poolId,
          impliedRate,
          ptPrice,
          ytPrice: Math.max(0, 1 - ptPrice),
          tvl,
          isSettled: entry.isSettled,
        },
      });

      synced++;
    }

    return NextResponse.json({ synced: true, markets: synced });
  } catch (error) {
    console.error("Sync failed:", error);
    return NextResponse.json(
      { synced: false, error: String(error) },
      { status: 500 }
    );
  }
}

/** GET /api/sync — Show sync status */
export async function GET() {
  try {
    const [marketCount, vaultCount, eventCount, userCount] = await Promise.all([
      prisma.market.count(),
      prisma.syVault.count(),
      prisma.event.count(),
      prisma.user.count(),
    ]);

    const lastEvent = await prisma.event.findFirst({
      orderBy: { timestampMs: "desc" },
      select: { eventType: true, timestampMs: true, createdAt: true },
    });

    return NextResponse.json({
      markets: marketCount,
      vaults: vaultCount,
      events: eventCount,
      users: userCount,
      lastEvent: lastEvent
        ? {
            type: lastEvent.eventType,
            timestampMs: lastEvent.timestampMs.toString(),
            indexedAt: lastEvent.createdAt.toISOString(),
          }
        : null,
    });
  } catch (error) {
    console.error("Sync status failed:", error);
    return NextResponse.json({ error: String(error) }, { status: 500 });
  }
}
