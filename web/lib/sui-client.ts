// ============================================================
// Crux Protocol — Sui Client & Transaction Builders
// ============================================================

import { SuiClient, getFullnodeUrl } from "@mysten/sui/client";
import { Transaction } from "@mysten/sui/transactions";
import { PACKAGE_ID, MODULES, SUI_NETWORK, SUI_RPC_URL } from "./constants";
import type { ObjectId } from "@/types";

/** Resolved RPC URL — env override or derived from network */
export const RPC_URL = SUI_RPC_URL || getFullnodeUrl(SUI_NETWORK);

// Singleton client
let _client: SuiClient | null = null;

export function getSuiClient(): SuiClient {
  if (!_client) {
    _client = new SuiClient({ url: RPC_URL });
  }
  return _client;
}

// ---- Transaction Builders ----

/**
 * One-click fixed-rate deposit via Router.
 * Flow: split Coin<SUI> → deposit into SYVault → swap SY for PT on AMM → PT transferred to user
 * Move: router::fixed_rate_deposit<T>(vault, pool, config, coin, min_pt_out, clock, ctx)
 */
export function buildFixedRateDeposit(
  vaultId: ObjectId,
  poolId: ObjectId,
  configId: ObjectId,
  amountMist: bigint,
  minPtOut: bigint,
  coinType: string,
): Transaction {
  const tx = new Transaction();
  // Split exact amount from gas coin
  const [coin] = tx.splitCoins(tx.gas, [tx.pure.u64(amountMist)]);
  tx.moveCall({
    target: `${MODULES.router}::fixed_rate_deposit`,
    typeArguments: [coinType],
    arguments: [
      tx.object(vaultId),
      tx.object(poolId),
      tx.object(configId),
      coin,
      tx.pure.u64(minPtOut),
      tx.object("0x6"),
    ],
  });
  return tx;
}

/**
 * Deposit underlying → SY (wrap).
 * Move: standardized_yield::deposit<T>(vault, coin, ctx) → SYToken<T>
 */
export function buildDeposit(
  vaultId: ObjectId,
  amountMist: bigint,
  coinType: string,
): Transaction {
  const tx = new Transaction();
  const [coin] = tx.splitCoins(tx.gas, [tx.pure.u64(amountMist)]);
  tx.moveCall({
    target: `${MODULES.standardized_yield}::deposit`,
    typeArguments: [coinType],
    arguments: [tx.object(vaultId), coin],
  });
  return tx;
}

/**
 * Mint PT + YT from an owned SYToken.
 * Move: yield_tokenizer::mint_py<T>(config, sy_token, clock, ctx) → (PT<T>, YT<T>)
 */
export function buildMintPY(
  configId: ObjectId,
  syTokenId: ObjectId,
  coinType: string,
): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: `${MODULES.yield_tokenizer}::mint_py`,
    typeArguments: [coinType],
    arguments: [
      tx.object(configId),
      tx.object(syTokenId),
      tx.object("0x6"),
    ],
  });
  return tx;
}

/**
 * Deposit underlying → SY → Mint PT+YT in one PTB.
 * Combines deposit + mint atomically.
 */
export function buildDepositAndMint(
  vaultId: ObjectId,
  configId: ObjectId,
  amountMist: bigint,
  coinType: string,
): Transaction {
  const tx = new Transaction();
  const [coin] = tx.splitCoins(tx.gas, [tx.pure.u64(amountMist)]);

  // Step 1: Deposit underlying → SY
  const [syToken] = tx.moveCall({
    target: `${MODULES.standardized_yield}::deposit`,
    typeArguments: [coinType],
    arguments: [tx.object(vaultId), coin],
  });

  // Step 2: Mint PT + YT from SY
  tx.moveCall({
    target: `${MODULES.yield_tokenizer}::mint_py`,
    typeArguments: [coinType],
    arguments: [
      tx.object(configId),
      syToken,
      tx.object("0x6"),
    ],
  });
  return tx;
}

/**
 * Swap SY → PT on AMM.
 * Move: rate_market::swap_sy_for_pt<T>(pool, config, sy_in, min_pt_out, clock, ctx) → PT<T>
 */
export function buildSwapSyToPt(
  poolId: ObjectId,
  configId: ObjectId,
  syTokenId: ObjectId,
  minPtOut: bigint,
  coinType: string,
): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: `${MODULES.rate_market}::swap_sy_for_pt`,
    typeArguments: [coinType],
    arguments: [
      tx.object(poolId),
      tx.object(configId),
      tx.object(syTokenId),
      tx.pure.u64(minPtOut),
      tx.object("0x6"),
    ],
  });
  return tx;
}

/**
 * Swap PT → SY on AMM.
 * Move: rate_market::swap_pt_for_sy<T>(pool, vault, config, pt_in, min_sy_out, clock, ctx) → SYToken<T>
 */
export function buildSwapPtToSy(
  poolId: ObjectId,
  vaultId: ObjectId,
  configId: ObjectId,
  ptTokenId: ObjectId,
  minSyOut: bigint,
  coinType: string,
): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: `${MODULES.rate_market}::swap_pt_for_sy`,
    typeArguments: [coinType],
    arguments: [
      tx.object(poolId),
      tx.object(vaultId),
      tx.object(configId),
      tx.object(ptTokenId),
      tx.pure.u64(minSyOut),
      tx.object("0x6"),
    ],
  });
  return tx;
}

/**
 * Deposit underlying → SY → Swap SY for PT in one PTB.
 * For Trade page: user has SUI, wants PT.
 */
export function buildDepositAndSwapToPt(
  vaultId: ObjectId,
  poolId: ObjectId,
  configId: ObjectId,
  amountMist: bigint,
  minPtOut: bigint,
  coinType: string,
): Transaction {
  const tx = new Transaction();
  const [coin] = tx.splitCoins(tx.gas, [tx.pure.u64(amountMist)]);

  const [syToken] = tx.moveCall({
    target: `${MODULES.standardized_yield}::deposit`,
    typeArguments: [coinType],
    arguments: [tx.object(vaultId), coin],
  });

  tx.moveCall({
    target: `${MODULES.rate_market}::swap_sy_for_pt`,
    typeArguments: [coinType],
    arguments: [
      tx.object(poolId),
      tx.object(configId),
      syToken,
      tx.pure.u64(minPtOut),
      tx.object("0x6"),
    ],
  });
  return tx;
}

/**
 * Redeem PT + YT → SY (pre-maturity).
 * Move: yield_tokenizer::redeem_py_pre_expiry<T>(config, pt, yt, ctx) → u64
 */
export function buildRedeemPY(
  configId: ObjectId,
  ptTokenId: ObjectId,
  ytTokenId: ObjectId,
  coinType: string,
): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: `${MODULES.yield_tokenizer}::redeem_py_pre_expiry`,
    typeArguments: [coinType],
    arguments: [
      tx.object(configId),
      tx.object(ptTokenId),
      tx.object(ytTokenId),
    ],
  });
  return tx;
}

/**
 * Redeem PT → SY (post-maturity).
 * Move: yield_tokenizer::redeem_pt_post_expiry<T>(config, pt) → u64
 */
export function buildRedeemPtPostMaturity(
  configId: ObjectId,
  ptTokenId: ObjectId,
  coinType: string,
): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: `${MODULES.yield_tokenizer}::redeem_pt_post_expiry`,
    typeArguments: [coinType],
    arguments: [tx.object(configId), tx.object(ptTokenId)],
  });
  return tx;
}

/**
 * Add liquidity to AMM.
 * Move: rate_market::add_liquidity<T>(pool, config, sy, pt, clock, ctx) → LPToken<T>
 */
export function buildAddLiquidity(
  poolId: ObjectId,
  configId: ObjectId,
  syTokenId: ObjectId,
  ptTokenId: ObjectId,
  coinType: string,
): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: `${MODULES.rate_market}::add_liquidity`,
    typeArguments: [coinType],
    arguments: [
      tx.object(poolId),
      tx.object(configId),
      tx.object(syTokenId),
      tx.object(ptTokenId),
      tx.object("0x6"),
    ],
  });
  return tx;
}

/**
 * Deposit into tranche (senior or junior).
 * Move: tranche_engine::deposit_senior/deposit_junior(vault, sy_amount, clock, ctx)
 */
export function buildTrancheDeposit(
  vaultId: ObjectId,
  syAmount: bigint,
  isSenior: boolean,
  coinType: string,
): Transaction {
  const tx = new Transaction();
  const fn = isSenior ? "deposit_senior" : "deposit_junior";
  tx.moveCall({
    target: `${MODULES.tranche_engine}::${fn}`,
    // tranche_engine functions are NOT generic (no type param)
    arguments: [
      tx.object(vaultId),
      tx.pure.u64(syAmount),
      tx.object("0x6"),
    ],
  });
  return tx;
}

/** Fetch owned objects of a type */
export async function fetchOwnedObjects(
  owner: string,
  structType: string,
): Promise<{ objectId: string; data: unknown }[]> {
  const client = getSuiClient();
  const resp = await client.getOwnedObjects({
    owner,
    filter: { StructType: structType },
    options: { showContent: true },
  });
  return resp.data
    .filter((o) => o.data)
    .map((o) => ({
      objectId: o.data!.objectId,
      data: (o.data!.content as { fields: unknown })?.fields,
    }));
}

/** Fetch a shared object */
export async function fetchObject(objectId: string) {
  const client = getSuiClient();
  return client.getObject({
    id: objectId,
    options: { showContent: true },
  });
}
