import { NextResponse } from "next/server";
import { getSuiClient, RPC_URL } from "@/lib/sui-client";
import { PACKAGE_ID } from "@/lib/constants";

export const dynamic = "force-dynamic";

interface MarketData {
  id: string;
  poolId: string;
  syVaultId: string;
  coinType: string;
  underlyingSymbol: string;
  maturityMs: number;
  impliedRate: number;
  ptPrice: number;
  tvl: number;
  volume24h: number;
  isSettled: boolean;
}

interface MaturityEntry {
  marketConfigId: string;
  maturityMs: number;
  durationMonths: number;
  isSettled: boolean;
}

/** Extract coin type from Move type "0xpkg::mod::Struct<0xhaedal::hasui::HASUI>" */
function extractCoinType(fullType: string): string {
  const match = fullType.match(/<(.+)>/);
  return match ? match[1] : "";
}

/** "0xhaedal::hasui::HASUI" → "HASUI" */
function symbolFromCoinType(coinType: string): string {
  const parts = coinType.split("::");
  return parts[parts.length - 1] ?? coinType;
}

/** Direct JSON-RPC call (avoids SDK caching issues) */
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

export async function GET() {
  try {
    const isDeployed = PACKAGE_ID && !PACKAGE_ID.startsWith("0x00000000");
    if (!isDeployed) return NextResponse.json([]);

    const client = getSuiClient();
    const registryId = process.env.NEXT_PUBLIC_REGISTRY_ID;
    if (!registryId) return NextResponse.json([]);

    // Step 1: Read MaturityRegistry via direct RPC (avoids SDK cache)
    const registryObj = await rpcCall("sui_getObject", [registryId, { showContent: true }]);
    const registryFields = registryObj?.data?.content?.fields;
    if (!registryFields) return NextResponse.json([]);

    const activeMaturities = registryFields.active_maturities as Array<{
      fields?: Record<string, string>;
    }> | undefined;

    if (!activeMaturities || activeMaturities.length === 0) {
      return NextResponse.json([]);
    }

    // Parse maturity entries
    const entries: MaturityEntry[] = activeMaturities.map((m) => {
      const f = m.fields ?? (m as unknown as Record<string, string>);
      return {
        marketConfigId: String(f.market_config_id),
        maturityMs: Number(f.maturity_ms),
        durationMonths: Number(f.duration_months),
        isSettled: Boolean(f.is_settled),
      };
    });

    // Step 2: Fetch unique YieldMarketConfig objects
    const uniqueConfigIds = Array.from(new Set(entries.map((e) => e.marketConfigId)));
    const configTypeMap = new Map<string, string>();
    const configFieldsMap = new Map<string, Record<string, unknown>>();

    await Promise.all(
      uniqueConfigIds.map(async (configId) => {
        try {
          const obj = await client.getObject({
            id: configId,
            options: { showContent: true },
          });
          if (obj.data?.content && "fields" in obj.data.content) {
            configTypeMap.set(configId, (obj.data.content as { type: string }).type);
            configFieldsMap.set(configId, obj.data.content.fields as Record<string, unknown>);
          }
        } catch {
          // skip
        }
      }),
    );

    // Step 3: Discover pools via PoolCreated events
    const poolIdMap = new Map<string, string>();

    try {
      const events = await client.queryEvents({
        query: { MoveEventType: `${PACKAGE_ID}::rate_market::PoolCreated` },
        limit: 50,
      });

      for (const ev of events.data) {
        const parsed = ev.parsedJson as Record<string, string> | undefined;
        if (parsed?.market_config_id && parsed?.pool_id) {
          poolIdMap.set(parsed.market_config_id, parsed.pool_id);
        }
      }
    } catch {
      // events query not supported or failed
    }

    // Step 4: Fetch pool objects for AMM data
    const poolDataMap = new Map<string, Record<string, unknown>>();

    await Promise.all(
      Array.from(poolIdMap.entries()).map(async ([configId, poolId]) => {
        try {
          const obj = await client.getObject({
            id: poolId,
            options: { showContent: true },
          });
          if (obj.data?.content && "fields" in obj.data.content) {
            poolDataMap.set(configId, obj.data.content.fields as Record<string, unknown>);
          }
        } catch {
          // skip
        }
      }),
    );

    // Step 5: Build market data
    const markets: MarketData[] = [];

    for (const entry of entries) {
      const fullType = configTypeMap.get(entry.marketConfigId) ?? "";
      const coinType = extractCoinType(fullType);
      const symbol = symbolFromCoinType(coinType);
      const poolFields = poolDataMap.get(entry.marketConfigId);
      const poolId = poolIdMap.get(entry.marketConfigId) ?? "";
      const configFields = configFieldsMap.get(entry.marketConfigId);
      const syVaultId = String(configFields?.sy_vault_id ?? "");

      let impliedRate = 0;
      let ptPrice = 0.95;
      let tvl = 0;

      if (poolFields) {
        const ptReserve = Number(poolFields.pt_reserve ?? 0);
        const syReserve = Number(poolFields.sy_reserve ?? 0);
        const currentImpliedRate = Number(poolFields.current_implied_rate ?? 0);

        if (currentImpliedRate > 0) {
          impliedRate = currentImpliedRate / 1e18;
        }

        if (ptReserve > 0 && syReserve > 0) {
          ptPrice = syReserve / ptReserve;
        }

        tvl = (ptReserve + syReserve) / 1e9;
      }

      markets.push({
        id: entry.marketConfigId,
        poolId,
        syVaultId,
        coinType,
        underlyingSymbol: symbol || "SUI",
        maturityMs: entry.maturityMs,
        impliedRate,
        ptPrice,
        tvl,
        volume24h: 0,
        isSettled: entry.isSettled,
      });
    }

    return NextResponse.json(markets);
  } catch (error) {
    console.error("Failed to fetch markets:", error);
    return NextResponse.json([]);
  }
}
