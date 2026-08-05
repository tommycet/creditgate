"use client";

import { WagmiProvider, createConfig, http } from "wagmi";
import { flareTestnet } from "wagmi/chains";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { RainbowKitProvider, connectorsForWallets } from "@rainbow-me/rainbowkit";
import { metaMaskWallet } from "@rainbow-me/rainbowkit/wallets";
import { CREDIT_GATE_CONFIG } from "@/config/contract";

const queryClient = new QueryClient();

const connectors = connectorsForWallets([
  {
    groupName: "Recommended",
    wallets: [metaMaskWallet],
  },
]);

export const config = createConfig({
  chains: [
    {
      ...flareTestnet,
      id: CREDIT_GATE_CONFIG.chainId,
      name: "Flare Coston2",
      nativeCurrency: { name: "C2FLR", symbol: "C2FLR", decimals: 18 },
      rpcUrls: {
        default: { http: [CREDIT_GATE_CONFIG.rpcUrl] },
      },
      blockExplorers: {
        default: {
          name: "Coston2 Explorer",
          url: CREDIT_GATE_CONFIG.explorerUrl,
        },
      },
    },
  ],
  connectors,
  transports: {
    [CREDIT_GATE_CONFIG.chainId]: http(CREDIT_GATE_CONFIG.rpcUrl),
  },
});

export function Providers({ children }: { children: React.ReactNode }) {
  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider>{children}</RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
