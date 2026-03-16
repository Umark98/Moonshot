"use client";

import { motion } from "framer-motion";
import {
  DollarSign,
  BarChart3,
  Users,
  Activity,
  ArrowUpRight,
  Loader2,
  DatabaseZap,
  CheckCircle2,
} from "lucide-react";
import { PACKAGE_ID } from "@/lib/constants";
import { StatCard } from "@/components/ui/StatCard";
import { MarketRow } from "@/components/ui/MarketRow";
import { YieldCurveChart } from "@/components/charts/YieldCurveChart";
import { useMarkets, useYieldCurve, useProtocolStats } from "@/hooks/useMarkets";
import { useState } from "react";
import { SUPPORTED_ASSETS } from "@/lib/constants";

const stagger = {
  hidden: {},
  show: { transition: { staggerChildren: 0.06 } },
};

const fadeUp = {
  hidden: { opacity: 0, y: 12 },
  show: { opacity: 1, y: 0, transition: { duration: 0.4, ease: [0.16, 1, 0.3, 1] } },
};

export default function DashboardPage() {
  const { data: stats, isLoading: statsLoading } = useProtocolStats();
  const [selectedAsset, setSelectedAsset] = useState("SUI");
  const { data: curve, isLoading: curveLoading } = useYieldCurve(selectedAsset);
  const { data: markets, isLoading: marketsLoading } = useMarkets();

  const s = stats ?? { totalTvl: 0, totalVolume24h: 0, totalMarkets: 0, activeMarkets: 0, totalUsers: 0, totalFees24h: 0 };
  const hasMarkets = markets && markets.length > 0;
  const hasCurve = curve && curve.length > 0;
  const isDeployed = PACKAGE_ID && !PACKAGE_ID.startsWith("0x00000000");

  return (
    <motion.div
      className="space-y-8"
      variants={stagger}
      initial="hidden"
      animate="show"
    >
      {/* Header */}
      <motion.div variants={fadeUp}>
        <h2 className="text-display-md text-white">Dashboard</h2>
        <p className="mt-1 text-body-md text-zinc-500">
          Sui&apos;s first DeFi yield curve — real-time market overview
        </p>
      </motion.div>

      {/* Deployment Status */}
      {isDeployed && !hasMarkets && !marketsLoading && (
        <motion.div variants={fadeUp} className="glass-card flex items-center gap-4 p-4">
          <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-accent-green/10">
            <CheckCircle2 className="h-5 w-5 text-accent-green" />
          </div>
          <div className="flex-1">
            <p className="text-body-sm font-semibold text-white">Contracts Deployed on Testnet</p>
            <p className="text-caption text-zinc-500">
              Package live at {PACKAGE_ID.slice(0, 10)}...{PACKAGE_ID.slice(-6)}. Create yield markets to start trading.
            </p>
          </div>
          <div className="flex items-center gap-1.5">
            <div className="h-2 w-2 animate-pulse-slow rounded-full bg-accent-green" />
            <span className="text-caption font-semibold text-accent-green">LIVE</span>
          </div>
        </motion.div>
      )}

      {/* Stats Grid */}
      <motion.div
        className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4"
        variants={stagger}
      >
        <motion.div variants={fadeUp}>
          <StatCard
            label="Total Value Locked"
            value={s.totalTvl}
            prefix="$"
            icon={DollarSign}
          />
        </motion.div>
        <motion.div variants={fadeUp}>
          <StatCard
            label="24h Volume"
            value={s.totalVolume24h}
            prefix="$"
            icon={BarChart3}
          />
        </motion.div>
        <motion.div variants={fadeUp}>
          <StatCard
            label="Active Markets"
            value={s.activeMarkets}
            suffix={s.totalMarkets > 0 ? ` / ${s.totalMarkets}` : ""}
            icon={Activity}
          />
        </motion.div>
        <motion.div variants={fadeUp}>
          <StatCard
            label="Total Users"
            value={s.totalUsers}
            icon={Users}
          />
        </motion.div>
      </motion.div>

      {/* Yield Curve */}
      <motion.div variants={fadeUp} className="glass-card p-6">
        <div className="mb-6 flex items-center justify-between">
          <div>
            <h3 className="text-display-sm text-white">Yield Curve</h3>
            <p className="mt-0.5 text-body-sm text-zinc-500">
              Implied fixed rates across maturities
            </p>
          </div>
          <div className="flex items-center gap-2">
            {SUPPORTED_ASSETS.map((asset) => (
              <button
                key={asset.symbol}
                onClick={() => setSelectedAsset(asset.symbol)}
                className={`rounded-full px-3.5 py-1.5 text-caption font-semibold transition-all duration-200 ${
                  selectedAsset === asset.symbol
                    ? "bg-brand-500/10 text-brand-400 ring-1 ring-brand-500/20"
                    : "text-zinc-500 hover:bg-white/[0.03] hover:text-zinc-300"
                }`}
              >
                {asset.symbol}
              </button>
            ))}
          </div>
        </div>

        {curveLoading ? (
          <div className="flex h-[340px] items-center justify-center">
            <Loader2 className="h-6 w-6 animate-spin text-zinc-500" />
          </div>
        ) : hasCurve ? (
          <>
            <YieldCurveChart data={curve} height={340} />
            <div className="mt-6 grid grid-cols-4 gap-4 border-t border-white/[0.04] pt-5">
              {curve.map((point) => (
                <div key={point.label} className="text-center">
                  <p className="text-overline text-zinc-500">{point.label}</p>
                  <p className="mono-number mt-1 text-body-lg font-bold text-white">
                    {(point.impliedRate * 100).toFixed(2)}%
                  </p>
                  <p className="mono-number text-caption text-zinc-500">
                    PT {point.ptPrice.toFixed(4)}
                  </p>
                </div>
              ))}
            </div>
          </>
        ) : (
          <div className="flex h-[340px] flex-col items-center justify-center text-center">
            <DatabaseZap className="mb-3 h-8 w-8 text-zinc-700" />
            <p className="text-body-sm font-medium text-zinc-400">No yield data available</p>
            <p className="mt-1 text-caption text-zinc-600">
              Yield curve will populate once yield markets are created
            </p>
          </div>
        )}
      </motion.div>

      {/* Markets */}
      <motion.div variants={fadeUp}>
        <div className="mb-4 flex items-center justify-between">
          <div>
            <h3 className="text-display-sm text-white">Active Markets</h3>
            <p className="mt-0.5 text-body-sm text-zinc-500">
              Trade PT/YT across all supported assets
            </p>
          </div>
          {hasMarkets && (
            <button className="btn-ghost text-body-sm">
              View All
              <ArrowUpRight className="h-4 w-4" />
            </button>
          )}
        </div>

        {marketsLoading ? (
          <div className="flex h-40 items-center justify-center">
            <Loader2 className="h-6 w-6 animate-spin text-zinc-500" />
          </div>
        ) : hasMarkets ? (
          <div className="space-y-2">
            {markets.map((m, i) => (
              <MarketRow key={m.id} market={m} index={i} />
            ))}
          </div>
        ) : (
          <div className="glass-card flex flex-col items-center justify-center py-16 text-center">
            <DatabaseZap className="mb-3 h-8 w-8 text-zinc-700" />
            <p className="text-body-sm font-medium text-zinc-400">No markets available</p>
            <p className="mt-1 text-caption text-zinc-600">
              Create your first yield market to start trading PT and YT
            </p>
          </div>
        )}
      </motion.div>
    </motion.div>
  );
}
