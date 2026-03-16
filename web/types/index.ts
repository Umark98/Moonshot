// ============================================================
// Crux Protocol — Core Types
// ============================================================

/** Sui object ID (0x-prefixed hex string) */
export type ObjectId = string;

/** Sui address */
export type SuiAddress = string;

/** Timestamp in milliseconds */
export type TimestampMs = number;

// ----- SY (Standardized Yield) -----

export interface SYVault {
  id: ObjectId;
  coinType: string;
  totalUnderlying: bigint;
  totalSySupply: bigint;
  exchangeRate: bigint; // WAD
  createdAt: TimestampMs;
}

// ----- Yield Market -----

export interface YieldMarket {
  id: ObjectId;
  vaultId: ObjectId;
  coinType: string;
  maturityMs: TimestampMs;
  totalPtSupply: bigint;
  totalYtSupply: bigint;
  globalInterestIndex: bigint; // WAD
  isSettled: boolean;
  settlementRate: bigint; // WAD
  impliedRate: number; // display APY as percentage
  ptPrice: number; // in SY terms
  ytPrice: number;
}

export interface MarketSummary {
  id: ObjectId;
  poolId: ObjectId;
  syVaultId: ObjectId;
  coinType: string;
  underlyingSymbol: string;
  maturityMs: TimestampMs;
  impliedRate: number;
  ptPrice: number;
  tvl: number; // in token units
  volume24h: number;
  isSettled: boolean;
}

// ----- PT / YT Tokens -----

export interface PTToken {
  id: ObjectId;
  amount: bigint;
  maturityMs: TimestampMs;
  marketConfigId: ObjectId;
  coinType: string;
}

export interface YTToken {
  id: ObjectId;
  amount: bigint;
  maturityMs: TimestampMs;
  marketConfigId: ObjectId;
  coinType: string;
  userInterestIndex: bigint;
  accruedYield: bigint;
}

// ----- AMM Pool -----

export interface YieldPool {
  id: ObjectId;
  marketConfigId: ObjectId;
  ptReserve: bigint;
  syReserve: bigint;
  totalLpSupply: bigint;
  scalarRoot: bigint;
  initialAnchor: bigint;
  lnFeeRateRoot: bigint;
  lastLnImpliedRate: bigint;
}

// ----- Tranches -----

export interface TrancheVault {
  id: ObjectId;
  marketConfigId: ObjectId;
  seniorDeposits: bigint;
  juniorDeposits: bigint;
  seniorTargetRateWad: bigint;
  seniorCap: bigint;
  isActive: boolean;
}

export type TrancheType = "senior" | "junior";

export interface TranchePosition {
  id: ObjectId;
  vaultId: ObjectId;
  tranche: TrancheType;
  depositAmount: bigint;
  depositTimestamp: TimestampMs;
}

// ----- Collateral -----

export interface CollateralPosition {
  positionIndex: number;
  owner: SuiAddress;
  ptAmount: bigint;
  syBorrowed: bigint;
  ltv: number;
  healthFactor: number;
}

// ----- Governance -----

export interface Proposal {
  id: number;
  proposer: SuiAddress;
  title: string;
  description: string;
  forVotes: bigint;
  againstVotes: bigint;
  startTime: TimestampMs;
  endTime: TimestampMs;
  executed: boolean;
  status: "active" | "passed" | "failed" | "executed";
}

export interface GaugeInfo {
  index: number;
  poolId: ObjectId;
  votes: bigint;
  share: number; // 0-1
  emissions: number;
}

// ----- Portfolio -----

export interface UserPortfolio {
  address: SuiAddress;
  ptPositions: PTToken[];
  ytPositions: YTToken[];
  lpPositions: LPPosition[];
  tranchePositions: TranchePosition[];
  collateralPositions: CollateralPosition[];
  totalValueUsd: number;
  totalYieldEarned: number;
}

export interface LPPosition {
  id: ObjectId;
  poolId: ObjectId;
  lpAmount: bigint;
  ptShare: bigint;
  syShare: bigint;
}

// ----- Yield Curve -----

export interface YieldCurvePoint {
  maturityMs: TimestampMs;
  impliedRate: number;
  ptPrice: number;
  daysToMaturity: number;
  label: string;
}

// ----- Swap -----

export interface SwapQuote {
  amountIn: bigint;
  amountOut: bigint;
  priceImpact: number;
  fee: bigint;
  impliedRateAfter: number;
  route: "pt_to_sy" | "sy_to_pt";
}

// ----- Stats -----

export interface ProtocolStats {
  totalTvl: number;
  totalVolume24h: number;
  totalMarkets: number;
  activeMarkets: number;
  totalUsers: number;
  totalFees24h: number;
}

// ----- Transaction -----

export interface TxResult {
  digest: string;
  success: boolean;
  error?: string;
}
