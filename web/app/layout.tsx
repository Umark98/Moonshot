import type { Metadata } from "next";
import { Providers } from "./providers";
import { Sidebar } from "@/components/layout/Sidebar";
import { TopBar } from "@/components/layout/TopBar";
import "@mysten/dapp-kit/dist/index.css";
import "@/styles/globals.css";

export const metadata: Metadata = {
  title: "Crux — Yield Tokenization for Sui",
  description:
    "Split yield-bearing Sui assets into tradeable Principal (PT) and Yield (YT) tokens. Fixed rates, leveraged yield, and the first on-chain yield curve for Sui DeFi.",
  icons: { icon: "/favicon.ico" },
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" className="dark" suppressHydrationWarning>
      <body className="min-h-screen overflow-hidden">
        <Providers>
          <div className="flex h-screen">
            <Sidebar />
            <div className="flex flex-1 flex-col overflow-hidden">
              <TopBar />
              <main className="flex-1 overflow-y-auto">
                <div className="mx-auto max-w-[1400px] px-6 py-8 lg:px-10">
                  {children}
                </div>
              </main>
            </div>
          </div>
        </Providers>
      </body>
    </html>
  );
}
