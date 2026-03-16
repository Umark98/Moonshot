"use client";

import { ConnectModal, useCurrentAccount } from "@mysten/dapp-kit";
import { Wallet } from "lucide-react";

interface ConnectWalletButtonProps {
  label?: string;
  className?: string;
}

export function ConnectWalletButton({
  label = "Connect Wallet",
  className = "btn-primary w-full py-3.5",
}: ConnectWalletButtonProps) {
  const account = useCurrentAccount();

  if (account) return null;

  return (
    <ConnectModal
      trigger={
        <button className={className}>
          <Wallet className="h-4 w-4" />
          {label}
        </button>
      }
    />
  );
}
