"use client";

import { useQuery } from "@tanstack/react-query";

interface DailyStat {
  date: string;
  totalTvl: number;
  totalVolume: number;
  totalSwaps: number;
  totalMints: number;
  totalRedeems: number;
  uniqueUsers: number;
  totalFees: number;
}

interface RatePoint {
  impliedRate: number;
  ptPrice: number;
  tvl: number;
  timestamp: string;
}

interface SwapRecord {
  id: number;
  txDigest: string;
  direction: string;
  amountIn: string;
  amountOut: string;
  ptPrice: number;
  timestampMs: string;
  market: {
    underlyingSymbol: string;
    maturityMs: bigint;
    durationMonths: number;
  };
}

export function useDailyStats(days = 30) {
  return useQuery<DailyStat[]>({
    queryKey: ["daily-stats", days],
    queryFn: async () => {
      const res = await fetch(`/api/daily-stats?days=${days}`);
      if (!res.ok) throw new Error("Failed to fetch daily stats");
      return res.json();
    },
  });
}

export function useRateHistory(marketId: string, period = "7d") {
  return useQuery<RatePoint[]>({
    queryKey: ["rate-history", marketId, period],
    queryFn: async () => {
      const res = await fetch(
        `/api/history?marketId=${marketId}&period=${period}&type=rate`
      );
      if (!res.ok) throw new Error("Failed to fetch rate history");
      return res.json();
    },
    enabled: !!marketId,
  });
}

export function useSwapHistory(params?: {
  marketId?: string;
  trader?: string;
  limit?: number;
}) {
  return useQuery<{ swaps: SwapRecord[]; total: number }>({
    queryKey: ["swap-history", params],
    queryFn: async () => {
      const search = new URLSearchParams();
      if (params?.marketId) search.set("marketId", params.marketId);
      if (params?.trader) search.set("trader", params.trader);
      if (params?.limit) search.set("limit", String(params.limit));
      const res = await fetch(`/api/swaps?${search}`);
      if (!res.ok) throw new Error("Failed to fetch swaps");
      return res.json();
    },
  });
}

export function useSyncStatus() {
  return useQuery({
    queryKey: ["sync-status"],
    queryFn: async () => {
      const res = await fetch("/api/sync");
      if (!res.ok) throw new Error("Failed to fetch sync status");
      return res.json();
    },
  });
}
