import type { Metadata } from "next";
import { Providers } from "./providers";
import { Toaster } from "react-hot-toast";
import "@rainbow-me/rainbowkit/styles.css";
import "./globals.css";

export const metadata: Metadata = {
  title: "CreditGate — Private FXRP Credit on Flare",
  description:
    "Private eligibility and repayment-verification layer for FXRP-backed credit on Flare Coston2",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body className="bg-gray-950 text-white antialiased">
        <Providers>{children}</Providers>
        <Toaster
          position="top-right"
          toastOptions={{
            duration: 5000,
            style: {
              background: "#1f2937",
              color: "#f9fafb",
              border: "1px solid #374151",
              borderRadius: "0.5rem",
            },
            success: {
              iconTheme: { primary: "#22c55e", secondary: "#f9fafb" },
            },
            error: {
              iconTheme: { primary: "#ef4444", secondary: "#f9fafb" },
            },
          }}
        />
      </body>
    </html>
  );
}
