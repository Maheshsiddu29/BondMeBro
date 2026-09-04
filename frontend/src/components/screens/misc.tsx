"use client";

/**
 * Learn.
 *
 * Short factual sentences only. The collateral is taken from the VARIABLE leg — the output
 * for exact input, the input for exact output — and is never carved out of the amount the
 * user specified. Maturity is ten blocks, not a wall-clock estimate.
 */
export function LearnScreen({ onSwap }: { onSwap: () => void }) {
  return (
    <div className="page">
      <span className="eyebrow">How it works</span>
      <h1 className="page-title">Refundable collateral, not a fee.</h1>
      <p className="page-sub">Held for 10 blocks, then returned or retained based on where the price settles.</p>

      <div className="learn-grid">
        <article className="learn-card learn-step">
          <span className="learn-num">1</span>
          <div>
            <h3>Swap</h3>
            <p>Trade as normal. One transaction.</p>
          </div>
        </article>

        <article className="learn-card learn-step">
          <span className="learn-num">2</span>
          <div>
            <h3>Bond</h3>
            <p>
              A high-impact swap has a small amount held as collateral. Exact input takes it from the output side;
              exact output takes it from the input side. The amount you specify is never reduced.
            </p>
          </div>
        </article>

        <article className="learn-card learn-step">
          <span className="learn-num">3</span>
          <div>
            <h3>Settle</h3>
            <p>
              After 10 blocks anyone can settle. If the price came back, the collateral is refunded. If the move
              persisted, it is retained for liquidity providers.
            </p>
          </div>
        </article>

        <article className="learn-card">
          <h3>How much</h3>
          <p>
            Determined at execution, from how far the pool moved in that block. Never more than 1% of the swap&apos;s
            variable side. It cannot be known before the trade lands.
          </p>
        </article>

        <article className="learn-card">
          <h3>What this is not</h3>
          <p>
            Not a fee, not an oracle, and not a claim to be MEV-proof. Same-block splitting is mitigated, not
            eliminated. Settling later gives the same answer as settling on time.
          </p>
        </article>
      </div>

      <button type="button" className="cta" style={{ marginTop: 18 }} onClick={onSwap}>
        Go to swap
      </button>
    </div>
  );
}
