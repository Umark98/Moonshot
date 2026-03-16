"use client";

import Link from "next/link";
import { motion } from "framer-motion";
import { TokenIcon } from "./TokenIcon";
import { formatRate, formatUsd, daysUntil } from "@/lib/constants";
import { ArrowUpRight } from "lucide-react";
import type { MarketSummary } from "@/types";

interface MarketRowProps {
  market: MarketSummary;
  index?: number;
}

export function MarketRow({ market, index = 0 }: MarketRowProps) {
  const days = daysUntil(market.maturityMs);

  return (
    <motion.div
      initial={{ opacity: 0, y: 6 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ delay: index * 0.05, duration: 0.3, ease: [0.16, 1, 0.3, 1] }}
    >
      <Link
        href={`/trade?market=${market.id}`}
        className="group flex items-center justify-between rounded-2xl border border-white/[0.04] bg-white/[0.02] px-5 py-4 transition-all duration-300 ease-out hover:border-white/[0.08] hover:bg-white/[0.04]"
      >
        <div className="flex items-center gap-4">
          <TokenIcon symbol={market.underlyingSymbol} size="lg" />
          <div>
            <div className="flex items-center gap-2">
              <span className="text-body-md font-semibold text-white">
                PT-{market.underlyingSymbol}
              </span>
              {market.isSettled && <span className="badge-amber">Settled</span>}
            </div>
            <span className="text-caption text-zinc-500">
              {days > 0 ? `${days}d to maturity` : "Matured"}
            </span>
          </div>
        </div>

        <div className="flex items-center gap-10">
          <div className="text-right">
            <p className="text-overline text-zinc-500">FIXED APY</p>
            <p className="mono-number text-body-lg font-bold text-accent-green">
              {formatRate(market.impliedRate)}
            </p>
          </div>
          <div className="text-right hidden sm:block">
            <p className="text-overline text-zinc-500">PT PRICE</p>
            <p className="mono-number text-body-md text-white">
              {market.ptPrice.toFixed(4)}
            </p>
          </div>
          <div className="text-right hidden md:block">
            <p className="text-overline text-zinc-500">TVL</p>
            <p className="text-body-md text-zinc-300">{formatUsd(market.tvl)}</p>
          </div>
          <div className="text-right hidden lg:block">
            <p className="text-overline text-zinc-500">24H VOL</p>
            <p className="text-body-md text-zinc-300">
              {formatUsd(market.volume24h)}
            </p>
          </div>
          <ArrowUpRight className="h-4 w-4 text-zinc-600 transition-all duration-200 group-hover:text-brand-400 group-hover:translate-x-0.5 group-hover:-translate-y-0.5" />
        </div>
      </Link>
    </motion.div>
  );
}
