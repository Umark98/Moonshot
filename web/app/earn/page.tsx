"use client";

import { useState } from "react";
import { useCurrentAccount, useSignAndExecuteTransaction } from "@mysten/dapp-kit";
import { motion, AnimatePresence } from "framer-motion";
import { TokenIcon } from "@/components/ui/TokenIcon";
import { ConnectWalletButton } from "@/components/ui/ConnectWalletButton";
import { useMarkets } from "@/hooks/useMarkets";
import { useWalletBalance } from "@/hooks/useWalletBalance";
import { formatRate, daysUntil } from "@/lib/constants";
import { buildFixedRateDeposit } from "@/lib/sui-client";
import { Shield, Clock, Zap, ChevronRight, Lock, ArrowRight, Loader2, DatabaseZap } from "lucide-react";
import type { MarketSummary } from "@/types";

const fadeUp = {
  hidden: { opacity: 0, y: 12 },
  show: { opacity: 1, y: 0, transition: { duration: 0.4, ease: [0.16, 1, 0.3, 1] } },
};

export default function EarnPage() {
  const account = useCurrentAccount();
  const { mutateAsync: signAndExecute } = useSignAndExecuteTransaction();
  const { data: markets, isLoading } = useMarkets();
  const { balance, formatted: balanceFormatted } = useWalletBalance("0x2::sui::SUI");
  const [selectedMarket, setSelectedMarket] = useState<MarketSummary | null>(null);
  const [amount, setAmount] = useState("");
  const [loading, setLoading] = useState(false);
  const [txSuccess, setTxSuccess] = useState(false);
  const [txError, setTxError] = useState<string | null>(null);

  const activeMarkets = markets?.filter((m) => !m.isSettled) ?? [];
  const hasMarkets = activeMarkets.length > 0;

  const amountNum = Number(amount || "0");
  const amountMist = BigInt(Math.floor(amountNum * 1e9));
  const hasEnough = amountMist > BigInt(0) && amountMist <= balance;

  async function handleDeposit() {
    if (!selectedMarket || !amount || !account || !hasEnough) return;
    setLoading(true);
    setTxSuccess(false);
    setTxError(null);
    try {
      const tx = buildFixedRateDeposit(
        selectedMarket.syVaultId,
        selectedMarket.poolId,
        selectedMarket.id, // YieldMarketConfig ID
        amountMist,
        BigInt(0),
        selectedMarket.coinType,
      );
      const result = await signAndExecute({ transaction: tx });
      console.log("Deposit result:", result);
      setTxSuccess(true);
      setAmount("");
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error("Deposit failed:", msg);
      setTxError(msg.length > 200 ? msg.slice(0, 200) + "..." : msg);
    } finally {
      setLoading(false);
    }
  }

  const ptReceived = selectedMarket && amountNum > 0
    ? (amountNum / selectedMarket.ptPrice)
    : 0;
  const profit = ptReceived - amountNum;

  return (
    <motion.div className="space-y-8" initial="hidden" animate="show" variants={{ show: { transition: { staggerChildren: 0.06 } } }}>
      <motion.div variants={fadeUp}>
        <h2 className="text-display-md text-white">Fixed-Rate Earn</h2>
        <p className="mt-1 text-body-md text-zinc-500">
          Lock in guaranteed yields — one click, atomic via Sui PTBs
        </p>
      </motion.div>

      {/* How it works */}
      <motion.div variants={fadeUp} className="grid grid-cols-1 gap-4 md:grid-cols-3">
        {[
          { icon: Shield, color: "text-brand-400 bg-brand-500/10", title: "Guaranteed Rate", desc: "Buy PT at a discount. Redeem at face value at maturity. Zero impermanent loss." },
          { icon: Clock, color: "text-accent-green bg-accent-green/10", title: "Choose Duration", desc: "1 month to 1 year. Longer maturities offer higher rates." },
          { icon: Zap, color: "text-accent-cyan bg-accent-cyan/10", title: "Single Transaction", desc: "Deposit, wrap, and buy PT in one atomic PTB. No MEV risk." },
        ].map(({ icon: Icon, color, title, desc }) => (
          <div key={title} className="glass-card p-5 flex items-start gap-4">
            <div className={`rounded-xl p-2.5 ${color}`}>
              <Icon className="h-5 w-5" />
            </div>
            <div>
              <p className="text-body-sm font-semibold text-white">{title}</p>
              <p className="mt-1 text-caption text-zinc-500">{desc}</p>
            </div>
          </div>
        ))}
      </motion.div>

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-5">
        {/* Markets */}
        <motion.div variants={fadeUp} className="lg:col-span-3 space-y-3">
          <h3 className="text-display-sm text-white">Select Market</h3>

          {isLoading ? (
            <div className="flex h-40 items-center justify-center">
              <Loader2 className="h-6 w-6 animate-spin text-zinc-500" />
            </div>
          ) : hasMarkets ? (
            <div className="space-y-2">
              {activeMarkets.map((market, i) => (
                <motion.button
                  key={`${market.id}-${market.maturityMs}`}
                  initial={{ opacity: 0, y: 6 }}
                  animate={{ opacity: 1, y: 0 }}
                  transition={{ delay: i * 0.05 }}
                  onClick={() => setSelectedMarket(market)}
                  className={`group flex w-full items-center justify-between rounded-2xl border px-5 py-5 text-left transition-all duration-300 ${
                    selectedMarket?.maturityMs === market.maturityMs
                      ? "border-brand-500/40 bg-brand-500/5 shadow-glow-sm"
                      : "border-white/[0.04] bg-white/[0.02] hover:border-white/[0.08] hover:bg-white/[0.04]"
                  }`}
                >
                  <div className="flex items-center gap-4">
                    <TokenIcon symbol={market.underlyingSymbol} size="lg" />
                    <div>
                      <p className="text-body-md font-semibold text-white">
                        PT-{market.underlyingSymbol}
                      </p>
                      <p className="text-caption text-zinc-500">
                        {daysUntil(market.maturityMs)}d to maturity
                      </p>
                    </div>
                  </div>
                  <div className="flex items-center gap-6">
                    <div className="text-right">
                      <p className="mono-number text-body-lg font-bold text-accent-green">
                        {formatRate(market.impliedRate)}
                      </p>
                      <p className="text-overline text-zinc-500">FIXED APY</p>
                    </div>
                    <ChevronRight className={`h-5 w-5 transition-all duration-200 ${
                      selectedMarket?.maturityMs === market.maturityMs ? "text-brand-400 translate-x-0.5" : "text-zinc-600"
                    }`} />
                  </div>
                </motion.button>
              ))}
            </div>
          ) : (
            <div className="glass-card flex flex-col items-center justify-center py-16 text-center">
              <DatabaseZap className="mb-3 h-8 w-8 text-zinc-700" />
              <p className="text-body-sm font-medium text-zinc-400">No markets available</p>
              <p className="mt-1 text-caption text-zinc-600">
                Create yield markets to see available fixed-rate opportunities
              </p>
            </div>
          )}
        </motion.div>

        {/* Deposit Panel */}
        <motion.div variants={fadeUp} className="lg:col-span-2">
          <div className="glass-card p-6 sticky top-8">
            <AnimatePresence mode="wait">
              {selectedMarket ? (
                <motion.div
                  key={selectedMarket.maturityMs}
                  initial={{ opacity: 0, y: 8 }}
                  animate={{ opacity: 1, y: 0 }}
                  exit={{ opacity: 0, y: -8 }}
                  className="space-y-5"
                >
                  <div className="flex items-center justify-between">
                    <div>
                      <p className="text-overline text-zinc-500">EARNING</p>
                      <p className="text-display-sm text-gradient-green">
                        {formatRate(selectedMarket.impliedRate)}
                      </p>
                    </div>
                    <div className="flex items-center gap-1.5 rounded-full bg-accent-green/10 px-3 py-1.5">
                      <Lock className="h-3 w-3 text-accent-green" />
                      <span className="text-caption font-semibold text-accent-green">FIXED</span>
                    </div>
                  </div>

                  <div className="divider" />

                  <div>
                    <div className="flex items-center justify-between mb-2">
                      <span className="text-caption text-zinc-500">Deposit Amount</span>
                      <span className="text-caption text-zinc-600">
                        Balance: {account ? `${balanceFormatted} SUI` : "—"}
                      </span>
                    </div>
                    <div className="flex items-center gap-3 rounded-xl border border-white/[0.06] bg-white/[0.02] p-4">
                      <input
                        type="number"
                        value={amount}
                        onChange={(e) => { setAmount(e.target.value); setTxSuccess(false); setTxError(null); }}
                        placeholder="0.00"
                        className="input-lg flex-1"
                      />
                      <button
                        onClick={() => {
                          // Max button — leave 0.05 SUI for gas
                          const maxMist = balance > BigInt(50_000_000) ? balance - BigInt(50_000_000) : BigInt(0);
                          setAmount((Number(maxMist) / 1e9).toString());
                        }}
                        className="text-caption font-semibold text-brand-400 hover:text-brand-300 transition-colors"
                      >
                        MAX
                      </button>
                      <div className="flex items-center gap-2 rounded-lg bg-white/[0.04] px-3 py-1.5">
                        <TokenIcon symbol={selectedMarket.underlyingSymbol} size="xs" />
                        <span className="text-body-sm font-medium text-zinc-300">
                          {selectedMarket.underlyingSymbol}
                        </span>
                      </div>
                    </div>
                    {amountNum > 0 && !hasEnough && account && (
                      <p className="mt-1.5 text-caption text-accent-red">Insufficient balance</p>
                    )}
                  </div>

                  {amountNum > 0 && hasEnough && (
                    <motion.div
                      initial={{ opacity: 0, height: 0 }}
                      animate={{ opacity: 1, height: "auto" }}
                      className="space-y-2.5 rounded-xl bg-white/[0.02] p-4"
                    >
                      <div className="flex justify-between text-body-sm">
                        <span className="text-zinc-500">You deposit</span>
                        <span className="mono-number text-white">{amount} {selectedMarket.underlyingSymbol}</span>
                      </div>
                      <div className="flex items-center justify-center py-1">
                        <ArrowRight className="h-4 w-4 text-zinc-600" />
                      </div>
                      <div className="flex justify-between text-body-sm">
                        <span className="text-zinc-500">You receive</span>
                        <span className="mono-number text-white">{ptReceived.toFixed(4)} PT</span>
                      </div>
                      <div className="divider" />
                      <div className="flex justify-between text-body-sm">
                        <span className="text-zinc-500">At maturity</span>
                        <span className="mono-number font-semibold text-accent-green">
                          {ptReceived.toFixed(4)} SY
                        </span>
                      </div>
                      <div className="flex justify-between text-body-sm">
                        <span className="text-zinc-500">Profit</span>
                        <span className="mono-number font-semibold text-accent-green">
                          +{profit.toFixed(4)} SY
                        </span>
                      </div>
                    </motion.div>
                  )}

                  {txSuccess && (
                    <motion.div
                      initial={{ opacity: 0 }}
                      animate={{ opacity: 1 }}
                      className="rounded-xl bg-accent-green/10 p-3 text-center text-caption font-semibold text-accent-green"
                    >
                      Deposit successful! Check your Portfolio.
                    </motion.div>
                  )}

                  {txError && (
                    <motion.div
                      initial={{ opacity: 0 }}
                      animate={{ opacity: 1 }}
                      className="rounded-xl bg-accent-red/10 border border-accent-red/20 p-3 text-caption text-accent-red"
                    >
                      <p className="font-semibold mb-1">Transaction Failed</p>
                      <p className="text-accent-red/80 break-all">{txError}</p>
                    </motion.div>
                  )}

                  {!account ? (
                    <ConnectWalletButton className="btn-success w-full py-3.5" />
                  ) : (
                    <button
                      onClick={handleDeposit}
                      disabled={!amountNum || !hasEnough || loading}
                      className="btn-success w-full py-3.5"
                    >
                      {loading ? "Processing..." : "Earn Fixed Rate"}
                    </button>
                  )}
                </motion.div>
              ) : (
                <motion.div
                  initial={{ opacity: 0 }}
                  animate={{ opacity: 1 }}
                  className="flex flex-col items-center justify-center py-12 text-center"
                >
                  <div className="rounded-2xl bg-white/[0.03] p-4 mb-4">
                    <Shield className="h-8 w-8 text-zinc-600" />
                  </div>
                  <p className="text-body-md font-medium text-zinc-400">
                    {hasMarkets ? "Select a Market" : "No Markets Yet"}
                  </p>
                  <p className="mt-1 text-body-sm text-zinc-600">
                    {hasMarkets
                      ? "Choose a market to see your guaranteed yield"
                      : "Markets will appear after contract deployment"}
                  </p>
                </motion.div>
              )}
            </AnimatePresence>
          </div>
        </motion.div>
      </div>
    </motion.div>
  );
}
