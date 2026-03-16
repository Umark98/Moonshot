"use client";

import { useState } from "react";
import { useCurrentAccount, useSignAndExecuteTransaction } from "@mysten/dapp-kit";
import { motion } from "framer-motion";
import { TokenIcon } from "@/components/ui/TokenIcon";
import { ConnectWalletButton } from "@/components/ui/ConnectWalletButton";
import { useMarkets } from "@/hooks/useMarkets";
import { useWalletBalance, useOwnedProtocolObjects } from "@/hooks/useWalletBalance";
import { formatRate, PACKAGE_ID } from "@/lib/constants";
import { buildDepositAndSwapToPt, buildSwapPtToSy } from "@/lib/sui-client";
import { useSwapHistory } from "@/hooks/useAnalytics";
import { ArrowDownUp, Info, BarChart3, Settings2, Loader2, DatabaseZap, ExternalLink } from "lucide-react";

type SwapDirection = "buy_pt" | "sell_pt";
type TradeTab = "swap" | "orderbook";

const fadeUp = {
  hidden: { opacity: 0, y: 12 },
  show: { opacity: 1, y: 0, transition: { duration: 0.4, ease: [0.16, 1, 0.3, 1] } },
};

export default function TradePage() {
  const account = useCurrentAccount();
  const { mutateAsync: signAndExecute } = useSignAndExecuteTransaction();
  const { data: markets, isLoading } = useMarkets();
  const { balance: suiBalance, formatted: suiFormatted } = useWalletBalance("0x2::sui::SUI");
  const [tab, setTab] = useState<TradeTab>("swap");
  const [direction, setDirection] = useState<SwapDirection>("buy_pt");
  const [inputAmount, setInputAmount] = useState("");
  const [slippage, setSlippage] = useState("0.5");
  const [loading, setLoading] = useState(false);
  const [selectedMarketId, setSelectedMarketId] = useState<string | null>(null);
  const [txSuccess, setTxSuccess] = useState(false);
  const [txError, setTxError] = useState<string | null>(null);

  const activeMarkets = markets?.filter((m) => !m.isSettled) ?? [];
  const market = selectedMarketId
    ? activeMarkets.find((m) => `${m.id}-${m.maturityMs}` === selectedMarketId)
    : activeMarkets[0];

  // Fetch user's PT tokens for sell direction
  const ptType = market ? `${PACKAGE_ID}::yield_tokenizer::PT<${market.coinType}>` : "";
  const { objects: ptObjects } = useOwnedProtocolObjects(ptType);

  const inputNum = Number(inputAmount || "0");
  const amountMist = BigInt(Math.floor(inputNum * 1e9));

  const outputAmount = market && inputNum > 0
    ? direction === "buy_pt"
      ? (inputNum / market.ptPrice).toFixed(4)
      : (inputNum * market.ptPrice).toFixed(4)
    : "";

  const priceImpact = inputNum > 0 && market
    ? Math.min(inputNum / (market.tvl > 0 ? market.tvl * 1e9 : 1) * 100, 50).toFixed(3)
    : "0.000";

  // SECURITY: Calculate minimum output with slippage protection
  const slippagePct = parseFloat(slippage) / 100;
  const outputNum = parseFloat(outputAmount || "0");
  const minOutputMist = BigInt(Math.floor(outputNum * (1 - slippagePct) * 1e9));

  // For buy_pt: user needs SUI
  // For sell_pt: user needs PT objects
  const canExecute = direction === "buy_pt"
    ? amountMist > BigInt(0) && amountMist <= suiBalance
    : inputNum > 0 && ptObjects.length > 0;

  async function handleSwap() {
    if (!account || !inputAmount || !market || !canExecute) return;
    setLoading(true);
    setTxSuccess(false);
    setTxError(null);
    try {
      if (direction === "buy_pt") {
        // SECURITY: Apply slippage protection — minPtOut calculated from user's slippage setting
        const tx = buildDepositAndSwapToPt(
          market.syVaultId,
          market.poolId,
          market.id, // YieldMarketConfig ID
          amountMist,
          minOutputMist,
          market.coinType,
        );
        await signAndExecute({ transaction: tx });
      } else {
        const ptObj = ptObjects[0];
        if (!ptObj?.data?.objectId) throw new Error("No PT token found");
        // SECURITY: Apply slippage protection — minSyOut calculated from user's slippage setting
        const tx = buildSwapPtToSy(
          market.poolId,
          market.syVaultId,
          market.id, // YieldMarketConfig ID
          ptObj.data.objectId,
          minOutputMist,
          market.coinType,
        );
        await signAndExecute({ transaction: tx });
      }
      setTxSuccess(true);
      setInputAmount("");
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error("Swap failed:", msg);
      setTxError(msg.length > 200 ? msg.slice(0, 200) + "..." : msg);
    } finally {
      setLoading(false);
    }
  }

  const inputLabel = direction === "buy_pt" ? "SUI" : "PT";
  const outputLabel = direction === "buy_pt" ? "PT" : "SUI";

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
          Create a yield market and add liquidity to start trading PT tokens.
        </p>
      </motion.div>
    );
  }

  return (
    <motion.div className="space-y-8" initial="hidden" animate="show" variants={{ show: { transition: { staggerChildren: 0.06 } } }}>
      <motion.div variants={fadeUp}>
        <h2 className="text-display-md text-white">Trade</h2>
        <p className="mt-1 text-body-md text-zinc-500">
          Swap underlying and PT tokens on the yield AMM
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
              PT-{m.underlyingSymbol} · {Math.ceil((m.maturityMs - Date.now()) / 86400000)}d
            </button>
          ))}
        </motion.div>
      )}

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-5">
        {/* Main Panel */}
        <motion.div variants={fadeUp} className="lg:col-span-3">
          <div className="mb-4 flex gap-1 rounded-2xl bg-white/[0.02] border border-white/[0.04] p-1.5">
            {(["swap", "orderbook"] as const).map((t) => (
              <button
                key={t}
                onClick={() => setTab(t)}
                className={`flex-1 rounded-xl px-4 py-2.5 text-body-sm font-medium transition-all duration-200 ${
                  tab === t
                    ? "bg-white/[0.06] text-white shadow-elevation-1"
                    : "text-zinc-500 hover:text-zinc-300"
                }`}
              >
                {t === "swap" ? "AMM Swap" : "Order Book"}
              </button>
            ))}
          </div>

          {tab === "swap" ? (
            <div className="glass-card p-6 space-y-4">
              <div className="flex items-center justify-between">
                <span className="text-body-sm font-medium text-zinc-400">Swap</span>
                <button className="rounded-lg p-1.5 text-zinc-500 hover:bg-white/[0.04] hover:text-zinc-300 transition-colors">
                  <Settings2 className="h-4 w-4" />
                </button>
              </div>

              <div className="rounded-2xl border border-white/[0.04] bg-white/[0.02] p-5">
                <div className="flex items-center justify-between mb-3">
                  <span className="text-caption text-zinc-500">You Pay</span>
                  <span className="text-caption text-zinc-600">
                    Balance: {account
                      ? direction === "buy_pt"
                        ? `${suiFormatted} SUI`
                        : `${ptObjects.length} PT`
                      : "—"}
                  </span>
                </div>
                <div className="flex items-center gap-3">
                  <input
                    type="number"
                    value={inputAmount}
                    onChange={(e) => { setInputAmount(e.target.value); setTxSuccess(false); setTxError(null); }}
                    placeholder="0.00"
                    className="input-lg flex-1 min-w-0"
                  />
                  <div className="flex items-center gap-2 rounded-xl bg-white/[0.04] px-4 py-2.5 shrink-0">
                    <TokenIcon symbol={market.underlyingSymbol} size="sm" />
                    <span className="text-body-sm font-semibold text-white">{inputLabel}</span>
                  </div>
                </div>
              </div>

              <div className="flex justify-center -my-1 relative z-10">
                <motion.button
                  whileTap={{ rotate: 180 }}
                  transition={{ duration: 0.3 }}
                  onClick={() => setDirection(direction === "buy_pt" ? "sell_pt" : "buy_pt")}
                  className="rounded-xl border border-white/[0.06] bg-surface-1 p-2.5 text-zinc-400 transition-colors hover:border-white/[0.1] hover:text-white"
                >
                  <ArrowDownUp className="h-5 w-5" />
                </motion.button>
              </div>

              <div className="rounded-2xl border border-white/[0.04] bg-white/[0.02] p-5">
                <div className="flex items-center justify-between mb-3">
                  <span className="text-caption text-zinc-500">You Receive</span>
                </div>
                <div className="flex items-center gap-3">
                  <div className="flex-1 text-2xl font-semibold text-white min-w-0" style={{ letterSpacing: "-0.01em" }}>
                    {outputAmount || <span className="text-zinc-700">0.00</span>}
                  </div>
                  <div className="flex items-center gap-2 rounded-xl bg-white/[0.04] px-4 py-2.5 shrink-0">
                    <TokenIcon symbol={market.underlyingSymbol} size="sm" />
                    <span className="text-body-sm font-semibold text-white">{outputLabel}</span>
                  </div>
                </div>
              </div>

              {inputNum > 0 && (
                <motion.div
                  initial={{ opacity: 0, height: 0 }}
                  animate={{ opacity: 1, height: "auto" }}
                  className="space-y-2 rounded-xl bg-white/[0.02] p-4"
                >
                  {[
                    ["Rate", `1 SUI = ${(1 / market.ptPrice).toFixed(4)} PT`],
                    ["Price Impact", `${priceImpact}%`, Number(priceImpact) > 1],
                    ["Slippage", `${slippage}%`],
                    ["Implied APY", formatRate(market.impliedRate), false, true],
                  ].map(([label, value, isWarn, isGreen]) => (
                    <div key={label as string} className="flex justify-between text-body-sm">
                      <span className="text-zinc-500">{label}</span>
                      <span className={`mono-number ${isWarn ? "text-accent-red" : isGreen ? "text-accent-green font-semibold" : "text-zinc-300"}`}>
                        {value}
                      </span>
                    </div>
                  ))}
                </motion.div>
              )}

              <div className="flex items-center gap-2">
                <span className="text-caption text-zinc-500">Slippage</span>
                <div className="flex gap-1.5 ml-auto">
                  {["0.1", "0.5", "1.0"].map((s) => (
                    <button
                      key={s}
                      onClick={() => setSlippage(s)}
                      className={`rounded-lg px-2.5 py-1 text-caption font-semibold transition-all duration-200 ${
                        slippage === s
                          ? "bg-brand-500/15 text-brand-400 ring-1 ring-brand-500/20"
                          : "bg-white/[0.03] text-zinc-500 hover:text-zinc-300"
                      }`}
                    >
                      {s}%
                    </button>
                  ))}
                </div>
              </div>

              {txSuccess && (
                <motion.div
                  initial={{ opacity: 0 }}
                  animate={{ opacity: 1 }}
                  className="rounded-xl bg-accent-green/10 p-3 text-center text-caption font-semibold text-accent-green"
                >
                  Swap successful!
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
                <ConnectWalletButton />
              ) : (
                <button
                  onClick={handleSwap}
                  disabled={!canExecute || loading}
                  className="btn-primary w-full py-3.5"
                >
                  {loading ? "Swapping..." : `Swap ${inputLabel} → ${outputLabel}`}
                </button>
              )}
            </div>
          ) : (
            <div className="glass-card p-6">
              <div className="flex items-center gap-2 mb-5">
                <BarChart3 className="h-5 w-5 text-zinc-400" />
                <h3 className="text-body-lg font-semibold text-white">DeepBook v3</h3>
              </div>

              <div className="flex flex-col items-center justify-center py-12 text-center">
                <DatabaseZap className="mb-3 h-8 w-8 text-zinc-700" />
                <p className="text-body-sm font-medium text-zinc-400">Order book not available</p>
                <p className="mt-1 text-caption text-zinc-600">
                  DeepBook order book will populate once liquidity is added to the market
                </p>
              </div>

              <div className="mt-5 flex items-center gap-1.5 text-caption text-zinc-600">
                <Info className="h-3.5 w-3.5" />
                Powered by DeepBook v3 — institutional-grade limit orders
              </div>
            </div>
          )}
        </motion.div>

        {/* Market Info */}
        <motion.div variants={fadeUp} className="lg:col-span-2 space-y-4">
          <div className="glass-card p-6">
            <p className="text-overline text-zinc-500 mb-4">MARKET INFO</p>
            <div className="flex items-center gap-3 mb-5">
              <TokenIcon symbol={market.underlyingSymbol} size="xl" showRing />
              <div>
                <p className="text-body-lg font-bold text-white">PT-{market.underlyingSymbol}</p>
                <p className="text-caption text-zinc-500">
                  {Math.ceil((market.maturityMs - Date.now()) / 86400000)}d to maturity
                </p>
              </div>
            </div>
            <div className="space-y-3">
              {[
                ["Implied APY", formatRate(market.impliedRate), "text-accent-green font-bold"],
                ["PT Price", `${market.ptPrice.toFixed(4)} SUI`, "mono-number text-white"],
                ["YT Price", `${(1 - market.ptPrice).toFixed(4)} SUI`, "mono-number text-white"],
              ].map(([label, value, cls]) => (
                <div key={label} className="flex justify-between text-body-sm">
                  <span className="text-zinc-500">{label}</span>
                  <span className={cls}>{value}</span>
                </div>
              ))}
              <div className="divider" />
              {[
                ["TVL", market.tvl > 0 ? `$${market.tvl.toLocaleString()}` : "—"],
                ["24h Volume", market.volume24h > 0 ? `$${market.volume24h.toLocaleString()}` : "—"],
              ].map(([label, value]) => (
                <div key={label} className="flex justify-between text-body-sm">
                  <span className="text-zinc-500">{label}</span>
                  <span className="text-zinc-300">{value}</span>
                </div>
              ))}
            </div>
          </div>

          <div className="glass-card p-6">
            <p className="text-overline text-zinc-500 mb-3">HOW IT WORKS</p>
            <div className="space-y-3 text-caption text-zinc-500">
              <p>
                <strong className="text-zinc-300">Buy PT</strong> — lock in a
                fixed yield. PT trades below 1.0 underlying; the discount is your
                guaranteed return at maturity.
              </p>
              <p>
                <strong className="text-zinc-300">Sell PT</strong> — exit your
                fixed position early and receive underlying immediately.
              </p>
              <p>
                <strong className="text-zinc-300">YT</strong> — for leveraged
                yield exposure, mint PT+YT then sell the PT on this market.
              </p>
            </div>
          </div>
        </motion.div>
      </div>

      {/* Recent Trades */}
      <RecentTrades marketId={market?.id} />
    </motion.div>
  );
}

function RecentTrades({ marketId }: { marketId?: string }) {
  const { data } = useSwapHistory({ marketId, limit: 10 });
  const swaps = data?.swaps ?? [];

  if (swaps.length === 0) return null;

  return (
    <motion.div variants={fadeUp} className="glass-card overflow-hidden p-0">
      <div className="border-b border-white/[0.04] px-6 py-4">
        <p className="text-overline text-zinc-500">RECENT TRADES</p>
      </div>
      <div className="divide-y divide-white/[0.03]">
        {swaps.map((swap) => {
          const isBuy = swap.direction === "sy_to_pt";
          const time = new Date(Number(swap.timestampMs));
          const timeStr = time.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
          const dateStr = time.toLocaleDateString([], { month: "short", day: "numeric" });

          return (
            <div
              key={swap.id}
              className="flex items-center justify-between px-6 py-3 text-body-sm hover:bg-white/[0.02] transition-colors"
            >
              <div className="flex items-center gap-3">
                <span
                  className={`rounded-md px-1.5 py-0.5 text-overline font-bold ${
                    isBuy
                      ? "text-accent-green bg-accent-green/10"
                      : "text-accent-red bg-accent-red/10"
                  }`}
                >
                  {isBuy ? "BUY" : "SELL"}
                </span>
                <span className="mono-number text-zinc-300">
                  {(Number(swap.amountIn) / 1e9).toFixed(4)}
                </span>
                <span className="text-zinc-600">→</span>
                <span className="mono-number text-white">
                  {(Number(swap.amountOut) / 1e9).toFixed(4)}
                </span>
              </div>
              <div className="flex items-center gap-4">
                <span className="mono-number text-caption text-zinc-500">
                  PT {swap.ptPrice.toFixed(4)}
                </span>
                <span className="text-caption text-zinc-600">
                  {dateStr} {timeStr}
                </span>
                <a
                  href={`https://testnet.suivision.xyz/txblock/${swap.txDigest}`}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-zinc-600 hover:text-zinc-400 transition-colors"
                >
                  <ExternalLink className="h-3.5 w-3.5" />
                </a>
              </div>
            </div>
          );
        })}
      </div>
    </motion.div>
  );
}
