import { SuiClient, getFullnodeUrl } from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction } from '@mysten/sui/transactions';
import { CONFIG } from './config';

class CruxKeeper {
  private client: SuiClient;
  private keypair: Ed25519Keypair;
  private running = false;

  constructor() {
    this.client = new SuiClient({ url: CONFIG.rpcUrl });
    this.keypair = CONFIG.secretKey
      ? Ed25519Keypair.fromSecretKey(Buffer.from(CONFIG.secretKey, 'hex'))
      : new Ed25519Keypair();

    console.log(`Keeper address: ${this.keypair.getPublicKey().toSuiAddress()}`);
  }

  async start() {
    this.running = true;
    console.log('Crux Keeper Bot starting...');
    console.log(`RPC: ${CONFIG.rpcUrl}`);
    console.log(`Package: ${CONFIG.packageId}`);

    // Run loops concurrently
    await Promise.all([
      this.rateUpdateLoop(),
      this.maturityCheckLoop(),
      this.oracleUpdateLoop(),
    ]);
  }

  stop() {
    this.running = false;
    console.log('Keeper stopping...');
  }

  // === Rate Sync Loop ===
  // Fetches latest exchange rates from lending protocols and pushes on-chain
  private async rateUpdateLoop() {
    while (this.running) {
      try {
        await this.syncRates();
      } catch (err) {
        console.error('Rate sync error:', err);
      }
      await this.sleep(CONFIG.rateUpdateInterval);
    }
  }

  private async syncRates() {
    if (!CONFIG.packageId || !CONFIG.syVaultId) return;

    // In production, fetch actual rates from:
    // - Haedal: read StakingPool.exchange_rate
    // - Suilend: read Reserve.cToken_exchange_rate
    // - NAVI: read LendingPool.deposit_rate
    // - Scallop: read Market.sCoin_rate

    // For testnet, we simulate rate increases
    const simulatedRate = this.simulateRateIncrease();

    const tx = new Transaction();

    if (CONFIG.haedalAdapterId) {
      tx.moveCall({
        target: `${CONFIG.packageId}::haedal_adapter::sync_rate`,
        arguments: [
          tx.object(CONFIG.haedalAdapterId),
          tx.object(CONFIG.syVaultId),
          tx.pure.u128(simulatedRate),
          tx.object('0x6'), // Clock
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
      // Rate unchanged or too frequent — expected
      if (!err.message?.includes('EStaleRate')) {
        console.error('Rate sync failed:', err.message);
      }
    }
  }

  // === Maturity Check Loop ===
  // Settles expired markets
  private async maturityCheckLoop() {
    while (this.running) {
      try {
        await this.checkMaturities();
      } catch (err) {
        console.error('Maturity check error:', err);
      }
      await this.sleep(CONFIG.maturityCheckInterval);
    }
  }

  private async checkMaturities() {
    if (!CONFIG.packageId || !CONFIG.yieldMarketConfigId) return;

    const tx = new Transaction();
    tx.moveCall({
      target: `${CONFIG.packageId}::yield_tokenizer::settle_market`,
      arguments: [
        tx.object(CONFIG.yieldMarketConfigId),
        tx.object('0x6'), // Clock
      ],
    });

    try {
      const result = await this.client.signAndExecuteTransaction({
        signer: this.keypair,
        transaction: tx,
      });
      console.log(`Maturity settlement tx: ${result.digest}`);
    } catch (err: any) {
      // Not expired yet or already settled — expected
      if (!err.message?.includes('EMarketNotExpired') && !err.message?.includes('EAlreadySettled')) {
        console.error('Settlement failed:', err.message);
      }
    }
  }

  // === Oracle Update Loop ===
  // Pushes implied rate observations to the TWAP oracle
  private async oracleUpdateLoop() {
    while (this.running) {
      try {
        await this.updateOracle();
      } catch (err) {
        console.error('Oracle update error:', err);
      }
      await this.sleep(CONFIG.yieldAccrualInterval);
    }
  }

  private async updateOracle() {
    if (!CONFIG.packageId || !CONFIG.rateOracleId) return;
    // Oracle updates would read the current implied rate from the AMM pool
    // and push it to the rate oracle for TWAP tracking
    console.log('Oracle update: would push implied rate observation');
  }

  // === Helpers ===

  private simulateRateIncrease(): bigint {
    // Simulate ~7% APY: rate increases by ~0.00000022% per 30s
    // WAD = 1e18, 7% annual = 0.07, per 30s = 0.07 / (365.25 * 24 * 120) ≈ 6.65e-9
    const WAD = BigInt('1000000000000000000');
    const increment = WAD * BigInt(665) / BigInt(100_000_000_000); // ~6.65e-9 WAD
    return WAD + increment;
  }

  private sleep(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }
}

// Entry point
const keeper = new CruxKeeper();

process.on('SIGINT', () => {
  keeper.stop();
  process.exit(0);
});

keeper.start().catch(console.error);
