"use client";

import { useState } from "react";
import { useCurrentAccount, useSignAndExecuteTransaction } from "@mysten/dapp-kit";
import { motion, AnimatePresence } from "framer-motion";
import { TokenIcon } from "@/components/ui/TokenIcon";
import { ConnectWalletButton } from "@/components/ui/ConnectWalletButton";
import { useMarkets } from "@/hooks/useMarkets";
import { useWalletBalance, useOwnedProtocolObjects } from "@/hooks/useWalletBalance";
import { PACKAGE_ID } from "@/lib/constants";
import { buildDepositAndMint, buildRedeemPY } from "@/lib/sui-client";
import { Coins, Undo2, Zap, Info, ChevronRight, Loader2, DatabaseZap } from "lucide-react";

type MintTab = "mint" | "redeem";

const fadeUp = {
  hidden: { opacity: 0, y: 12 },
  show: { opacity: 1, y: 0, transition: { duration: 0.4, ease: [0.16, 1, 0.3, 1] } },
};

export default function MintPage() {
  const account = useCurrentAccount();
  const { mutateAsync: signAndExecute } = useSignAndExecuteTransaction();
  const { data: markets, isLoading } = useMarkets();
  const { balance: suiBalance, formatted: suiFormatted } = useWalletBalance("0x2::sui::SUI");
  const [tab, setTab] = useState<MintTab>("mint");
  const [amount, setAmount] = useState("");
  const [loading, setLoading] = useState(false);
  const [selectedMarketId, setSelectedMarketId] = useState<string | null>(null);
  const [txSuccess, setTxSuccess] = useState(false);

  const activeMarkets = markets?.filter((m) => !m.isSettled) ?? [];
  const market = selectedMarketId
    ? activeMarkets.find((m) => `${m.id}-${m.maturityMs}` === selectedMarketId)
    : activeMarkets[0];

  // Fetch user's PT and YT tokens for redeem
  const ptType = market ? `${PACKAGE_ID}::yield_tokenizer::PT<${market.coinType}>` : "";
  const ytType = market ? `${PACKAGE_ID}::yield_tokenizer::YT<${market.coinType}>` : "";
  const { objects: ptObjects } = useOwnedProtocolObjects(ptType);
  const { objects: ytObjects } = useOwnedProtocolObjects(ytType);

  const amountNum = Number(amount || "0");
  const amountMist = BigInt(Math.floor(amountNum * 1e9));

  async function handleMint() {
    if (!account || !amount || !market || amountMist <= BigInt(0)|| amountMist > suiBalance) return;
    setLoading(true);
    setTxSuccess(false);
    try {
      const tx = buildDepositAndMint(
        market.syVaultId,
        market.id,
        amountMist,
        market.coinType,
      );
      await signAndExecute({ transaction: tx });
      setTxSuccess(true);
      setAmount("");
    } catch (err) {
      console.error("Mint failed:", err);
    } finally {
      setLoading(false);
    }
  }

  async function handleRedeem() {
    if (!account || !market || ptObjects.length === 0 || ytObjects.length === 0) return;
    setLoading(true);
    setTxSuccess(false);
    try {
      const ptObj = ptObjects[0];
      const ytObj = ytObjects[0];
      if (!ptObj?.data?.objectId || !ytObj?.data?.objectId) throw new Error("Missing tokens");
      const tx = buildRedeemPY(
        market.id,
        market.syVaultId,
        ptObj.data.objectId,
        ytObj.data.objectId,
        market.coinType,
      );
      await signAndExecute({ transaction: tx });
      setTxSuccess(true);
      setAmount("");
    } catch (err) {
      console.error("Redeem failed:", err);
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

  if (!market) {
    return (
      <motion.div
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        className="flex h-96 flex-col items-center justify-center text-center"
      >
        <DatabaseZap className="mb-4 h-10 w-10 text-zinc-700" />
        <h2 className="text-display-sm text-white">No Markets Available</h2>
        <p className="mt-2 text-body-md text-zinc-500 max-w-sm">
          Create a yield market first, then mint PT + YT from your underlying tokens.
        </p>
      </motion.div>
    );
  }

  const maturityDays = Math.ceil((market.maturityMs - Date.now()) / 86400000);
  const canMint = amountMist > BigInt(0)&& amountMist <= suiBalance;
  const canRedeem = ptObjects.length > 0 && ytObjects.length > 0;

  return (
    <motion.div className="space-y-8" initial="hidden" animate="show" variants={{ show: { transition: { staggerChildren: 0.06 } } }}>
      <motion.div variants={fadeUp}>
        <h2 className="text-display-md text-white">Mint / Redeem</h2>
        <p className="mt-1 text-body-md text-zinc-500">
          Split yield-bearing assets into PT + YT, or recombine to recover underlying
        </p>
      </motion.div>

      {/* Market Selector */}
      {activeMarkets.length > 1 && (
        <motion.div variants={fadeUp} className="flex gap-2 flex-wrap">
          {activeMarkets.map((m) => (
            <button
              key={`${m.id}-${m.maturityMs}`}
              onClick={() => setSelectedMarketId(`${m.id}-${m.maturityMs}`)}
              className={`rounded-full px-3.5 py-1.5 text-caption font-semibold transition-all duration-200 ${
                market.id === m.id && market.maturityMs === m.maturityMs
                  ? "bg-brand-500/10 text-brand-400 ring-1 ring-brand-500/20"
                  : "text-zinc-500 hover:bg-white/[0.03] hover:text-zinc-300"
              }`}
            >
              {m.underlyingSymbol} · {maturityDays}d
            </button>
          ))}
        </motion.div>
      )}

      <motion.div variants={fadeUp} className="mx-auto max-w-xl">
        <div className="mb-4 flex gap-1 rounded-2xl bg-white/[0.02] border border-white/[0.04] p-1.5">
          {([
            { key: "mint" as const, label: "Mint PT + YT", icon: Coins },
            { key: "redeem" as const, label: "Redeem", icon: Undo2 },
          ]).map((t) => (
            <button
              key={t.key}
              onClick={() => { setTab(t.key); setTxSuccess(false); }}
              className={`flex flex-1 items-center justify-center gap-2 rounded-xl px-4 py-2.5 text-body-sm font-medium transition-all duration-200 ${
                tab === t.key
                  ? "bg-white/[0.06] text-white shadow-elevation-1"
                  : "text-zinc-500 hover:text-zinc-300"
              }`}
            >
              <t.icon className="h-4 w-4" />
              {t.label}
            </button>
          ))}
        </div>

        <AnimatePresence mode="wait">
          {tab === "mint" ? (
            <motion.div
              key="mint"
              initial={{ opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -8 }}
              transition={{ duration: 0.25, ease: [0.16, 1, 0.3, 1] }}
              className="glass-card p-6 space-y-5"
            >
              <div className="flex items-center justify-center gap-3 rounded-2xl border border-white/[0.04] bg-white/[0.02] p-5">
                <div className="flex flex-col items-center gap-1.5">
                  <TokenIcon symbol={market.underlyingSymbol} size="lg" />
                  <span className="text-caption font-semibold text-zinc-400">SUI</span>
                </div>
                <div className="flex flex-col items-center gap-0.5 px-4">
                  <motion.div animate={{ x: [0, 4, 0] }} transition={{ duration: 1.5, repeat: Infinity, ease: "easeInOut" }}>
                    <ChevronRight className="h-5 w-5 text-brand-400" />
                  </motion.div>
                  <span className="text-overline text-zinc-600">SPLIT</span>
                </div>
                <div className="flex items-center gap-4">
                  <div className="flex flex-col items-center gap-1.5">
                    <TokenIcon symbol="PT" size="lg" />
                    <span className="text-caption font-semibold text-brand-400">PT</span>
                  </div>
                  <span className="text-body-lg text-zinc-600">+</span>
                  <div className="flex flex-col items-center gap-1.5">
                    <TokenIcon symbol="YT" size="lg" />
                    <span className="text-caption font-semibold text-accent-amber">YT</span>
                  </div>
                </div>
              </div>

              <div className="rounded-2xl border border-white/[0.04] bg-white/[0.02] p-5">
                <div className="flex items-center justify-between mb-3">
                  <span className="text-caption text-zinc-500">SUI Amount to Deposit & Split</span>
                  <span className="text-caption text-zinc-600">
                    Balance: {account ? `${suiFormatted} SUI` : "—"}
                  </span>
                </div>
                <div className="flex items-center gap-3">
                  <input
                    type="number"
                    value={amount}
                    onChange={(e) => { setAmount(e.target.value); setTxSuccess(false); }}
                    placeholder="0.00"
                    className="input-lg flex-1 min-w-0"
                  />
                  <div className="flex items-center gap-2 rounded-xl bg-white/[0.04] px-4 py-2.5 shrink-0">
                    <TokenIcon symbol={market.underlyingSymbol} size="sm" />
                    <span className="text-body-sm font-semibold text-white">SUI</span>
                  </div>
                </div>
                {amountNum > 0 && !canMint && account && (
                  <p className="mt-1.5 text-caption text-accent-red">Insufficient balance</p>
                )}
              </div>

              {amountNum > 0 && canMint && (
                <motion.div
                  initial={{ opacity: 0, height: 0 }}
                  animate={{ opacity: 1, height: "auto" }}
                  className="space-y-2 rounded-xl bg-white/[0.02] p-4"
                >
                  {[
                    ["You deposit", `${amount} SUI`, "text-white"],
                    ["You receive", `${amount} PT`, "text-brand-400 font-semibold"],
                    ["+", `${amount} YT`, "text-accent-amber font-semibold"],
                  ].map(([label, value, cls]) => (
                    <div key={label} className="flex justify-between text-body-sm">
                      <span className="text-zinc-500">{label}</span>
                      <span className={`mono-number ${cls}`}>{value}</span>
                    </div>
                  ))}
                  <div className="divider" />
                  <div className="flex justify-between text-body-sm">
                    <span className="text-zinc-500">Maturity</span>
                    <span className="text-zinc-300">{maturityDays} days</span>
                  </div>
                </motion.div>
              )}

              {txSuccess && (
                <motion.div
                  initial={{ opacity: 0 }}
                  animate={{ opacity: 1 }}
                  className="rounded-xl bg-accent-green/10 p-3 text-center text-caption font-semibold text-accent-green"
                >
                  Mint successful! You now have PT + YT tokens.
                </motion.div>
              )}

              {!account ? (
                <ConnectWalletButton />
              ) : (
                <button onClick={handleMint} disabled={!canMint || loading} className="btn-primary w-full py-3.5">
                  {loading ? "Minting..." : "Mint PT + YT"}
                </button>
              )}

              <div className="flex items-start gap-2.5 rounded-xl border border-brand-500/10 bg-brand-500/[0.04] p-4">
                <Zap className="mt-0.5 h-4 w-4 shrink-0 text-brand-400" />
                <p className="text-caption text-zinc-400">
                  <strong className="text-zinc-300">Tip:</strong> Mint PT + YT,
                  then sell the token you don&apos;t want. Sell PT for leveraged yield
                  via YT. Sell YT to lock in fixed rate via PT.
                </p>
              </div>
            </motion.div>
          ) : (
            <motion.div
              key="redeem"
              initial={{ opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -8 }}
              transition={{ duration: 0.25, ease: [0.16, 1, 0.3, 1] }}
              className="glass-card p-6 space-y-5"
            >
              <div className="flex items-center justify-center gap-3 rounded-2xl border border-white/[0.04] bg-white/[0.02] p-5">
                <div className="flex items-center gap-4">
                  <div className="flex flex-col items-center gap-1.5">
                    <TokenIcon symbol="PT" size="lg" />
                    <span className="text-caption font-semibold text-brand-400">PT</span>
                  </div>
                  <span className="text-body-lg text-zinc-600">+</span>
                  <div className="flex flex-col items-center gap-1.5">
                    <TokenIcon symbol="YT" size="lg" />
                    <span className="text-caption font-semibold text-accent-amber">YT</span>
                  </div>
                </div>
                <div className="flex flex-col items-center gap-0.5 px-4">
                  <motion.div animate={{ x: [0, 4, 0] }} transition={{ duration: 1.5, repeat: Infinity, ease: "easeInOut" }}>
                    <ChevronRight className="h-5 w-5 text-accent-green" />
                  </motion.div>
                  <span className="text-overline text-zinc-600">MERGE</span>
                </div>
                <div className="flex flex-col items-center gap-1.5">
                  <TokenIcon symbol={market.underlyingSymbol} size="lg" />
                  <span className="text-caption font-semibold text-zinc-400">SUI</span>
                </div>
              </div>

              <div className="rounded-2xl border border-white/[0.04] bg-white/[0.02] p-5">
                <div className="flex items-center justify-between mb-3">
                  <span className="text-caption text-zinc-500">Your Tokens</span>
                </div>
                <div className="space-y-2">
                  <div className="flex justify-between text-body-sm">
                    <span className="text-zinc-500">PT tokens</span>
                    <span className="mono-number text-white">{ptObjects.length} positions</span>
                  </div>
                  <div className="flex justify-between text-body-sm">
                    <span className="text-zinc-500">YT tokens</span>
                    <span className="mono-number text-white">{ytObjects.length} positions</span>
                  </div>
                </div>
              </div>

              {txSuccess && (
                <motion.div
                  initial={{ opacity: 0 }}
                  animate={{ opacity: 1 }}
                  className="rounded-xl bg-accent-green/10 p-3 text-center text-caption font-semibold text-accent-green"
                >
                  Redeem successful! Underlying returned to your wallet.
                </motion.div>
              )}

              {!account ? (
                <ConnectWalletButton />
              ) : (
                <button onClick={handleRedeem} disabled={!canRedeem || loading} className="btn-primary w-full py-3.5">
                  {loading ? "Redeeming..." : canRedeem ? "Redeem PT + YT → SUI" : "No PT + YT to redeem"}
                </button>
              )}

              <div className="flex items-start gap-2.5 rounded-xl bg-white/[0.02] p-4">
                <Info className="mt-0.5 h-4 w-4 shrink-0 text-zinc-500" />
                <p className="text-caption text-zinc-500">
                  Redeem requires equal amounts of PT and YT from the same market.
                  After maturity, PT can be redeemed alone at the settlement rate.
                </p>
              </div>
            </motion.div>
          )}
        </AnimatePresence>
      </motion.div>
    </motion.div>
  );
}
