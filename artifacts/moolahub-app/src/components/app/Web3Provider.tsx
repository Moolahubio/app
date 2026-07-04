import type { ReactNode } from "react";
import { PrivyProvider } from "@privy-io/react-auth";
import { SmartWalletsProvider } from "@privy-io/react-auth/smart-wallets";
import { monadTestnet } from "viem/chains";
import { useTheme } from "@/hooks/use-theme";

const APP_ID = import.meta.env.VITE_PRIVY_APP_ID ?? "";

/** True when a usable Privy app id is configured for this deployment. */
export const isWeb3Enabled: boolean = Boolean(APP_ID && APP_ID.length >= 10);

/**
 * Mounts Privy + smart-wallet context once, at the app root, so any component can
 * safely call usePrivy()/useLogin()/useSmartWallets(). When no Privy app id is
 * configured the app still renders and wallet features degrade to an
 * "unavailable" state (see WalletSetupCard). Must live inside ThemeProvider
 * because Privy's appearance follows the resolved theme.
 */
export function Web3Provider({ children }: { children: ReactNode }) {
  const { resolvedTheme } = useTheme();

  if (!isWeb3Enabled) {
    return <>{children}</>;
  }

  return (
    <PrivyProvider
      appId={APP_ID}
      config={{
        defaultChain: monadTestnet,
        supportedChains: [monadTestnet],
        embeddedWallets: {
          ethereum: {
            createOnLogin: "users-without-wallets",
          },
        },
        appearance: {
          theme: resolvedTheme,
          accentColor: "#0E9E6E",
          logo: `${import.meta.env.BASE_URL}brand/moolahub_app_icon.png`,
        },
      }}
    >
      <SmartWalletsProvider>{children}</SmartWalletsProvider>
    </PrivyProvider>
  );
}
