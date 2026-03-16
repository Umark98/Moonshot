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
 * Mint PT + YT from an owned Coin<T> (underlying).
 * Move: yield_tokenizer::mint_py<T>(config, vault, coin, clock, ctx) → (PT<T>, YT<T>)
 */
export function buildMintPY(
  configId: ObjectId,
  vaultId: ObjectId,
  coinObjectId: ObjectId,
  coinType: string,
): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: `${MODULES.yield_tokenizer}::mint_py`,
    typeArguments: [coinType],
    arguments: [
      tx.object(configId),
      tx.object(vaultId),
      tx.object(coinObjectId),
      tx.object("0x6"),
    ],
  });
  return tx;
}

/**
 * Split Coin<T> from gas → Mint PT+YT directly in one PTB.
 * mint_py now accepts Coin<T> (underlying) directly — no SY deposit step needed.
 */
export function buildDepositAndMint(
  vaultId: ObjectId,
  configId: ObjectId,
  amountMist: bigint,
  coinType: string,
): Transaction {
  const tx = new Transaction();
  const [coin] = tx.splitCoins(tx.gas, [tx.pure.u64(amountMist)]);

  // Mint PT + YT directly from Coin<T> (vault is read-only reference)
  tx.moveCall({
    target: `${MODULES.yield_tokenizer}::mint_py`,
    typeArguments: [coinType],
    arguments: [
      tx.object(configId),
      tx.object(vaultId),
      coin,
      tx.object("0x6"),
    ],
  });
  return tx;
}

/**
 * Swap Coin<T> (underlying) → PT on AMM.
 * Move: rate_market::swap_sy_for_pt<T>(pool, vault, config, coin, min_pt_out, clock, ctx) → PT<T>
 */
export function buildSwapSyToPt(
  poolId: ObjectId,
  vaultId: ObjectId,
  configId: ObjectId,
  coinObjectId: ObjectId,
  minPtOut: bigint,
  coinType: string,
): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: `${MODULES.rate_market}::swap_sy_for_pt`,
    typeArguments: [coinType],
    arguments: [
      tx.object(poolId),
      tx.object(vaultId),
      tx.object(configId),
      tx.object(coinObjectId),
      tx.pure.u64(minPtOut),
      tx.object("0x6"),
    ],
  });
  return tx;
}

/**
 * Swap PT → Coin<T> (underlying) on AMM.
 * Move: rate_market::swap_pt_for_sy<T>(pool, vault, config, pt_in, min_underlying_out, clock, ctx) → Coin<T>
 */
export function buildSwapPtToSy(
  poolId: ObjectId,
  vaultId: ObjectId,
  configId: ObjectId,
  ptTokenId: ObjectId,
  minUnderlyingOut: bigint,
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
      tx.pure.u64(minUnderlyingOut),
      tx.object("0x6"),
    ],
  });
  return tx;
}

/**
 * Split Coin<T> from gas → Swap underlying for PT in one PTB.
 * swap_sy_for_pt now accepts Coin<T> directly — no SY deposit step needed.
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

  tx.moveCall({
    target: `${MODULES.rate_market}::swap_sy_for_pt`,
    typeArguments: [coinType],
    arguments: [
      tx.object(poolId),
      tx.object(vaultId),
      tx.object(configId),
      coin,
      tx.pure.u64(minPtOut),
      tx.object("0x6"),
    ],
  });
  return tx;
}

/**
 * Redeem PT + YT → Coin<T> (underlying, pre-maturity).
 * Move: yield_tokenizer::redeem_py_pre_expiry<T>(config, vault, pt, yt, ctx) → Coin<T>
 */
export function buildRedeemPY(
  configId: ObjectId,
  vaultId: ObjectId,
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
      tx.object(vaultId),
      tx.object(ptTokenId),
      tx.object(ytTokenId),
    ],
  });
  return tx;
}

/**
 * Redeem PT → Coin<T> (underlying, post-maturity).
 * Move: yield_tokenizer::redeem_pt_post_expiry<T>(config, pt) → Coin<T>
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
 * Move: rate_market::add_liquidity<T>(pool, vault, underlying: Coin<T>, pt_amount: u64, sy_amount: u64, clock, ctx) → LPToken<T>
 */
export function buildAddLiquidity(
  poolId: ObjectId,
  vaultId: ObjectId,
  configId: ObjectId,
  coinObjectId: ObjectId,
  ptAmount: bigint,
  syAmount: bigint,
  coinType: string,
): Transaction {
  const tx = new Transaction();
  tx.moveCall({
    target: `${MODULES.rate_market}::add_liquidity`,
    typeArguments: [coinType],
    arguments: [
      tx.object(poolId),
      tx.object(vaultId),
      tx.object(coinObjectId),
      tx.pure.u64(ptAmount),
      tx.pure.u64(syAmount),
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
