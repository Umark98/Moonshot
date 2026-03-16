"use client";

import {
  AreaChart,
  Area,
  XAxis,
  YAxis,
  Tooltip,
  ResponsiveContainer,
} from "recharts";

interface DailyStat {
  date: string;
  totalTvl: number;
  totalVolume: number;
  totalSwaps: number;
  uniqueUsers: number;
  totalFees: number;
}

interface TvlChartProps {
  data: DailyStat[];
  height?: number;
  metric?: "totalTvl" | "totalVolume" | "totalFees" | "uniqueUsers";
}

const metricConfig = {
  totalTvl: { label: "TVL", color: "#6366f1", prefix: "$" },
  totalVolume: { label: "Volume", color: "#22c55e", prefix: "$" },
  totalFees: { label: "Fees", color: "#f59e0b", prefix: "$" },
  uniqueUsers: { label: "Users", color: "#06b6d4", prefix: "" },
};

export function TvlChart({
  data,
  height = 240,
  metric = "totalTvl",
}: TvlChartProps) {
  const config = metricConfig[metric];

  return (
    <ResponsiveContainer width="100%" height={height}>
      <AreaChart data={data}>
        <defs>
          <linearGradient id={`gradient-${metric}`} x1="0" y1="0" x2="0" y2="1">
            <stop offset="5%" stopColor={config.color} stopOpacity={0.3} />
            <stop offset="95%" stopColor={config.color} stopOpacity={0} />
          </linearGradient>
        </defs>
        <XAxis
          dataKey="date"
          tick={{ fill: "#71717a", fontSize: 11 }}
          tickLine={false}
          axisLine={false}
          tickFormatter={(v: string) => {
            const d = new Date(v);
            return `${d.getMonth() + 1}/${d.getDate()}`;
          }}
        />
        <YAxis
          tick={{ fill: "#71717a", fontSize: 11 }}
          tickLine={false}
          axisLine={false}
          width={50}
          tickFormatter={(v: number) =>
            config.prefix +
            (v >= 1000 ? `${(v / 1000).toFixed(1)}K` : v.toFixed(1))
          }
        />
        <Tooltip
          contentStyle={{
            backgroundColor: "#18181b",
            border: "1px solid rgba(255,255,255,0.06)",
            borderRadius: "12px",
            fontSize: "12px",
          }}
          labelStyle={{ color: "#a1a1aa" }}
          formatter={(value: number) => [
            `${config.prefix}${value.toFixed(2)}`,
            config.label,
          ]}
        />
        <Area
          type="monotone"
          dataKey={metric}
          stroke={config.color}
          strokeWidth={2}
          fill={`url(#gradient-${metric})`}
        />
      </AreaChart>
    </ResponsiveContainer>
  );
}
