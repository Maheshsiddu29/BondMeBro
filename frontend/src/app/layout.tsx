import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "BondMeBro | Outcome-linked LP-risk sharing",
  description:
    "Swap through a BondMeBro pool, watch refundable collateral mature, and settle it permissionlessly.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  // Wallet providers live inside the deployment gate in app/page.tsx, so nothing here can
  // establish a chain connection before that deployment has been verified.
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
