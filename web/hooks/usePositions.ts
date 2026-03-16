"use client";

import { useQuery } from "@tanstack/react-query";
import { useCurrentAccount } from "@mysten/dapp-kit";

export function usePositions() {
  const account = useCurrentAccount();

  return useQuery({
    queryKey: ["positions", account?.address],
    queryFn: async () => {
      if (!account) return null;
      const res = await fetch(`/api/positions?address=${account.address}`);
      if (!res.ok) throw new Error("Failed to fetch positions");
      return res.json();
    },
    enabled: !!account,
  });
}
