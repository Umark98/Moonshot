// ============================================================
// Crux Protocol — Event Indexer (Prisma + Supabase)
// ============================================================

import { SuiClient, SuiEvent, EventId } from "@mysten/sui/client";
// Prisma client generated in web/node_modules — resolve from there
import { PrismaClient } from "../../web/node_modules/@prisma/client";
import dotenv from "dotenv";

// Load local .env, then fall back to web/.env for DB URL
dotenv.config();
if (!process.env.DATABASE_URL) {
  dotenv.config({ path: "../web/.env" });
}

const RPC_URL =
  process.env.SUI_RPC_URL || "https://fullnode.testnet.sui.io:443";
const PACKAGE_ID = process.env.PACKAGE_ID || process.env.NEXT_PUBLIC_PACKAGE_ID || "";
const POLL_INTERVAL = parseInt(process.env.POLL_INTERVAL || "5000");

const MODULES = [
  "standardized_yield",
  "yield_tokenizer",
  "rate_market",
  "orderbook_adapter",
  "tranche_engine",
  "governor",
  "fee_collector",
  "haedal_adapter",
  "suilend_adapter",
  "navi_adapter",
  "scallop_adapter",
  "router",
  "flash_mint",
];

class CruxIndexer {
  private client: SuiClient;
  private prisma: PrismaClient;
  private running = false;

  constructor() {
    this.client = new SuiClient({ url: RPC_URL });
    this.prisma = new PrismaClient({
      log: ["warn", "error"],
    });
    console.log("Crux Indexer initialized (Prisma + Supabase)");
  }

  async start() {
    this.running = true;
    console.log(`Indexing events for package: ${PACKAGE_ID}`);
    console.log(`RPC: ${RPC_URL}`);
    console.log(`Polling every ${POLL_INTERVAL}ms`);

    while (this.running) {
      try {
        await this.pollAllModules();
      } catch (err) {
        console.error("Poll cycle error:", err);
      }
      await this.sleep(POLL_INTERVAL);
    }
  }

  async stop() {
    this.running = false;
    await this.prisma.$disconnect();
    console.log("Indexer stopped.");
  }

  // ── Poll all modules with cursor tracking ──

  private async pollAllModules() {
    if (!PACKAGE_ID) return;

    for (const mod of MODULES) {
      try {
        await this.pollModule(mod);
      } catch {
        // Module may not have events yet — skip silently
      }
    }
  }

  private async pollModule(moduleName: string) {
    // Load cursor from DB
    const cursorRow = await this.prisma.indexerCursor.findUnique({
      where: { module: moduleName },
    });

    const cursor: EventId | null =
      cursorRow?.txDigest && cursorRow?.eventSeq != null
        ? { txDigest: cursorRow.txDigest, eventSeq: String(cursorRow.eventSeq) }
        : null;

    const { data, nextCursor } = await this.client.queryEvents({
      query: {
        MoveModule: { package: PACKAGE_ID, module: moduleName },
      },
      cursor: cursor as any,
      limit: 50,
      order: "ascending",
    });

    if (data.length === 0) return;

    for (const event of data) {
      await this.processEvent(event);
    }

    // Save cursor
    if (nextCursor) {
      await this.prisma.indexerCursor.upsert({
        where: { module: moduleName },
        create: {
          module: moduleName,
          txDigest: (nextCursor as any).txDigest,
          eventSeq: parseInt((nextCursor as any).eventSeq || "0"),
        },
        update: {
          txDigest: (nextCursor as any).txDigest,
          eventSeq: parseInt((nextCursor as any).eventSeq || "0"),
        },
      });
    }

    if (data.length > 0) {
      console.log(`[${moduleName}] Indexed ${data.length} events`);
    }
  }

  // ── Process individual events ──

  private async processEvent(event: SuiEvent) {
    const eventType = event.type.split("::").pop() || "";
    const moduleName = event.type.split("::")[1] || "";
    const timestampMs = BigInt(event.timestampMs || "0");
    const parsed = event.parsedJson as Record<string, any> | undefined;
    const eventSeqNum = parseInt(
      typeof event.id.eventSeq === "string" ? event.id.eventSeq : "0"
    );

    // 1. Store raw event (upsert to avoid duplicates)
    try {
      await this.prisma.event.upsert({
        where: {
          txDigest_eventSeq: {
            txDigest: event.id.txDigest,
            eventSeq: eventSeqNum,
          },
        },
        create: {
          txDigest: event.id.txDigest,
          eventSeq: eventSeqNum,
          eventType,
          packageId: PACKAGE_ID,
          module: moduleName,
          sender: parsed?.sender ?? null,
          data: parsed ?? {},
          timestampMs,
        },
        update: {}, // no-op if exists
      });
    } catch {
      // duplicate — skip
      return;
    }

    // 2. Process typed events
    if (!parsed) return;

    try {
      switch (eventType) {
        case "SYDeposited":
          await this.handleSyDeposit(event.id.txDigest, parsed, timestampMs);
          break;
        case "SYRedeemed":
          await this.handleSyRedemption(event.id.txDigest, parsed, timestampMs);
          break;
        case "PYMinted":
          await this.handlePyMint(event.id.txDigest, parsed, timestampMs);
          break;
        case "Swapped":
          await this.handleSwap(event.id.txDigest, parsed, timestampMs);
          break;
        case "ExchangeRateUpdated":
          await this.handleRateUpdate(parsed, timestampMs);
          break;
        case "MarketSettled":
          await this.handleSettlement(parsed, timestampMs);
          break;
        case "LiquidityAdded":
          await this.handleLiquidityAdd(event.id.txDigest, parsed, timestampMs);
          break;
        case "LiquidityRemoved":
          await this.handleLiquidityRemove(
            event.id.txDigest,
            parsed,
            timestampMs
          );
          break;
        case "FeeCollected":
          await this.handleFeeCollection(event.id.txDigest, parsed, timestampMs);
          break;
        case "PoolCreated":
          await this.handlePoolCreated(parsed);
          break;
      }
    } catch (err) {
      console.error(`Error processing ${eventType}:`, err);
    }

    // 3. Track user
    const userAddress =
      parsed.depositor ||
      parsed.redeemer ||
      parsed.minter ||
      parsed.trader ||
      parsed.provider;
    if (userAddress) {
      await this.upsertUser(userAddress, eventType, parsed);
    }
  }

  // ── Event handlers ──

  private async handleSyDeposit(
    txDigest: string,
    p: Record<string, any>,
    ts: bigint
  ) {
    const vaultId = String(p.vault_id);

    // Ensure vault exists
    await this.ensureVault(vaultId, p);

    await this.prisma.syDeposit.create({
      data: {
        txDigest,
        vaultId,
        depositor: String(p.depositor),
        underlyingAmount: BigInt(p.underlying_amount || 0),
        syAmount: BigInt(p.sy_amount || 0),
        exchangeRate: BigInt(p.exchange_rate || 0),
        timestampMs: ts,
      },
    });
  }

  private async handleSyRedemption(
    txDigest: string,
    p: Record<string, any>,
    ts: bigint
  ) {
    const vaultId = String(p.vault_id);
    await this.ensureVault(vaultId, p);

    await this.prisma.syRedemption.create({
      data: {
        txDigest,
        vaultId,
        redeemer: String(p.redeemer),
        syAmount: BigInt(p.sy_amount || 0),
        underlyingAmount: BigInt(p.underlying_amount || 0),
        exchangeRate: BigInt(p.exchange_rate || 0),
        timestampMs: ts,
      },
    });
  }

  private async handlePyMint(
    txDigest: string,
    p: Record<string, any>,
    ts: bigint
  ) {
    const marketId = String(p.market_config_id);
    await this.ensureMarket(marketId);

    await this.prisma.pyMint.create({
      data: {
        txDigest,
        marketId,
        minter: String(p.minter),
        syConsumed: BigInt(p.sy_consumed || 0),
        ptMinted: BigInt(p.pt_minted || 0),
        ytMinted: BigInt(p.yt_minted || 0),
        timestampMs: ts,
      },
    });
  }

  private async handleSwap(
    txDigest: string,
    p: Record<string, any>,
    ts: bigint
  ) {
    const poolId = String(p.pool_id);
    const ptIn = BigInt(p.pt_in || 0);
    const syIn = BigInt(p.sy_in || 0);
    const ptOut = BigInt(p.pt_out || 0);
    const syOut = BigInt(p.sy_out || 0);
    const direction = ptIn > 0n ? "pt_to_sy" : "sy_to_pt";
    const impliedRateRaw = BigInt(p.implied_rate || 0);
    const impliedRateFloat =
      Number(impliedRateRaw) / 1e18;

    // Find market by pool
    const market = await this.prisma.market.findFirst({
      where: { poolId },
    });

    if (!market) return;

    const ptReserve = Number(p.pt_reserve ?? 0);
    const syReserve = Number(p.sy_reserve ?? 0);
    const ptPrice = ptReserve > 0 ? syReserve / ptReserve : 1;

    await this.prisma.swap.create({
      data: {
        txDigest,
        marketId: market.id,
        poolId,
        trader: String(p.trader),
        direction,
        amountIn: direction === "pt_to_sy" ? ptIn : syIn,
        amountOut: direction === "pt_to_sy" ? syOut : ptOut,
        fee: BigInt(p.fee || 0),
        impliedRate: impliedRateRaw,
        ptPrice,
        timestampMs: ts,
      },
    });

    // Update market cached state
    await this.prisma.market.update({
      where: { id: market.id },
      data: {
        impliedRate: impliedRateFloat,
        ptPrice,
        tvl: (ptReserve + syReserve) / 1e9,
      },
    });

    // Snapshot for charts
    await this.prisma.impliedRateSnapshot.create({
      data: {
        marketId: market.id,
        impliedRate: impliedRateFloat,
        ptPrice,
        ptReserve: BigInt(p.pt_reserve ?? 0),
        syReserve: BigInt(p.sy_reserve ?? 0),
        tvl: (ptReserve + syReserve) / 1e9,
      },
    });
  }

  private async handleRateUpdate(p: Record<string, any>, ts: bigint) {
    const vaultId = String(p.vault_id);
    await this.ensureVault(vaultId, p);

    await this.prisma.rateSnapshot.create({
      data: {
        vaultId,
        oldRate: BigInt(p.old_rate || 0),
        newRate: BigInt(p.new_rate || 0),
        timestampMs: ts,
      },
    });

    // Update vault exchange rate
    await this.prisma.syVault.update({
      where: { id: vaultId },
      data: { exchangeRate: BigInt(p.new_rate || 0) },
    });
  }

  private async handleSettlement(p: Record<string, any>, ts: bigint) {
    const marketId = String(p.market_config_id);
    await this.ensureMarket(marketId);

    await this.prisma.marketSettlement.create({
      data: {
        marketId,
        settlementIndex: BigInt(p.settlement_py_index || 0),
        maturityMs: BigInt(p.maturity_ms || 0),
        timestampMs: ts,
      },
    });

    // Mark market as settled
    await this.prisma.market.update({
      where: { id: marketId },
      data: {
        isSettled: true,
        settlementRate: BigInt(p.settlement_py_index || 0),
        settledAt: new Date(),
      },
    });
  }

  private async handleLiquidityAdd(
    txDigest: string,
    p: Record<string, any>,
    ts: bigint
  ) {
    const poolId = String(p.pool_id);
    const market = await this.prisma.market.findFirst({ where: { poolId } });
    if (!market) return;

    await this.prisma.liquidityEvent.create({
      data: {
        txDigest,
        marketId: market.id,
        poolId,
        provider: String(p.provider),
        action: "add",
        syAmount: BigInt(p.sy_amount || 0),
        ptAmount: BigInt(p.pt_amount || 0),
        lpAmount: BigInt(p.lp_amount || 0),
        timestampMs: ts,
      },
    });
  }

  private async handleLiquidityRemove(
    txDigest: string,
    p: Record<string, any>,
    ts: bigint
  ) {
    const poolId = String(p.pool_id);
    const market = await this.prisma.market.findFirst({ where: { poolId } });
    if (!market) return;

    await this.prisma.liquidityEvent.create({
      data: {
        txDigest,
        marketId: market.id,
        poolId,
        provider: String(p.provider),
        action: "remove",
        syAmount: BigInt(p.sy_amount || 0),
        ptAmount: BigInt(p.pt_amount || 0),
        lpAmount: BigInt(p.lp_amount || 0),
        timestampMs: ts,
      },
    });
  }

  private async handleFeeCollection(
    txDigest: string,
    p: Record<string, any>,
    ts: bigint
  ) {
    await this.prisma.feeCollection.create({
      data: {
        txDigest,
        source: String(p.source || "swap"),
        poolId: p.pool_id ? String(p.pool_id) : null,
        amount: BigInt(p.amount || 0),
        coinType: String(p.coin_type || ""),
        timestampMs: ts,
      },
    });
  }

  private async handlePoolCreated(p: Record<string, any>) {
    const marketId = String(p.market_config_id);
    const poolId = String(p.pool_id);

    // Link pool to market
    try {
      await this.prisma.market.update({
        where: { id: marketId },
        data: { poolId },
      });
      console.log(`Linked pool ${poolId.slice(0, 10)}... to market ${marketId.slice(0, 10)}...`);
    } catch {
      // Market may not exist in DB yet
    }
  }

  // ── Helpers ──

  private async ensureVault(vaultId: string, p: Record<string, any>) {
    await this.prisma.syVault.upsert({
      where: { id: vaultId },
      create: {
        id: vaultId,
        coinType: String(p.coin_type || "0x2::sui::SUI"),
        underlyingSymbol: String(p.symbol || "SUI"),
        exchangeRate: BigInt(p.exchange_rate || "1000000000000000000"),
      },
      update: {},
    });
  }

  private async ensureMarket(marketId: string) {
    const exists = await this.prisma.market.findUnique({
      where: { id: marketId },
    });
    if (!exists) {
      // Create a placeholder — will be populated by sync job
      await this.prisma.market.create({
        data: {
          id: marketId,
          vaultId: "unknown",
          coinType: "0x2::sui::SUI",
          underlyingSymbol: "SUI",
          maturityMs: 0n,
          durationMonths: 0,
        },
      }).catch(() => {
        // May fail if vault doesn't exist — that's ok, sync job will fix
      });
    }
  }

  private async upsertUser(
    address: string,
    eventType: string,
    p: Record<string, any>
  ) {
    const swapVol =
      eventType === "Swapped"
        ? BigInt(p.sy_in || 0) + BigInt(p.sy_out || 0)
        : 0n;
    const depositVol =
      eventType === "SYDeposited" ? BigInt(p.underlying_amount || 0) : 0n;

    try {
      await this.prisma.user.upsert({
        where: { id: address },
        create: {
          id: address,
          totalDeposited: depositVol,
          totalSwapVol: swapVol,
          swapCount: eventType === "Swapped" ? 1 : 0,
          mintCount: eventType === "PYMinted" ? 1 : 0,
        },
        update: {
          lastActiveAt: new Date(),
          totalDeposited: { increment: depositVol },
          totalSwapVol: { increment: swapVol },
          swapCount:
            eventType === "Swapped" ? { increment: 1 } : undefined,
          mintCount:
            eventType === "PYMinted" ? { increment: 1 } : undefined,
        },
      });
    } catch {
      // Non-critical — skip
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}

// ── Entry Point ──
const indexer = new CruxIndexer();

process.on("SIGINT", async () => {
  await indexer.stop();
  process.exit(0);
});

indexer.start().catch(console.error);
