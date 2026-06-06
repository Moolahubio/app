import { useCallback } from "react";
import { useSmartWallets } from "@privy-io/react-auth/smart-wallets";
import { encodeFunctionData, type Address, type Hex } from "viem";
import { ERC20_ABI, CIRCLE_ABI, ACCUMULATION_ABI, GOAL_VAULT_ABI } from "../lib/onchain/abis";
import { idToBytes32 } from "../lib/onchain/ids";

/**
 * User-signed on-chain actions for Circles and Goals, executed through the user's
 * Privy smart account (ERC-4337). Gas is sponsored by the paymaster registered in
 * the Privy dashboard, so these are gasless for the user.
 *
 * Smart accounts can't use EIP-2612 permit (USDC verifies with ecrecover, not
 * ERC-1271), so token-pulling actions do `approve` then the call — two sponsored
 * user-ops. The user signs each.
 *
 * Each action returns the final transaction hash; surface it as a Basescan link.
 */
export function useOnchain() {
  const { client } = useSmartWallets();
  const ready = !!client;

  const send = useCallback(
    async (to: Address, data: Hex): Promise<Hex> => {
      if (!client) throw new Error("Wallet not ready");
      // Privy's smart-wallet client is a drop-in viem WalletClient; account + chain
      // are bound, and gas is sponsored by the dashboard paymaster.
      return (await client.sendTransaction({ to, data })) as Hex;
    },
    [client],
  );

  const approve = useCallback(
    (usdc: Address, spender: Address, amount: bigint) =>
      send(usdc, encodeFunctionData({ abi: ERC20_ABI, functionName: "approve", args: [spender, amount] })),
    [send],
  );

  /** Contribute the round amount to a circle (works for rotation and accumulation). */
  const contributeToCircle = useCallback(
    async (params: { usdc: Address; circle: Address; contributionUnits: bigint }): Promise<{ hash: Hex }> => {
      await approve(params.usdc, params.circle, params.contributionUnits);
      const hash = await send(
        params.circle,
        encodeFunctionData({ abi: CIRCLE_ABI, functionName: "contribute", args: [] }),
      );
      return { hash };
    },
    [approve, send],
  );

  /** Withdraw your own accumulated savings from an accumulation circle. */
  const withdrawFromCircle = useCallback(
    async (circle: Address): Promise<{ hash: Hex }> => ({
      hash: await send(circle, encodeFunctionData({ abi: ACCUMULATION_ABI, functionName: "withdraw", args: [] })),
    }),
    [send],
  );

  /** Reclaim unsettled contributions from a cancelled rotation circle. */
  const claimCircleRefund = useCallback(
    async (circle: Address): Promise<{ hash: Hex }> => ({
      hash: await send(circle, encodeFunctionData({ abi: CIRCLE_ABI, functionName: "claimRefund", args: [] })),
    }),
    [send],
  );

  /** Deposit into a goal (free). */
  const depositToGoal = useCallback(
    async (params: { usdc: Address; vault: Address; goalUuid: string; units: bigint }): Promise<{ hash: Hex }> => {
      await approve(params.usdc, params.vault, params.units);
      const hash = await send(
        params.vault,
        encodeFunctionData({
          abi: GOAL_VAULT_ABI,
          functionName: "deposit",
          args: [idToBytes32(params.goalUuid), params.units],
        }),
      );
      return { hash };
    },
    [approve, send],
  );

  /** Withdraw from a goal (2% fee applied on-chain; caller receives the net). */
  const withdrawFromGoal = useCallback(
    async (params: { vault: Address; goalUuid: string; grossUnits: bigint }): Promise<{ hash: Hex }> => ({
      hash: await send(
        params.vault,
        encodeFunctionData({
          abi: GOAL_VAULT_ABI,
          functionName: "withdraw",
          args: [idToBytes32(params.goalUuid), params.grossUnits],
        }),
      ),
    }),
    [send],
  );

  return {
    ready,
    contributeToCircle,
    withdrawFromCircle,
    claimCircleRefund,
    depositToGoal,
    withdrawFromGoal,
  };
}
