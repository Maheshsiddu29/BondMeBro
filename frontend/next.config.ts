import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  // Arena serves the browser preview from a dynamic *.e2b.app origin.
  allowedDevOrigins: ["*.e2b.app"],
};

export default nextConfig;
