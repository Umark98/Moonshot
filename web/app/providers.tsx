"use client";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import {
  SuiClientProvider,
  WalletProvider,
  createNetworkConfig,
} from "@mysten/dapp-kit";
import { getFullnodeUrl } from "@mysten/sui/client";
import { useState } from "react";

const rpcUrl = process.env.NEXT_PUBLIC_SUI_RPC_URL;
const network = (process.env.NEXT_PUBLIC_SUI_NETWORK ?? "testnet") as "testnet" | "mainnet" | "devnet";

const { networkConfig } = createNetworkConfig({
  testnet: { url: network === "testnet" && rpcUrl ? rpcUrl : getFullnodeUrl("testnet") },
  mainnet: { url: network === "mainnet" && rpcUrl ? rpcUrl : getFullnodeUrl("mainnet") },
  devnet: { url: network === "devnet" && rpcUrl ? rpcUrl : getFullnodeUrl("devnet") },
});

export function Providers({ children }: { children: React.ReactNode }) {
  const [queryClient] = useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: { staleTime: 30_000, refetchInterval: 60_000 },
        },
      }),
  );

  return (
    <QueryClientProvider client={queryClient}>
      <SuiClientProvider networks={networkConfig} defaultNetwork={network}>
        <WalletProvider autoConnect>{children}</WalletProvider>
      </SuiClientProvider>
    </QueryClientProvider>
  );
}
