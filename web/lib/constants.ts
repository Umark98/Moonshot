// ============================================================
// Crux Protocol — Constants
// ============================================================

/** WAD = 1e18 for fixed-point math */
export const WAD = BigInt("1000000000000000000");

/** Package ID — updated after deployment */
export const PACKAGE_ID =
  process.env.NEXT_PUBLIC_PACKAGE_ID ??
  "0x0000000000000000000000000000000000000000000000000000000000000000";

/** Network */
export const SUI_NETWORK = (process.env.NEXT_PUBLIC_SUI_NETWORK ??
  "testnet") as "mainnet" | "testnet" | "devnet";

/** RPC URL — override with NEXT_PUBLIC_SUI_RPC_URL, otherwise derive from network */
export const SUI_RPC_URL =
  process.env.NEXT_PUBLIC_SUI_RPC_URL ?? "";

/** Module names */
export const MODULES = {
  standardized_yield: `${PACKAGE_ID}::standardized_yield`,
  yield_tokenizer: `${PACKAGE_ID}::yield_tokenizer`,
  rate_market: `${PACKAGE_ID}::rate_market`,
  router: `${PACKAGE_ID}::router`,
  flash_mint: `${PACKAGE_ID}::flash_mint`,
  tranche_engine: `${PACKAGE_ID}::tranche_engine`,
  pt_collateral: `${PACKAGE_ID}::pt_collateral`,
  permissionless_market: `${PACKAGE_ID}::permissionless_market`,
  gauge_voting: `${PACKAGE_ID}::gauge_voting`,
  governor: `${PACKAGE_ID}::governor`,
  fee_collector: `${PACKAGE_ID}::fee_collector`,
} as const;

/** Common object IDs (populated post-deployment) */
export const OBJECT_IDS = {
  registry: process.env.NEXT_PUBLIC_REGISTRY_ID ?? "",
  gaugeController: process.env.NEXT_PUBLIC_GAUGE_CONTROLLER_ID ?? "",
  feeCollector: process.env.NEXT_PUBLIC_FEE_COLLECTOR_ID ?? "",
};

/** Supported underlying assets */
export const SUPPORTED_ASSETS = [
  {
    symbol: "SUI",
    name: "Sui",
    coinType: "0x2::sui::SUI",
    icon: "/icons/sui.svg",
    decimals: 9,
    color: "#4DA2FF",
  },
  {
    symbol: "haSUI",
    name: "Haedal Staked SUI",
    coinType: "0xhaedal::hasui::HASUI",
    icon: "/icons/hasui.svg",
    decimals: 9,
    color: "#4FC3F7",
  },
  {
    symbol: "sSUI",
    name: "Suilend SUI",
    coinType: "0xsuilend::ssui::SSUI",
    icon: "/icons/ssui.svg",
    decimals: 9,
    color: "#7C4DFF",
  },
  {
    symbol: "nSUI",
    name: "NAVI SUI",
    coinType: "0xnavi::nsui::NSUI",
    icon: "/icons/nsui.svg",
    decimals: 9,
    color: "#00BFA5",
  },
] as const;

/** Standard maturity durations in milliseconds */
export const MATURITIES = {
  "1M": 2_629_800_000,
  "3M": 7_889_400_000,
  "6M": 15_778_800_000,
  "1Y": 31_557_600_000,
} as const;

/** Navigation items */
export const NAV_ITEMS = [
  { label: "Dashboard", href: "/dashboard", icon: "LayoutDashboard" },
  { label: "Earn", href: "/earn", icon: "TrendingUp" },
  { label: "Trade", href: "/trade", icon: "ArrowLeftRight" },
  { label: "Mint / Redeem", href: "/mint", icon: "Coins" },
  { label: "Tranches", href: "/tranches", icon: "Layers" },
  { label: "Portfolio", href: "/portfolio", icon: "Wallet" },
] as const;

/** Format helpers */
export function formatWad(wad: bigint, decimals = 4): string {
  const whole = wad / WAD;
  const frac = wad % WAD;
  const fracStr = frac.toString().padStart(18, "0").slice(0, decimals);
  return `${whole}.${fracStr}`;
}

export function formatRate(rate: number): string {
  return `${(rate * 100).toFixed(2)}%`;
}

export function formatUsd(amount: number): string {
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: 0,
  }).format(amount);
}

export function formatToken(amount: bigint, decimals = 9): string {
  const divisor = BigInt(10 ** decimals);
  const whole = amount / divisor;
  const frac = (amount % divisor).toString().padStart(decimals, "0").slice(0, 4);
  return `${whole.toLocaleString()}.${frac}`;
}

export function daysUntil(timestampMs: number): number {
  const now = Date.now();
  return Math.max(0, Math.ceil((timestampMs - now) / 86_400_000));
}

export function maturityLabel(timestampMs: number): string {
  const days = daysUntil(timestampMs);
  if (days <= 0) return "Matured";
  if (days <= 30) return `${days}d`;
  if (days <= 365) return `${Math.round(days / 30)}mo`;
  return `${(days / 365).toFixed(1)}y`;
}
