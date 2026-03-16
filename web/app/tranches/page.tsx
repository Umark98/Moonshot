"use client";

import { useState } from "react";
import { useCurrentAccount, useSignAndExecuteTransaction } from "@mysten/dapp-kit";
import { motion } from "framer-motion";
import { TokenIcon } from "@/components/ui/TokenIcon";
import { ConnectWalletButton } from "@/components/ui/ConnectWalletButton";
import { useMarkets } from "@/hooks/useMarkets";
import { useWalletBalance } from "@/hooks/useWalletBalance";
import { buildTrancheDeposit } from "@/lib/sui-client";
import { Shield, Flame, Info, Check, Loader2, DatabaseZap } from "lucide-react";
import { formatRate } from "@/lib/constants";
import type { TrancheType } from "@/types";

const fadeUp = {
  hidden: { opacity: 0, y: 12 },
  show: { opacity: 1, y: 0, transition: { duration: 0.4, ease: [0.16, 1, 0.3, 1] } },
};

export default function TranchesPage() {
  const account = useCurrentAccount();
  const { mutateAsync: signAndExecute } = useSignAndExecuteTransaction();
  const { data: markets, isLoading } = useMarkets();
  const { balance: suiBalance, formatted: suiFormatted } = useWalletBalance("0x2::sui::SUI");
  const [trancheType, setTrancheType] = useState<TrancheType>("senior");
  const [amount, setAmount] = useState("");
  const [loading, setLoading] = useState(false);
  const [selectedMarketIdx, setSelectedMarketIdx] = useState(0);
  const [txSuccess, setTxSuccess] = useState(false);

  const activeMarkets = markets?.filter((m) => !m.isSettled) ?? [];
  const selectedMarket = activeMarkets[selectedMarketIdx];
  const isSenior = trancheType === "senior";

  const amountNum = Number(amount || "0");
  const amountMist = BigInt(Math.floor(amountNum * 1e9));
  const hasEnough = amountMist > BigInt(0) && amountMist <= suiBalance;

  async function handleDeposit() {
    if (!account || !amount || !selectedMarket || !hasEnough) return;
    setLoading(true);
    setTxSuccess(false);
    try {
      // Note: tranche deposits use sy_amount (u64), not SY token objects
      const tx = buildTrancheDeposit(
        selectedMarket.id, // Using market config as vault ID for now
        amountMist,
        isSenior,
        selectedMarket.coinType,
      );
      await signAndExecute({ transaction: tx });
      setTxSuccess(true);
      setAmount("");
    } catch (err) {
      console.error("Tranche deposit failed:", err);
    } finally {
      setLoading(false);
    }
  }

  if (isLoading) {
    return (
      <div className="flex h-96 items-center justify-center">
        <Loader2 className="h-6 w-6 animate-spin text-zinc-500" />
      </div>
    );
  }

  if (!selectedMarket) {
    return (
      <motion.div
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        className="flex h-96 flex-col items-center justify-center text-center"
      >
        <DatabaseZap className="mb-4 h-10 w-10 text-zinc-700" />
        <h2 className="text-display-sm text-white">No Tranches Available</h2>
        <p className="mt-2 text-body-md text-zinc-500 max-w-sm">
          Create a yield market first, then configure senior/junior tranches.
        </p>
      </motion.div>
    );
  }

  return (
    <motion.div className="space-y-8" initial="hidden" animate="show" variants={{ show: { transition: { staggerChildren: 0.06 } } }}>
      <motion.div variants={fadeUp}>
        <h2 className="text-display-md text-white">Structured Tranches</h2>
        <p className="mt-1 text-body-md text-zinc-500">
          Choose your risk profile — Senior (protected) or Junior (leveraged)
        </p>
      </motion.div>

      {/* Risk Profile Selector */}
      <motion.div variants={fadeUp} className="grid grid-cols-1 gap-4 md:grid-cols-2">
        <button
          onClick={() => setTrancheType("senior")}
          className={`glass-card relative cursor-pointer p-5 text-left transition-all duration-300 ${
            isSenior ? "border-brand-500/30 shadow-glow-sm" : "hover:border-white/[0.08]"
          }`}
        >
          {isSenior && (
            <motion.div layoutId="tranche-selected" className="absolute right-4 top-4 flex h-6 w-6 items-center justify-center rounded-full bg-brand-500" transition={{ type: "spring", bounce: 0.15, duration: 0.5 }}>
              <Check className="h-3.5 w-3.5 text-white" />
            </motion.div>
          )}
          <div className="flex items-center gap-3 mb-3">
            <div className="rounded-xl bg-brand-500/10 p-2.5"><Shield className="h-5 w-5 text-brand-400" /></div>
            <div>
              <p className="text-body-md font-semibold text-white">Senior Tranche</p>
              <p className="text-caption text-zinc-500">Protected, target fixed rate</p>
            </div>
          </div>
          <p className="text-caption text-zinc-500 leading-relaxed">Gets paid first from yield. Lower risk, predictable returns. Junior absorbs losses before senior is affected.</p>
          <div className="mt-4 flex items-center gap-2">
            <span className="text-overline text-zinc-600">RISK</span>
            <div className="flex-1 h-1.5 rounded-full bg-white/[0.04] overflow-hidden">
              <div className="h-full w-[25%] rounded-full bg-gradient-to-r from-accent-green to-accent-green/60" />
            </div>
            <span className="text-overline text-accent-green">LOW</span>
          </div>
        </button>

        <button
          onClick={() => setTrancheType("junior")}
          className={`glass-card relative cursor-pointer p-5 text-left transition-all duration-300 ${
            !isSenior ? "border-accent-amber/30 shadow-[0_0_20px_rgba(245,158,11,0.08)]" : "hover:border-white/[0.08]"
          }`}
        >
          {!isSenior && (
            <motion.div layoutId="tranche-selected" className="absolute right-4 top-4 flex h-6 w-6 items-center justify-center rounded-full bg-accent-amber" transition={{ type: "spring", bounce: 0.15, duration: 0.5 }}>
              <Check className="h-3.5 w-3.5 text-white" />
            </motion.div>
          )}
          <div className="flex items-center gap-3 mb-3">
            <div className="rounded-xl bg-accent-amber/10 p-2.5"><Flame className="h-5 w-5 text-accent-amber" /></div>
            <div>
              <p className="text-body-md font-semibold text-white">Junior Tranche</p>
              <p className="text-caption text-zinc-500">Leveraged, variable returns</p>
            </div>
          </div>
          <p className="text-caption text-zinc-500 leading-relaxed">Receives all excess yield after senior is paid. Higher returns in good times, first-loss in bad times. Up to 4x leverage on yield.</p>
          <div className="mt-4 flex items-center gap-2">
            <span className="text-overline text-zinc-600">RISK</span>
            <div className="flex-1 h-1.5 rounded-full bg-white/[0.04] overflow-hidden">
              <div className="h-full w-[75%] rounded-full bg-gradient-to-r from-accent-amber/60 to-accent-red" />
            </div>
            <span className="text-overline text-accent-amber">HIGH</span>
          </div>
        </button>
      </motion.div>

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-5">
        {/* Market Selector */}
        <motion.div variants={fadeUp} className="lg:col-span-3 space-y-4">
          <p className="text-overline text-zinc-500">AVAILABLE VAULTS</p>
          <div className="space-y-3">
            {activeMarkets.map((market, idx) => (
              <button
                key={`${market.id}-${market.maturityMs}`}
                onClick={() => setSelectedMarketIdx(idx)}
                className={`glass-card w-full p-5 text-left transition-all duration-300 ${
                  selectedMarketIdx === idx ? "border-brand-500/20 shadow-glow-sm" : "hover:border-white/[0.08]"
                }`}
              >
                <div className="flex items-center justify-between">
                  <div className="flex items-center gap-3">
                    <TokenIcon symbol={market.underlyingSymbol} size="lg" showRing={selectedMarketIdx === idx} />
                    <div>
                      <p className="text-body-md font-semibold text-white">{market.underlyingSymbol}</p>
                      <p className="text-caption text-zinc-500">
                        {Math.ceil((market.maturityMs - Date.now()) / 86400000)}d to maturity
                      </p>
                    </div>
                  </div>
                  <div className="flex items-center gap-6">
                    <div className="text-right">
                      <p className="text-overline text-zinc-600">IMPLIED APY</p>
                      <p className="mono-number text-body-sm font-bold text-brand-400">
                        {formatRate(market.impliedRate)}
                      </p>
                    </div>
                    <div className="text-right">
                      <p className="text-overline text-zinc-600">TVL</p>
                      <p className="mono-number text-body-sm text-zinc-300">
                        {market.tvl > 0 ? `$${(market.tvl / 1e6).toFixed(1)}M` : "—"}
                      </p>
                    </div>
                  </div>
                </div>
              </button>
            ))}
          </div>
        </motion.div>

        {/* Deposit Panel */}
        <motion.div variants={fadeUp} className="lg:col-span-2">
          <div className="glass-card sticky top-6 p-6 space-y-5">
            <div className="flex items-center gap-2.5">
              {isSenior ? <Shield className="h-5 w-5 text-brand-400" /> : <Flame className="h-5 w-5 text-accent-amber" />}
              <h3 className="text-body-lg font-semibold text-white">
                {isSenior ? "Senior" : "Junior"} Deposit
              </h3>
            </div>

            <div className="rounded-2xl border border-white/[0.04] bg-white/[0.02] p-4 text-center">
              <p className="text-overline text-zinc-500 mb-1">{isSenior ? "TARGET" : "ESTIMATED"} APY</p>
              <p className={`text-display-sm font-bold ${isSenior ? "text-gradient-brand" : "text-accent-amber"}`}>
                {formatRate(selectedMarket.impliedRate)}
              </p>
            </div>

            <div className="rounded-2xl border border-white/[0.04] bg-white/[0.02] p-5">
              <div className="flex items-center justify-between mb-3">
                <span className="text-caption text-zinc-500">Deposit Amount</span>
                <span className="text-caption text-zinc-600">
                  Balance: {account ? `${suiFormatted} SUI` : "—"}
                </span>
              </div>
              <div className="flex items-center gap-3">
                <input type="number" value={amount} onChange={(e) => { setAmount(e.target.value); setTxSuccess(false); }} placeholder="0.00" className="input-lg flex-1 min-w-0" />
                <div className="flex items-center gap-2 rounded-xl bg-white/[0.04] px-4 py-2.5 shrink-0">
                  <TokenIcon symbol={selectedMarket.underlyingSymbol} size="sm" />
                  <span className="text-body-sm font-semibold text-white">SUI</span>
                </div>
              </div>
              {amountNum > 0 && !hasEnough && account && (
                <p className="mt-1.5 text-caption text-accent-red">Insufficient balance</p>
              )}
            </div>

            {amountNum > 0 && hasEnough && (
              <motion.div initial={{ opacity: 0, height: 0 }} animate={{ opacity: 1, height: "auto" }} className="space-y-2 rounded-xl bg-white/[0.02] p-4">
                {[
                  ["Tranche", isSenior ? "Senior" : "Junior"],
                  ["Implied APY", formatRate(selectedMarket.impliedRate)],
                  ["Underlying", selectedMarket.underlyingSymbol],
                  ["Maturity", `${Math.ceil((selectedMarket.maturityMs - Date.now()) / 86400000)}d`],
                ].map(([label, value]) => (
                  <div key={label} className="flex justify-between text-body-sm">
                    <span className="text-zinc-500">{label}</span>
                    <span className="text-zinc-300">{value}</span>
                  </div>
                ))}
              </motion.div>
            )}

            {txSuccess && (
              <motion.div
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                className="rounded-xl bg-accent-green/10 p-3 text-center text-caption font-semibold text-accent-green"
              >
                Tranche deposit successful!
              </motion.div>
            )}

            {!account ? (
              <ConnectWalletButton />
            ) : (
              <button onClick={handleDeposit} disabled={!hasEnough || loading} className="btn-primary w-full py-3.5">
                {loading ? "Depositing..." : `Deposit to ${isSenior ? "Senior" : "Junior"} Tranche`}
              </button>
            )}

            <div className="flex items-start gap-2.5 rounded-xl bg-white/[0.02] p-4">
              <Info className="mt-0.5 h-4 w-4 shrink-0 text-zinc-500" />
              <p className="text-caption text-zinc-500">
                {isSenior
                  ? "Senior tranche targets a fixed rate. In low-yield scenarios, actual returns may be lower than target."
                  : "Junior tranche absorbs first losses. In bad scenarios, you may lose part of your deposit."}
              </p>
            </div>
          </div>
        </motion.div>
      </div>
    </motion.div>
  );
}
