"use client";

import { useEffect } from "react";

export default function Error({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  useEffect(() => {
    // Keep technical details in the browser console without exposing them as the main UX.
    console.error("BondMeBro dashboard error", error);
  }, [error]);

  return (
    <main className="app-error">
      <span className="eyebrow">SYSTEM NOTICE</span>
      <h1>We lost the thread.</h1>
      <p>The dashboard could not render this view. Your wallet and funds are not affected.</p>
      <button className="primary-button" type="button" onClick={() => reset()}>Try again <span>→</span></button>
    </main>
  );
}
