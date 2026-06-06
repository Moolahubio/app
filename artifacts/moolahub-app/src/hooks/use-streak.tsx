import { useGetStreaks, getGetStreaksQueryKey } from "@workspace/api-client-react";

/**
 * Thin wrapper over the generated streak query so callers don't repeat the
 * query-key wiring. Streaks are a derived, non-financial projection — safe to
 * fetch anywhere without affecting money flows.
 */
export function useStreak(enabled = true) {
  return useGetStreaks({
    query: { enabled, queryKey: getGetStreaksQueryKey() },
  });
}

export { getGetStreaksQueryKey };
