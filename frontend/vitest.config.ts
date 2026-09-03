import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

/**
 * Node-environment unit tests for the contract-integration layer.
 *
 * The audit's FE-20 finding was that every build check passed while the frontend spoke to
 * a contract that no longer existed. These tests exist to make that impossible: they pin
 * ABI shape, payload bytes, limit arithmetic, currency mapping, maturity, receipt handling
 * and decimal formatting against the current contract baseline.
 */
export default defineConfig({
  resolve: {
    alias: { "@": fileURLToPath(new URL("./src", import.meta.url)) },
  },
  test: {
    environment: "node",
    include: ["src/**/*.test.ts"],
  },
});
