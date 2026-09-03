/**
 * Shown when no complete, self-consistent deployment is configured.
 *
 * This is a deliberate dead end. The previous build shipped a Sepolia hook address whose
 * permission bits (0x10CC) prove it is not this contract, and would happily have quoted,
 * approved and swapped against it. A successful transaction against the wrong hook looks
 * exactly like a working demo, which is worse than no demo at all.
 */
export function DeploymentRequired({ problems }: { problems: string[] }) {
  return (
    <main className="app-error">
      <span className="eyebrow">DEPLOYMENT REQUIRED</span>
      <h1>No verified deployment is configured.</h1>
      <p>
        This build refuses to read from or write to a chain until every part of one deployment is supplied and
        self-consistent. Nothing falls back to a previously shipped address.
      </p>
      <ul className="deployment-problem-list">
        {problems.map((problem) => (
          <li key={problem}>{problem}</li>
        ))}
      </ul>
      <p>
        Set the following before starting the app. The hook&apos;s low 14 address bits must equal <code>0x10C4</code>,
        the two currencies must be standard ERC20s sorted low-to-high, and the pool ID is derived from the key rather
        than supplied.
      </p>
      <pre className="deployment-env-block">
        {[
          "RPC_URL=                        # server-side, must serve NEXT_PUBLIC_CHAIN_ID",
          "NEXT_PUBLIC_CHAIN_ID=",
          "NEXT_PUBLIC_NETWORK_NAME=",
          "NEXT_PUBLIC_EXPLORER_URL=",
          "NEXT_PUBLIC_HOOK_ADDRESS=",
          "NEXT_PUBLIC_POOL_MANAGER=",
          "NEXT_PUBLIC_UNIVERSAL_ROUTER=",
          "NEXT_PUBLIC_QUOTER=",
          "NEXT_PUBLIC_PERMIT2=",
          "NEXT_PUBLIC_CURRENCY0=",
          "NEXT_PUBLIC_CURRENCY1=",
          "NEXT_PUBLIC_POOL_FEE=",
          "NEXT_PUBLIC_TICK_SPACING=",
          "NEXT_PUBLIC_DEPLOYMENT_BLOCK=",
          "NEXT_PUBLIC_POOL_ID=            # optional; checked against the derived ID",
        ].join("\n")}
      </pre>
    </main>
  );
}
