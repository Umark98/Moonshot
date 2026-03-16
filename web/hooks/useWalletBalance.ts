"use client";

import { useCurrentAccount, useSuiClientQuery } from "@mysten/dapp-kit";

/** Fetch the connected wallet's balance for a given coin type */
export function useWalletBalance(coinType = "0x2::sui::SUI") {
  const account = useCurrentAccount();

  const { data, isLoading, refetch } = useSuiClientQuery(
    "getBalance",
    { owner: account?.address ?? "", coinType },
    { enabled: !!account },
  );

  const totalBalance = BigInt(data?.totalBalance ?? "0");

  return {
    balance: totalBalance,
    /** Formatted balance in whole units (9 decimals for SUI) */
    formatted: formatBalance(totalBalance, 9),
    isLoading,
    refetch,
    address: account?.address,
  };
}

/** Fetch the user's coin objects (needed to pass into transactions) */
export function useWalletCoins(coinType = "0x2::sui::SUI") {
  const account = useCurrentAccount();

  const { data, isLoading, refetch } = useSuiClientQuery(
    "getCoins",
    { owner: account?.address ?? "", coinType },
    { enabled: !!account },
  );

  return {
    coins: data?.data ?? [],
    isLoading,
    refetch,
  };
}

/** Fetch user's owned objects of a specific protocol type (SY, PT, YT) */
export function useOwnedProtocolObjects(structType: string) {
  const account = useCurrentAccount();

  const { data, isLoading, refetch } = useSuiClientQuery(
    "getOwnedObjects",
    {
      owner: account?.address ?? "",
      filter: { StructType: structType },
      options: { showContent: true },
    },
    { enabled: !!account && !!structType },
  );

  return {
    objects: data?.data ?? [],
    isLoading,
    refetch,
  };
}

function formatBalance(balance: bigint, decimals: number): string {
  const divisor = BigInt(10 ** decimals);
  const whole = balance / divisor;
  const frac = (balance % divisor).toString().padStart(decimals, "0").slice(0, 4);
  return `${whole.toLocaleString()}.${frac}`;
}
