import type { Hex } from "viem";

import type { Deployment } from "@/lib/deployment";

/**
 * Local activity feed.
 *
 * Entries are keyed by transaction hash AND log index, so two events of the same kind in
 * one transaction keep separate identities. The previous version keyed on kind plus hash
 * alone and silently merged them.
 */
export type ActivityKind = "SWAP" | "OPENED" | "TAKEN" | "SETTLED" | "CONFIG" | "UNBONDED";

export type Activity = {
  kind: ActivityKind;
  block: string;
  detail: string;
  hash?: Hex;
  logIndex?: number;
};

export const MAX_ACTIVITY_ITEMS = 50;

export function activityStorageKey(deployment: Deployment) {
  return `bondmebro-activity-${deployment.chainId}-${deployment.hook.toLowerCase()}`;
}

const KINDS: ActivityKind[] = ["SWAP", "OPENED", "TAKEN", "SETTLED", "CONFIG", "UNBONDED"];

function isActivity(value: unknown): value is Activity {
  if (value === null || typeof value !== "object") return false;
  const item = value as Record<string, unknown>;
  return (
    typeof item.kind === "string"
    && KINDS.includes(item.kind as ActivityKind)
    && typeof item.block === "string"
    && typeof item.detail === "string"
    && (item.hash === undefined || typeof item.hash === "string")
    && (item.logIndex === undefined || typeof item.logIndex === "number")
  );
}

export function readSavedActivity(deployment: Deployment): Activity[] {
  if (typeof window === "undefined") return [];
  try {
    const raw = window.localStorage.getItem(activityStorageKey(deployment));
    if (!raw) return [];
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.filter(isActivity).slice(0, MAX_ACTIVITY_ITEMS) : [];
  } catch {
    return [];
  }
}

export function saveActivity(deployment: Deployment, activity: Activity[]) {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(
      activityStorageKey(deployment),
      JSON.stringify(activity.slice(0, MAX_ACTIVITY_ITEMS)),
    );
  } catch {
    // Storage can be disabled or full; the live feed must still work.
  }
}

export function activityKey(item: Activity) {
  return `${item.kind}:${item.hash ?? "local"}:${item.logIndex ?? "-"}:${item.block}`;
}

export function mergeActivity(previous: Activity[], incoming: Activity[]): Activity[] {
  const incomingKeys = new Set(incoming.map(activityKey));
  const merged = [...incoming, ...previous.filter((item) => !incomingKeys.has(activityKey(item)))];
  merged.sort((a, b) => {
    const left = /^\d+$/.test(a.block) ? BigInt(a.block) : -1n;
    const right = /^\d+$/.test(b.block) ? BigInt(b.block) : -1n;
    if (right > left) return 1;
    if (right < left) return -1;
    return (b.logIndex ?? 0) - (a.logIndex ?? 0);
  });
  return merged.slice(0, MAX_ACTIVITY_ITEMS);
}

export function activityIcon(kind: ActivityKind) {
  switch (kind) {
    case "OPENED":
      return "◈";
    case "TAKEN":
      return "◇";
    case "SETTLED":
      return "✓";
    case "CONFIG":
      return "⌁";
    case "UNBONDED":
      return "○";
    default:
      return "↕";
  }
}
