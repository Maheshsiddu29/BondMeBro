#!/usr/bin/env node
// Regenerates src/lib/abi/bondMeBro.ts from the Foundry build of the hook in this repository.
//
// The frontend must never hand-maintain the hook's ABI: the audit found only 3 of 20
// hand-written function signatures and none of 6 event signatures still matched main.
// This script copies the exact entries the frontend calls out of the compiled artifact,
// so a contract change that removes or reshapes one of them fails here rather than at
// run time against a live wallet.
//
//   forge build && node frontend/scripts/sync-abi.mjs
//
// Run `npm run abi:check` to verify the checked-in file still matches the artifact.

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "..", "..");
const artifactPath = join(repoRoot, "out", "BondMeBro.sol", "BondMeBro.json");
const outputPath = join(here, "..", "src", "lib", "abi", "bondMeBro.ts");

// Exactly the surface the dashboard reads, writes, decodes or reports. Anything not
// listed here is deliberately absent from the browser bundle.
const FUNCTIONS = [
  "BPS",
  "MAX_BOND_BPS",
  "OBSERVATION_BLOCKS",
  "MAX_SETTLE_BATCH",
  "owner",
  "poolManager",
  "poolConfig",
  "setPoolConfig",
  "getBond",
  "bondExists",
  "collateralAmountOf",
  "insurancePot",
  "accumulator",
  "blockStartTickOf",
  "effectiveCollateralBpsFor",
  "settleBond",
  "settleMany",
];

const EVENTS = ["BondOpened", "BondTaken", "BondSettled", "PoolConfigured"];

// Every custom error the UI may have to explain to a user. Errors are cheap to carry
// and turn an opaque revert into an accurate message.
const ERRORS = [
  "BondExceedsTraderMax",
  "BondNotFound",
  "BondNotMature",
  "BondNotSettleable",
  "BondViolatesNoOpVLBound",
  "IncompleteBondingConfig",
  "InvalidHookDataLength",
  "MaturityCheckpointMissing",
  "MissingHookData",
  "NotOwner",
  "PoolNotRegistered",
  "SettleBatchTooLarge",
  "UnsupportedHookDataVersion",
  "VariableLegMinimumTooSmall",
  "ZeroMaxBondAmount",
  "ZeroRefundRecipient",
];

function loadArtifact() {
  try {
    return JSON.parse(readFileSync(artifactPath, "utf8"));
  } catch (error) {
    throw new Error(
      `Could not read ${artifactPath}. Run \`forge build\` at the repository root first. (${error.message})`,
    );
  }
}

function pick(abi, kind, names) {
  return names.map((name) => {
    const entry = abi.find((item) => item.type === kind && item.name === name);
    if (!entry) throw new Error(`${kind} ${name} is absent from the compiled BondMeBro ABI.`);
    return entry;
  });
}

function render() {
  const { abi } = loadArtifact();
  const entries = [
    ...pick(abi, "function", FUNCTIONS),
    ...pick(abi, "event", EVENTS),
    ...pick(abi, "error", ERRORS),
  ];

  const body = JSON.stringify(entries, null, 2);

  return `// GENERATED FILE — do not edit by hand.
// Source: out/BondMeBro.sol/BondMeBro.json (\`forge build\` at the repository root).
// Regenerate with: node frontend/scripts/sync-abi.mjs
//
// This is the exact compiled surface of the hook on the current contract baseline,
// narrowed to the entries the dashboard uses. Getter, setter and event field orders
// differ from one another for PoolConfig; they are preserved verbatim here and must
// never be collapsed into one shared positional tuple.
import type { Abi } from "viem";

export const bondMeBroAbi = ${body} as const satisfies Abi;

export type BondMeBroAbi = typeof bondMeBroAbi;
`;
}

const rendered = render();

if (process.argv.includes("--check")) {
  const current = readFileSync(outputPath, "utf8");
  if (current !== rendered) {
    console.error(
      "src/lib/abi/bondMeBro.ts is out of date with out/BondMeBro.sol/BondMeBro.json.\n" +
        "Run: node frontend/scripts/sync-abi.mjs",
    );
    process.exit(1);
  }
  console.log("ABI is in sync with the compiled artifact.");
} else {
  writeFileSync(outputPath, rendered);
  console.log(`Wrote ${outputPath}`);
}
