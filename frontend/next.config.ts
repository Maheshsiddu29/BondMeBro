import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  // The hosted preview uses a dynamic *.e2b.app origin.
  allowedDevOrigins: ["*.e2b.app"],
};

export default nextConfig;
