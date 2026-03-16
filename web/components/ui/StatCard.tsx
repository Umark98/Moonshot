"use client";

import { cn } from "@/lib/utils";
import { AnimatedNumber } from "./AnimatedNumber";
import type { LucideIcon } from "lucide-react";

interface StatCardProps {
  label: string;
  value: number;
  prefix?: string;
  suffix?: string;
  decimals?: number;
  change?: string;
  changeType?: "positive" | "negative" | "neutral";
  icon?: LucideIcon;
  className?: string;
}

export function StatCard({
  label,
  value,
  prefix,
  suffix,
  decimals = 0,
  change,
  changeType = "neutral",
  icon: Icon,
  className,
}: StatCardProps) {
  return (
    <div className={cn("glass-card p-5", className)}>
      <div className="flex items-start justify-between">
        <div className="space-y-2">
          <p className="stat-label">{label}</p>
          <p className="stat-value">
            <AnimatedNumber
              value={value}
              prefix={prefix}
              suffix={suffix}
              decimals={decimals}
            />
          </p>
          {change && (
            <p
              className={cn(
                "text-caption font-medium",
                changeType === "positive" && "text-accent-green",
                changeType === "negative" && "text-accent-red",
                changeType === "neutral" && "text-zinc-500",
              )}
            >
              {change}
            </p>
          )}
        </div>
        {Icon && (
          <div className="rounded-xl bg-white/[0.03] p-2.5">
            <Icon className="h-5 w-5 text-zinc-500" />
          </div>
        )}
      </div>
    </div>
  );
}
