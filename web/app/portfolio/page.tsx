"use client";

import { useCurrentAccount } from "@mysten/dapp-kit";
import { motion } from "framer-motion";
import { ConnectWalletButton } from "@/components/ui/ConnectWalletButton";
import { usePositions } from "@/hooks/usePositions";
import { formatRate, daysUntil } from "@/lib/constants";
import {
  Wallet,
  TrendingUp,
  Clock,
  DollarSign,
  Calendar,
  Loader2,
  Inbox,
  ArrowUpRight,
  Shield,
  Zap,
  Droplets,
} from "lucide-react";
import { StatCard } from "@/components/ui/StatCard";

const stagger = {
  hidden: {},
  show: { transition: { staggerChildren: 0.06 } },
};

const fadeUp = {
  hidden: { opacity: 0, y: 12 },
  show: {
    opacity: 1,
    y: 0,
    transition: { duration: 0.4, ease: [0.16, 1, 0.3, 1] },
  },
};

interface Position {
  objectId: string;
  type: string;
  amount: number;
  amountFormatted: string;
  symbol?: string;
  duration?: string;
  maturityMs?: number;
  daysToMaturity?: number;
  impliedRate?: number;
  ptPrice?: number;
  ytPrice?: number;
  currentValue?: number;
  maturityValue?: number;
  profit?: number;
  accruedYield?: number;
  accruedYieldFormatted?: string;
  isSettled?: boolean;
  trancheType?: string;
  poolId?: string;
  marketConfigId?: string;
}

interface PositionsData {
  ptPositions: Position[];
  ytPositions: Position[];
  lpPositions: Position[];
  tranchePositions: Position[];
  summary: {
    totalPositions: number;
    totalPtValue: number;
    totalYtValue: number;
    totalLpValue: number;
    totalValue: number;
    totalAccruedYield: number;
  };
  maturities: Array<{
    type: string;
    symbol: string;
    duration: string;
    maturityMs: number;
    daysToMaturity: number;
    amount: string;
    isSettled: boolean;
  }>;
}

function PositionBadge({ type }: { type: string }) {
  const styles: Record<string, string> = {
    PT: "text-brand-400 bg-brand-500/10 ring-brand-500/20",
    YT: "text-accent-amber bg-accent-amber/10 ring-accent-amber/20",
    LP: "text-accent-cyan bg-accent-cyan/10 ring-accent-cyan/20",
    Tranche:
      "text-violet-400 bg-violet-400/10 ring-violet-400/20",
  };
  return (
    <span
      className={`rounded-md px-2 py-0.5 text-overline font-bold ring-1 ${styles[type] ?? styles.PT}`}
    >
      {type}
    </span>
  );
}

function PositionRow({ pos, index }: { pos: Position; index: number }) {
  const isPT = pos.type === "PT";
  const isYT = pos.type === "YT";
  const isLP = pos.type === "LP";

  return (
    <motion.div
      initial={{ opacity: 0, x: -8 }}
      animate={{ opacity: 1, x: 0 }}
      transition={{ delay: index * 0.04 }}
      className="flex items-center gap-4 px-6 py-4 transition-colors hover:bg-white/[0.02]"
    >
      {/* Badge + Symbol */}
      <div className="flex items-center gap-3 min-w-[120px]">
        <PositionBadge type={pos.type} />
        <div>
          <p className="text-body-sm font-semibold text-white">
            {pos.symbol ?? "SUI"}
          </p>
          <p className="text-caption text-zinc-600">
            {pos.duration ?? ""}
            {pos.isSettled && (
              <span className="ml-1 text-accent-amber">Matured</span>
            )}
          </p>
        </div>
      </div>

      {/* Amount */}
      <div className="flex-1 text-right">
        <p className="mono-number text-body-sm font-semibold text-white">
          {pos.amountFormatted} {pos.type}
        </p>
        {isPT && pos.maturityValue != null && (
          <p className="mono-number text-caption text-zinc-500">
            {pos.maturityValue.toFixed(4)} SUI at maturity
          </p>
        )}
        {isYT && pos.accruedYieldFormatted && (
          <p className="mono-number text-caption text-accent-green">
            +{pos.accruedYieldFormatted} yield accrued
          </p>
        )}
        {isLP && (
          <p className="mono-number text-caption text-zinc-500">LP shares</p>
        )}
      </div>

      {/* Rate / Price */}
      <div className="hidden sm:block text-right min-w-[80px]">
        {(isPT || isYT) && pos.impliedRate != null && (
          <>
            <p className="mono-number text-body-sm text-white">
              {formatRate(pos.impliedRate)}
            </p>
            <p className="text-caption text-zinc-600">APY</p>
          </>
        )}
        {isLP && pos.impliedRate != null && (
          <>
            <p className="mono-number text-body-sm text-white">
              {formatRate(pos.impliedRate)}
            </p>
            <p className="text-caption text-zinc-600">Pool APY</p>
          </>
        )}
      </div>

      {/* Maturity countdown */}
      <div className="hidden md:block text-right min-w-[80px]">
        {pos.daysToMaturity != null && (
          <>
            <p
              className={`mono-number text-body-sm ${
                pos.daysToMaturity <= 7
                  ? "text-accent-amber"
                  : "text-zinc-300"
              }`}
            >
              {pos.isSettled ? "Settled" : `${pos.daysToMaturity}d`}
            </p>
            <p className="text-caption text-zinc-600">
              {pos.isSettled ? "Redeemable" : "to maturity"}
            </p>
          </>
        )}
      </div>

      {/* P&L for PT */}
      <div className="hidden lg:block text-right min-w-[80px]">
        {isPT && pos.profit != null && (
          <>
            <p
              className={`mono-number text-body-sm font-semibold ${
                pos.profit > 0 ? "text-accent-green" : "text-zinc-400"
              }`}
            >
              {pos.profit > 0 ? "+" : ""}
              {pos.profit.toFixed(4)}
            </p>
            <p className="text-caption text-zinc-600">est. profit</p>
          </>
        )}
        {isYT && (
          <>
            <p className="mono-number text-body-sm text-accent-green">
              +{pos.accruedYieldFormatted}
            </p>
            <p className="text-caption text-zinc-600">earned</p>
          </>
        )}
      </div>
    </motion.div>
  );
}

export default function PortfolioPage() {
  const account = useCurrentAccount();
  const { data, isLoading } = usePositions();
  const positions = data as PositionsData | null;

  if (!account) {
    return (
      <motion.div
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.5, ease: [0.16, 1, 0.3, 1] }}
        className="flex h-96 flex-col items-center justify-center text-center"
      >
        <div className="rounded-2xl bg-white/[0.03] border border-white/[0.06] p-6 mb-6">
          <Wallet className="h-10 w-10 text-zinc-600" />
        </div>
        <h2 className="text-display-sm text-white">Connect Your Wallet</h2>
        <p className="mt-2 text-body-md text-zinc-500 max-w-sm">
          Connect your Sui wallet to view your Crux positions, P&L, and
          maturity calendar.
        </p>
        <div className="mt-6">
          <ConnectWalletButton className="btn-primary px-8 py-3" />
        </div>
      </motion.div>
    );
  }

  if (isLoading) {
    return (
      <div className="flex h-96 items-center justify-center">
        <Loader2 className="h-6 w-6 animate-spin text-zinc-500" />
      </div>
    );
  }

  const summary = positions?.summary ?? {
    totalPositions: 0,
    totalPtValue: 0,
    totalYtValue: 0,
    totalLpValue: 0,
    totalValue: 0,
    totalAccruedYield: 0,
  };

  const allPositions: Position[] = [
    ...(positions?.ptPositions ?? []),
    ...(positions?.ytPositions ?? []),
    ...(positions?.lpPositions ?? []),
    ...(positions?.tranchePositions ?? []),
  ];

  const hasPositions = allPositions.length > 0;
  const maturities = positions?.maturities ?? [];
  const upcomingMaturities = maturities.filter((m) => !m.isSettled).slice(0, 5);
  const settledMaturities = maturities.filter((m) => m.isSettled);

  return (
    <motion.div
      className="space-y-8"
      initial="hidden"
      animate="show"
      variants={stagger}
    >
      <motion.div variants={fadeUp}>
        <h2 className="text-display-md text-white">Portfolio</h2>
        <p className="mt-1 text-body-md text-zinc-500">
          All your Crux positions in one place
        </p>
      </motion.div>

      {/* Summary Stats */}
      <motion.div
        variants={fadeUp}
        className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4"
      >
        <StatCard
          label="Total Value"
          value={summary.totalValue}
          prefix=""
          suffix=" SUI"
          icon={DollarSign}
          decimals={4}
        />
        <StatCard
          label="PT Holdings"
          value={summary.totalPtValue}
          suffix=" SUI"
          icon={Shield}
          decimals={4}
        />
        <StatCard
          label="YT Holdings"
          value={summary.totalYtValue}
          suffix=" SUI"
          icon={Zap}
          decimals={4}
        />
        <StatCard
          label="Yield Earned"
          value={summary.totalAccruedYield}
          suffix=" SUI"
          icon={TrendingUp}
          decimals={4}
        />
      </motion.div>

      {/* Position List */}
      {hasPositions ? (
        <motion.div variants={fadeUp} className="glass-card overflow-hidden p-0">
          {/* Table Header */}
          <div className="flex items-center gap-4 border-b border-white/[0.06] px-6 py-3 text-overline text-zinc-500">
            <div className="min-w-[120px]">POSITION</div>
            <div className="flex-1 text-right">AMOUNT</div>
            <div className="hidden sm:block text-right min-w-[80px]">RATE</div>
            <div className="hidden md:block text-right min-w-[80px]">
              MATURITY
            </div>
            <div className="hidden lg:block text-right min-w-[80px]">P&L</div>
          </div>

          <div className="divide-y divide-white/[0.03]">
            {allPositions.map((pos, i) => (
              <PositionRow key={pos.objectId} pos={pos} index={i} />
            ))}
          </div>
        </motion.div>
      ) : (
        <motion.div
          variants={fadeUp}
          className="glass-card flex flex-col items-center justify-center py-16 text-center"
        >
          <Inbox className="mb-3 h-8 w-8 text-zinc-700" />
          <p className="text-body-sm font-medium text-zinc-400">
            No positions found
          </p>
          <p className="mt-1 text-caption text-zinc-600">
            Your PT, YT, LP, and tranche positions will appear here after you
            make your first deposit
          </p>
          <div className="mt-6 flex gap-3">
            <a
              href="/earn"
              className="btn-primary flex items-center gap-1.5 px-5 py-2 text-body-sm"
            >
              <Shield className="h-4 w-4" />
              Earn Fixed Rate
            </a>
            <a
              href="/trade"
              className="btn-ghost flex items-center gap-1.5 px-5 py-2 text-body-sm"
            >
              <ArrowUpRight className="h-4 w-4" />
              Trade PT/YT
            </a>
          </div>
        </motion.div>
      )}

      {/* Upcoming Maturities */}
      {upcomingMaturities.length > 0 && (
        <motion.div variants={fadeUp} className="glass-card p-6">
          <div className="flex items-center gap-2 mb-5">
            <Calendar className="h-4 w-4 text-zinc-500" />
            <p className="text-overline text-zinc-500">UPCOMING MATURITIES</p>
          </div>
          <div className="space-y-3">
            {upcomingMaturities.map((m, i) => (
              <div
                key={`${m.type}-${m.maturityMs}-${i}`}
                className="flex items-center justify-between rounded-lg bg-white/[0.02] px-4 py-3"
              >
                <div className="flex items-center gap-3">
                  <PositionBadge type={m.type} />
                  <div>
                    <p className="text-body-sm font-medium text-white">
                      {m.symbol} {m.duration}
                    </p>
                    <p className="text-caption text-zinc-500">
                      {m.amount} {m.type}
                    </p>
                  </div>
                </div>
                <div className="text-right">
                  <p
                    className={`mono-number text-body-sm font-semibold ${
                      m.daysToMaturity <= 7
                        ? "text-accent-amber"
                        : "text-white"
                    }`}
                  >
                    {m.daysToMaturity}d
                  </p>
                  <p className="text-caption text-zinc-600">remaining</p>
                </div>
              </div>
            ))}
          </div>
        </motion.div>
      )}

      {/* Settled / Redeemable */}
      {settledMaturities.length > 0 && (
        <motion.div variants={fadeUp} className="glass-card p-6">
          <div className="flex items-center gap-2 mb-5">
            <Clock className="h-4 w-4 text-accent-green" />
            <p className="text-overline text-accent-green">
              REDEEMABLE POSITIONS
            </p>
          </div>
          <div className="space-y-3">
            {settledMaturities.map((m, i) => (
              <div
                key={`settled-${m.type}-${i}`}
                className="flex items-center justify-between rounded-lg bg-accent-green/[0.03] border border-accent-green/10 px-4 py-3"
              >
                <div className="flex items-center gap-3">
                  <PositionBadge type={m.type} />
                  <p className="text-body-sm font-medium text-white">
                    {m.amount} {m.type} {m.symbol}
                  </p>
                </div>
                <a
                  href="/mint"
                  className="rounded-lg bg-accent-green/10 px-3 py-1.5 text-caption font-semibold text-accent-green hover:bg-accent-green/20 transition-colors"
                >
                  Redeem
                </a>
              </div>
            ))}
          </div>
        </motion.div>
      )}
    </motion.div>
  );
}
