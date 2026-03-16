// ============================================================
// Crux Protocol — Keeper Bot (Prisma + Supabase)
// ============================================================
// Responsibilities:
// 1. Sync exchange rates from yield adapters → on-chain
// 2. Settle expired markets → on-chain
// 3. Snapshot pool state → database (for charts/analytics)
// 4. Aggregate daily stats → database

import { SuiClient, getFullnodeUrl } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";
import { PrismaClient } from "../../web/node_modules/@prisma/client";
import { CONFIG } from "./config";

class CruxKeeper {
  private client: SuiClient;
  private keypair: Ed25519Keypair | null;
  private prisma: PrismaClient;
  private running = false;

  constructor() {
    this.client = new SuiClient({ url: CONFIG.rpcUrl });
    this.prisma = new PrismaClient({ log: ["warn", "error"] });

    // Keypair is optional — needed for on-chain txs but not for snapshots
    if (CONFIG.secretKey) {
      this.keypair = Ed25519Keypair.fromSecretKey(
        Buffer.from(CONFIG.secretKey, "hex")
      );
      console.log(
        `Keeper address: ${this.keypair.getPublicKey().toSuiAddress()}`
      );
    } else {
      this.keypair = null;
      console.log("Keeper running in read-only mode (no secret key)");
    }
  }

  async start() {
    this.running = true;
    console.log("Crux Keeper Bot starting...");
    console.log(`RPC: ${CONFIG.rpcUrl}`);
    console.log(`Package: ${CONFIG.packageId}`);

    // Run loops concurrently
    await Promise.all([
      this.rateUpdateLoop(),
      this.maturityCheckLoop(),
      this.snapshotLoop(),
      this.dailyStatsLoop(),
    ]);
  }

  async stop() {
    this.running = false;
    await this.prisma.$disconnect();
    console.log("Keeper stopped.");
  }

  // ── Rate Sync Loop ──
  // Pushes exchange rate updates to SY vaults

  private async rateUpdateLoop() {
    while (this.running) {
      try {
        await this.syncRates();
      } catch (err) {
        console.error("Rate sync error:", err);
      }
      await this.sleep(CONFIG.rateUpdateInterval);
    }
  }

  private async syncRates() {
    if (!this.keypair || !CONFIG.packageId || !CONFIG.syVaultId) return;

    // Simulate rate increase (~7% APY)
    const simulatedRate = this.simulateRateIncrease();

    const tx = new Transaction();

    if (CONFIG.haedalAdapterId) {
      tx.moveCall({
        target: `${CONFIG.packageId}::haedal_adapter::sync_rate`,
        arguments: [
          tx.object(CONFIG.haedalAdapterId),
          tx.object(CONFIG.syVaultId),
          tx.pure.u128(simulatedRate),
          tx.object("0x6"),
        ],
      });
    }

    try {
      const result = await this.client.signAndExecuteTransaction({
        signer: this.keypair,
        transaction: tx,
      });
      console.log(`Rate sync tx: ${result.digest}`);
    } catch (err: any) {
      if (!err.message?.includes("EStaleRate")) {
        console.error("Rate sync failed:", err.message?.slice(0, 100));
      }
    }
  }

  // ── Maturity Check Loop ──
  // Settles expired markets

  private async maturityCheckLoop() {
    while (this.running) {
      try {
        await this.checkMaturities();
      } catch (err) {
        console.error("Maturity check error:", err);
      }
      await this.sleep(CONFIG.maturityCheckInterval);
    }
  }

  private async checkMaturities() {
    if (!this.keypair || !CONFIG.packageId) return;

    // Get all unsettled markets from DB
    const markets = await this.prisma.market.findMany({
      where: { isSettled: false },
      select: { id: true, maturityMs: true },
    });

    const now = Date.now();

    for (const market of markets) {
      if (Number(market.maturityMs) > now) continue;

      // This market has expired — try to settle
      const tx = new Transaction();
      tx.moveCall({
        target: `${CONFIG.packageId}::yield_tokenizer::settle_market`,
        typeArguments: ["0x2::sui::SUI"],
        arguments: [tx.object(market.id), tx.object("0x6")],
      });

      try {
        const result = await this.client.signAndExecuteTransaction({
          signer: this.keypair,
          transaction: tx,
        });
        console.log(
          `Settled market ${market.id.slice(0, 10)}... tx: ${result.digest}`
        );

        // Update DB
        await this.prisma.market.update({
          where: { id: market.id },
          data: { isSettled: true, settledAt: new Date() },
        });
      } catch (err: any) {
        if (
          !err.message?.includes("EMarketNotExpired") &&
          !err.message?.includes("EAlreadySettled")
        ) {
          console.error(
            `Settlement failed for ${market.id.slice(0, 10)}:`,
            err.message?.slice(0, 100)
          );
        }
      }
    }
  }

  // ── Snapshot Loop ──
  // Reads pool state from chain and writes analytics snapshots to DB

  private async snapshotLoop() {
    // Initial delay to let DB sync
    await this.sleep(5000);

    while (this.running) {
      try {
        await this.takeSnapshots();
      } catch (err) {
        console.error("Snapshot error:", err);
      }
      await this.sleep(CONFIG.snapshotInterval);
    }
  }

  private async takeSnapshots() {
    const markets = await this.prisma.market.findMany({
      where: { poolId: { not: null } },
      select: { id: true, poolId: true },
    });

    for (const market of markets) {
      if (!market.poolId) continue;

      try {
        const obj = await this.client.getObject({
          id: market.poolId,
          options: { showContent: true },
        });

        if (!obj.data?.content || !("fields" in obj.data.content)) continue;

        const fields = obj.data.content.fields as Record<string, any>;
        const ptReserve = Number(fields.pt_reserve ?? 0);
        const syReserve = Number(fields.sy_reserve ?? 0);
        const currentImpliedRate = Number(
          fields.current_implied_rate ?? 0
        );

        const impliedRate = currentImpliedRate > 0 ? currentImpliedRate / 1e18 : 0;
        const ptPrice = ptReserve > 0 ? syReserve / ptReserve : 1;
        const tvl = (ptReserve + syReserve) / 1e9;

        // Update market cached state
        await this.prisma.market.update({
          where: { id: market.id },
          data: {
            impliedRate,
            ptPrice,
            ytPrice: Math.max(0, 1 - ptPrice),
            tvl,
          },
        });

        // Write rate snapshot for charts
        await this.prisma.impliedRateSnapshot.create({
          data: {
            marketId: market.id,
            impliedRate,
            ptPrice,
            ptReserve: BigInt(fields.pt_reserve ?? 0),
            syReserve: BigInt(fields.sy_reserve ?? 0),
            tvl,
          },
        });

        console.log(
          `Snapshot ${market.id.slice(0, 10)}: rate=${(impliedRate * 100).toFixed(2)}% tvl=${tvl.toFixed(4)}`
        );
      } catch {
        // Pool not found or RPC error — skip
      }
    }

    // Volume snapshots: count swaps in last 24h per market
    const oneDayAgo = BigInt(Date.now() - 86_400_000);

    for (const market of markets) {
      const stats = await this.prisma.swap.aggregate({
        where: {
          marketId: market.id,
          timestampMs: { gte: oneDayAgo },
        },
        _count: true,
        _sum: { amountIn: true, fee: true },
      });

      const volume = Number(stats._sum.amountIn ?? 0n) / 1e9;
      const fees = Number(stats._sum.fee ?? 0n) / 1e9;

      await this.prisma.volumeSnapshot.create({
        data: {
          marketId: market.id,
          volume,
          swapCount: stats._count,
          fees,
        },
      });

      // Also update the market's volume24h
      await this.prisma.market.update({
        where: { id: market.id },
        data: { volume24h: volume },
      });
    }
  }

  // ── Daily Stats Aggregation ──

  private async dailyStatsLoop() {
    // Run once on startup, then every hour
    await this.sleep(10000);

    while (this.running) {
      try {
        await this.aggregateDailyStats();
      } catch (err) {
        console.error("Daily stats error:", err);
      }
      await this.sleep(3_600_000); // 1 hour
    }
  }

  private async aggregateDailyStats() {
    const today = new Date();
    today.setHours(0, 0, 0, 0);

    const startMs = BigInt(today.getTime());
    const endMs = BigInt(today.getTime() + 86_400_000);

    const [markets, swapAgg, mintCount, redeemCount, uniqueTraders, feeAgg] =
      await Promise.all([
        this.prisma.market.findMany({ select: { tvl: true } }),
        this.prisma.swap.aggregate({
          where: { timestampMs: { gte: startMs, lt: endMs } },
          _count: true,
          _sum: { amountIn: true },
        }),
        this.prisma.pyMint.count({
          where: { timestampMs: { gte: startMs, lt: endMs } },
        }),
        this.prisma.event.count({
          where: {
            eventType: { in: ["PTRedeemedPostExpiry", "PYRedeemed"] },
            timestampMs: { gte: startMs, lt: endMs },
          },
        }),
        this.prisma.swap
          .findMany({
            where: { timestampMs: { gte: startMs, lt: endMs } },
            select: { trader: true },
            distinct: ["trader"],
          })
          .then((r) => r.length),
        this.prisma.feeCollection.aggregate({
          where: { timestampMs: { gte: startMs, lt: endMs } },
          _sum: { amount: true },
        }),
      ]);

    const totalTvl = markets.reduce((s, m) => s + m.tvl, 0);
    const totalVolume = Number(swapAgg._sum.amountIn ?? 0n) / 1e9;
    const totalFees = Number(feeAgg._sum.amount ?? 0n) / 1e9;

    await this.prisma.dailyStats.upsert({
      where: { date: today },
      create: {
        date: today,
        totalTvl,
        totalVolume,
        totalSwaps: swapAgg._count,
        totalMints: mintCount,
        totalRedeems: redeemCount,
        uniqueUsers: uniqueTraders,
        totalFees,
      },
      update: {
        totalTvl,
        totalVolume,
        totalSwaps: swapAgg._count,
        totalMints: mintCount,
        totalRedeems: redeemCount,
        uniqueUsers: uniqueTraders,
        totalFees,
      },
    });

    console.log(
      `Daily stats: TVL=${totalTvl.toFixed(2)} Vol=${totalVolume.toFixed(2)} Swaps=${swapAgg._count} Users=${uniqueTraders}`
    );
  }

  // ── Helpers ──

  private simulateRateIncrease(): bigint {
    // ~7% APY: per 30s = 0.07 / (365.25 * 24 * 120) ~ 6.65e-9
    const WAD = BigInt("1000000000000000000");
    const increment = (WAD * BigInt(665)) / BigInt(100_000_000_000);
    return WAD + increment;
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}

// ── Entry Point ──
const keeper = new CruxKeeper();

process.on("SIGINT", async () => {
  await keeper.stop();
  process.exit(0);
});

keeper.start().catch(console.error);
