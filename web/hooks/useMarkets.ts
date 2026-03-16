"use client";

import { useQuery } from "@tanstack/react-query";
import type { MarketSummary, YieldCurvePoint, ProtocolStats } from "@/types";

export function useMarkets() {
  return useQuery<MarketSummary[]>({
    queryKey: ["markets"],
    queryFn: async () => {
      const res = await fetch("/api/markets");
      if (!res.ok) throw new Error("Failed to fetch markets");
      return res.json();
    },
  });
}

export function useYieldCurve(asset = "haSUI") {
  return useQuery<YieldCurvePoint[]>({
    queryKey: ["yield-curve", asset],
    queryFn: async () => {
      const res = await fetch(`/api/yield-curve?asset=${asset}`);
      if (!res.ok) throw new Error("Failed to fetch yield curve");
      return res.json();
    },
  });
}

export function useProtocolStats() {
  return useQuery<ProtocolStats>({
    queryKey: ["stats"],
    queryFn: async () => {
      const res = await fetch("/api/stats");
      if (!res.ok) throw new Error("Failed to fetch stats");
      return res.json();
    },
  });
}
