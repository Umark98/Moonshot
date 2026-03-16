"use client";

import { useSignAndExecuteTransaction } from "@mysten/dapp-kit";
import { useQueryClient } from "@tanstack/react-query";
import { useState, useCallback } from "react";
import type { Transaction } from "@mysten/sui/transactions";
import type { TxResult } from "@/types";

/**
 * Hook for executing Crux transactions with loading state and cache invalidation.
 */
export function useCruxTx() {
  const { mutateAsync: signAndExecute } = useSignAndExecuteTransaction();
  const queryClient = useQueryClient();
  const [loading, setLoading] = useState(false);
  const [lastResult, setLastResult] = useState<TxResult | null>(null);

  const execute = useCallback(
    async (
      tx: Transaction,
      options?: { invalidateKeys?: string[][] },
    ): Promise<TxResult> => {
      setLoading(true);
      setLastResult(null);

      try {
        const result = await signAndExecute({ transaction: tx });
        const txResult: TxResult = {
          digest: result.digest,
          success: true,
        };
        setLastResult(txResult);

        // Invalidate relevant queries
        const keysToInvalidate = options?.invalidateKeys ?? [
          ["markets"],
          ["positions"],
          ["stats"],
        ];
        for (const key of keysToInvalidate) {
          queryClient.invalidateQueries({ queryKey: key });
        }

        return txResult;
      } catch (error) {
        const txResult: TxResult = {
          digest: "",
          success: false,
          error: error instanceof Error ? error.message : "Transaction failed",
        };
        setLastResult(txResult);
        return txResult;
      } finally {
        setLoading(false);
      }
    },
    [signAndExecute, queryClient],
  );

  return { execute, loading, lastResult };
}
