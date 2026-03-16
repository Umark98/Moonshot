"use client";

import { useCurrentAccount, useDisconnectWallet, ConnectButton } from "@mysten/dapp-kit";
import { shortenAddress } from "@/lib/utils";
import { SUI_NETWORK } from "@/lib/constants";
import { ChevronDown, Copy, LogOut, Check, Bell } from "lucide-react";
import { useState, useRef, useEffect } from "react";
import { AnimatePresence, motion } from "framer-motion";

export function TopBar() {
  const account = useCurrentAccount();
  const { mutate: disconnect } = useDisconnectWallet();
  const [showMenu, setShowMenu] = useState(false);
  const [copied, setCopied] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    function handleClickOutside(e: MouseEvent) {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        setShowMenu(false);
      }
    }
    document.addEventListener("mousedown", handleClickOutside);
    return () => document.removeEventListener("mousedown", handleClickOutside);
  }, []);

  function handleCopy() {
    if (!account) return;
    navigator.clipboard.writeText(account.address);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
    setShowMenu(false);
  }

  return (
    <header className="flex h-16 items-center justify-between border-b border-white/[0.04] bg-surface-0/50 backdrop-blur-xl px-6">
      {/* Left: Network badge */}
      <div className="flex items-center gap-3">
        <div className="flex items-center gap-2 rounded-full border border-white/[0.06] bg-white/[0.02] px-3 py-1.5">
          <div
            className={`h-1.5 w-1.5 rounded-full ${
              SUI_NETWORK === "mainnet"
                ? "bg-accent-green shadow-glow-green"
                : "bg-accent-amber"
            }`}
          />
          <span className="text-caption font-semibold uppercase tracking-wider text-zinc-400">
            {SUI_NETWORK}
          </span>
        </div>
      </div>

      {/* Right: Actions */}
      <div className="flex items-center gap-3">
        {/* Notifications placeholder */}
        <button className="relative rounded-xl p-2.5 text-zinc-500 transition-colors hover:bg-white/[0.04] hover:text-zinc-300">
          <Bell className="h-[18px] w-[18px]" />
        </button>

        {/* Wallet */}
        {account ? (
          <div className="relative" ref={menuRef}>
            <button
              onClick={() => setShowMenu(!showMenu)}
              className="flex items-center gap-2.5 rounded-xl border border-white/[0.06] bg-white/[0.03] px-3.5 py-2 transition-all duration-200 hover:border-white/[0.1] hover:bg-white/[0.05]"
            >
              <div className="h-6 w-6 rounded-full bg-gradient-to-br from-brand-400 via-violet-500 to-brand-700 shadow-elevation-1" />
              <span className="text-body-sm font-medium text-zinc-200">
                {shortenAddress(account.address)}
              </span>
              <ChevronDown
                className={`h-4 w-4 text-zinc-500 transition-transform duration-200 ${
                  showMenu ? "rotate-180" : ""
                }`}
              />
            </button>

            <AnimatePresence>
              {showMenu && (
                <motion.div
                  initial={{ opacity: 0, scale: 0.95, y: -4 }}
                  animate={{ opacity: 1, scale: 1, y: 0 }}
                  exit={{ opacity: 0, scale: 0.95, y: -4 }}
                  transition={{ duration: 0.15, ease: [0.16, 1, 0.3, 1] }}
                  className="glass-elevated absolute right-0 top-full mt-2 w-52 overflow-hidden rounded-xl p-1.5"
                >
                  <button
                    onClick={handleCopy}
                    className="flex w-full items-center gap-2.5 rounded-lg px-3 py-2.5 text-body-sm text-zinc-300 transition-colors hover:bg-white/[0.05]"
                  >
                    {copied ? (
                      <Check className="h-4 w-4 text-accent-green" />
                    ) : (
                      <Copy className="h-4 w-4 text-zinc-500" />
                    )}
                    {copied ? "Copied!" : "Copy Address"}
                  </button>
                  <div className="divider my-1" />
                  <button
                    onClick={() => {
                      disconnect();
                      setShowMenu(false);
                    }}
                    className="flex w-full items-center gap-2.5 rounded-lg px-3 py-2.5 text-body-sm text-accent-red/80 transition-colors hover:bg-accent-red/5 hover:text-accent-red"
                  >
                    <LogOut className="h-4 w-4" />
                    Disconnect
                  </button>
                </motion.div>
              )}
            </AnimatePresence>
          </div>
        ) : (
          <ConnectButton className="btn-primary" />
        )}
      </div>
    </header>
  );
}
