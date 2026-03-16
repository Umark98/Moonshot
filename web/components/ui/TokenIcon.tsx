"use client";

import { cn } from "@/lib/utils";

interface TokenIconProps {
  symbol: string;
  size?: "xs" | "sm" | "md" | "lg" | "xl";
  className?: string;
  showRing?: boolean;
}

const GRADIENTS: Record<string, string> = {
  haSUI: "from-sky-400 to-blue-600",
  sSUI: "from-violet-400 to-purple-600",
  nSUI: "from-emerald-400 to-teal-600",
  SUI: "from-blue-400 to-indigo-600",
  USDC: "from-blue-300 to-blue-500",
  PT: "from-brand-400 to-brand-600",
  YT: "from-amber-400 to-orange-500",
  SY: "from-zinc-300 to-zinc-500",
  LP: "from-cyan-400 to-teal-500",
};

const SIZES = {
  xs: "h-5 w-5 text-[8px]",
  sm: "h-7 w-7 text-[10px]",
  md: "h-9 w-9 text-xs",
  lg: "h-11 w-11 text-sm",
  xl: "h-14 w-14 text-base",
};

export function TokenIcon({
  symbol,
  size = "md",
  className,
  showRing = false,
}: TokenIconProps) {
  const gradient = GRADIENTS[symbol] ?? "from-zinc-400 to-zinc-600";
  const letters = symbol.length <= 3 ? symbol : symbol.slice(0, 2);

  return (
    <div
      className={cn(
        "relative flex items-center justify-center rounded-full bg-gradient-to-br font-bold text-white shadow-elevation-1",
        gradient,
        SIZES[size],
        showRing && "ring-2 ring-white/10 ring-offset-2 ring-offset-surface-0",
        className,
      )}
    >
      {letters}
    </div>
  );
}

export function TokenPair({
  base,
  quote,
  size = "md",
}: {
  base: string;
  quote: string;
  size?: "sm" | "md" | "lg";
}) {
  return (
    <div className="relative flex items-center">
      <TokenIcon symbol={base} size={size} />
      <TokenIcon symbol={quote} size={size} className="-ml-2" />
    </div>
  );
}
