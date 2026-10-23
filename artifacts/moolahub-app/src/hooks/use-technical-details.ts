import { useCallback, useSyncExternalStore } from "react";
import { useAuth } from "@/hooks/use-auth";

/**
 * "Technical details" (Settings → Advanced): an opt-in view that shows the
 * plumbing behind a balance. Off by default, so everyday screens show dollars,
 * goals and circles only; when on, account addresses, network names, explorer
 * links, transaction IDs and the receive/send-to-address flows appear.
 *
 * Stored per user in localStorage. Every access is wrapped: storage can throw
 * (private mode, blocked site data), and then the choice simply lasts for this
 * tab via the in-memory copy. The toggle is never needed to use the app.
 */

const PREFIX = "moolahub.technicalDetails.";
const memory = new Map<string, boolean>();
const listeners = new Set<() => void>();

function keyFor(userId: string | null | undefined): string {
  return `${PREFIX}${userId ?? "anonymous"}`;
}

function read(key: string): boolean {
  const cached = memory.get(key);
  if (cached !== undefined) return cached;
  let on = false;
  try {
    on = window.localStorage.getItem(key) === "1";
  } catch {
    /* storage unavailable: default off */
  }
  memory.set(key, on);
  return on;
}

function write(key: string, on: boolean): void {
  memory.set(key, on);
  try {
    if (on) window.localStorage.setItem(key, "1");
    else window.localStorage.removeItem(key);
  } catch {
    /* storage unavailable: keep the in-memory choice for this tab */
  }
  listeners.forEach((l) => l());
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/** `[enabled, setEnabled]` for the signed-in user's Technical details toggle. */
export function useTechnicalDetails(): [boolean, (on: boolean) => void] {
  const { user } = useAuth();
  const key = keyFor(user?.id);
  const enabled = useSyncExternalStore(
    subscribe,
    () => read(key),
    () => false,
  );
  const setEnabled = useCallback((on: boolean) => write(key, on), [key]);
  return [enabled, setEnabled];
}
