"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { motion } from "framer-motion";
import {
  LayoutDashboard,
  TrendingUp,
  ArrowLeftRight,
  Coins,
  Layers,
  Wallet,
  ExternalLink,
  BookOpen,
  Github,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { NAV_ITEMS } from "@/lib/constants";

const ICON_MAP: Record<string, React.ComponentType<{ className?: string }>> = {
  LayoutDashboard,
  TrendingUp,
  ArrowLeftRight,
  Coins,
  Layers,
  Wallet,
};

export function Sidebar() {
  const pathname = usePathname();

  return (
    <aside className="flex h-full w-[260px] flex-col border-r border-white/[0.04] bg-surface-1/50 backdrop-blur-xl">
      {/* Logo */}
      <div className="flex items-center gap-3.5 px-6 py-6">
        <div className="relative flex h-10 w-10 items-center justify-center rounded-xl bg-gradient-to-br from-brand-500 to-brand-700 shadow-glow-sm">
          <span className="text-lg font-extrabold text-white">C</span>
          <div className="absolute -inset-px rounded-xl bg-gradient-to-b from-white/20 to-transparent" />
        </div>
        <div>
          <h1 className="text-lg font-bold tracking-tight text-white">
            Crux
          </h1>
          <p className="text-overline text-zinc-500">YIELD PROTOCOL</p>
        </div>
      </div>

      <div className="glow-line mx-6" />

      {/* Navigation */}
      <nav className="flex-1 space-y-0.5 px-3 py-5">
        <p className="mb-2 px-3 text-overline text-zinc-600">NAVIGATE</p>
        {NAV_ITEMS.map((item) => {
          const Icon = ICON_MAP[item.icon];
          const isActive =
            pathname === item.href || pathname.startsWith(item.href + "/");

          return (
            <Link
              key={item.href}
              href={item.href}
              className={cn(
                "group relative flex items-center gap-3 rounded-xl px-3 py-2.5 text-body-sm font-medium transition-all duration-200",
                isActive
                  ? "text-white"
                  : "text-zinc-500 hover:text-zinc-300",
              )}
            >
              {/* Active indicator */}
              {isActive && (
                <motion.div
                  layoutId="nav-active"
                  className="absolute inset-0 rounded-xl bg-white/[0.06] border border-white/[0.06]"
                  transition={{ type: "spring", bounce: 0.15, duration: 0.5 }}
                />
              )}

              {/* Active bar */}
              {isActive && (
                <motion.div
                  layoutId="nav-bar"
                  className="absolute left-0 top-1/2 h-5 w-[3px] -translate-y-1/2 rounded-full bg-brand-500"
                  transition={{ type: "spring", bounce: 0.15, duration: 0.5 }}
                />
              )}

              <span className="relative z-10 flex items-center gap-3">
                {Icon && (
                  <Icon
                    className={cn(
                      "h-[18px] w-[18px] transition-colors duration-200",
                      isActive
                        ? "text-brand-400"
                        : "text-zinc-600 group-hover:text-zinc-400",
                    )}
                  />
                )}
                {item.label}
              </span>
            </Link>
          );
        })}
      </nav>

      {/* Footer */}
      <div className="space-y-1 border-t border-white/[0.04] px-3 py-4">
        <span
          className="flex items-center gap-2.5 rounded-xl px-3 py-2 text-body-sm text-zinc-600 cursor-default opacity-50"
          title="Documentation coming soon"
        >
          <BookOpen className="h-4 w-4" />
          Docs
          <span className="ml-auto text-overline text-zinc-700">SOON</span>
        </span>
        <span
          className="flex items-center gap-2.5 rounded-xl px-3 py-2 text-body-sm text-zinc-600 cursor-default opacity-50"
          title="GitHub repository coming soon"
        >
          <Github className="h-4 w-4" />
          GitHub
          <span className="ml-auto text-overline text-zinc-700">SOON</span>
        </span>
        <div className="mt-3 px-3">
          <div className="flex items-center gap-1.5">
            <div className="h-1.5 w-1.5 animate-pulse-slow rounded-full bg-accent-green" />
            <span className="text-caption text-zinc-600">Testnet v0.1.0</span>
          </div>
        </div>
      </div>
    </aside>
  );
}
