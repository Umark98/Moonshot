"use client";

import {
  ResponsiveContainer,
  AreaChart,
  Area,
  XAxis,
  YAxis,
  Tooltip,
  CartesianGrid,
} from "recharts";
import type { YieldCurvePoint } from "@/types";

interface YieldCurveChartProps {
  data: YieldCurvePoint[];
  height?: number;
}

function CustomTooltip({ active, payload, label }: any) {
  if (!active || !payload?.length) return null;

  const rate = payload[0].value;
  const point = payload[0].payload as YieldCurvePoint;

  return (
    <div className="glass-elevated rounded-xl p-4 min-w-[180px]">
      <p className="text-caption text-zinc-400 mb-2">Maturity: {label}</p>
      <div className="space-y-1.5">
        <div className="flex justify-between gap-6">
          <span className="text-body-sm text-zinc-400">Implied APY</span>
          <span className="mono-number text-body-sm font-bold text-accent-green">
            {(rate * 100).toFixed(2)}%
          </span>
        </div>
        <div className="flex justify-between gap-6">
          <span className="text-body-sm text-zinc-400">PT Price</span>
          <span className="mono-number text-body-sm text-white">
            {point.ptPrice.toFixed(4)}
          </span>
        </div>
        <div className="flex justify-between gap-6">
          <span className="text-body-sm text-zinc-400">Days</span>
          <span className="text-body-sm text-zinc-300">
            {point.daysToMaturity}d
          </span>
        </div>
      </div>
    </div>
  );
}

export function YieldCurveChart({ data, height = 320 }: YieldCurveChartProps) {
  if (data.length === 0) {
    return (
      <div className="flex items-center justify-center text-body-sm text-zinc-600" style={{ height }}>
        No yield curve data available
      </div>
    );
  }

  return (
    <ResponsiveContainer width="100%" height={height}>
      <AreaChart data={data} margin={{ top: 10, right: 10, bottom: 0, left: -10 }}>
        <defs>
          <linearGradient id="curveGradient" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="#6366f1" stopOpacity={0.2} />
            <stop offset="100%" stopColor="#6366f1" stopOpacity={0} />
          </linearGradient>
          <linearGradient id="lineGradient" x1="0" y1="0" x2="1" y2="0">
            <stop offset="0%" stopColor="#818cf8" />
            <stop offset="50%" stopColor="#6366f1" />
            <stop offset="100%" stopColor="#a78bfa" />
          </linearGradient>
        </defs>
        <CartesianGrid
          strokeDasharray="3 3"
          stroke="rgba(255,255,255,0.03)"
          vertical={false}
        />
        <XAxis
          dataKey="label"
          tick={{ fontSize: 11, fill: "#52525b", fontWeight: 500 }}
          axisLine={false}
          tickLine={false}
          dy={8}
        />
        <YAxis
          tickFormatter={(v: number) => `${(v * 100).toFixed(1)}%`}
          tick={{ fontSize: 11, fill: "#52525b", fontWeight: 500 }}
          axisLine={false}
          tickLine={false}
          width={52}
          dx={-4}
        />
        <Tooltip content={<CustomTooltip />} cursor={{ stroke: "rgba(99, 102, 241, 0.2)", strokeWidth: 1 }} />
        <Area
          type="monotone"
          dataKey="impliedRate"
          stroke="url(#lineGradient)"
          strokeWidth={2.5}
          fill="url(#curveGradient)"
          dot={{
            fill: "#6366f1",
            stroke: "#13141f",
            strokeWidth: 3,
            r: 5,
          }}
          activeDot={{
            fill: "#818cf8",
            stroke: "#13141f",
            strokeWidth: 3,
            r: 7,
          }}
        />
      </AreaChart>
    </ResponsiveContainer>
  );
}
