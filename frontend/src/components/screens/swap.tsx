"use client";

import { useEffect, useMemo, useState } from "react";
import type { Address, Hex } from "viem";
import { usePublicClient, useReadContract, useSwitchChain, useWriteContract } from "wagmi";

import { erc20Abi, permit2Abi, universalRouterAbi, v4QuoterAbi } from "@/lib/abi/external";
import type { Activity } from "@/lib/activity";
import { interpretSwapReceipt, type BondOpenedEvent, type BondTakenEvent } from "@/lib/bond";
import { explorerTx, poolKeyOf } from "@/lib/deployment";
import { describeError, isLiquidityError } from "@/lib/errors";
import { formatAmount, parseUint128Amount, type TokenMeta } from "@/lib/format";
import {
  assertContext,
  assertReceiptSucceeded,
  type IntendedContext,
  type SubmittedSummary,
} from "@/lib/guards";
import { allowanceStatus, sessionAllowanceFor, sessionExpiry } from "@/lib/allowance";
import { submitWithBoundedGas } from "@/lib/gas";
import { encodeHookData, EXACT_INPUT_MAX_BOND_AMOUNT } from "@/lib/hookData";
import { exactInputLimits, exactOutputLimits, LimitError } from "@/lib/limits";
import { thresholdsFor, type SwapKind } from "@/lib/poolConfig";
import { buildExactInputPlan, buildExactOutputPlan, spendRequirement } from "@/lib/swapPlan";
import type { ProtocolState } from "@/lib/useProtocol";

type FlowState = "idle" | "approving" | "sending" | "success" | "error";
type QuotePhase = "idle" | "loading" | "refreshing" | "ready" | "empty" | "failed";

const DEADLINE_SECONDS = 1_200;

/** Bounded backoff for transient quoter / RPC failures. */
const QUOTE_RETRIES = 3;

export function SwapScreen({
  protocol,
  account,
  walletChainId,
  isConnected,
  onConnect,
  onViewBonds,
  onActivity,
  onBondDiscovered,
  onSwapConfirmed,
}: {
  protocol: ProtocolState;
  account?: Address;
  walletChainId?: number;
  isConnected: boolean;
  onConnect: () => void;
  onViewBonds: () => void;
  onActivity: (item: Activity) => void;
  onBondDiscovered: (opened: BondOpenedEvent, taken?: BondTakenEvent) => void;
  onSwapConfirmed: () => void;
}) {
  const { deployment, constants, poolConfig, token0, token1 } = protocol;
  const publicClient = usePublicClient({ chainId: deployment.chainId });
  const { writeContractAsync } = useWriteContract();
  const { switchChain } = useSwitchChain();

  const [kind, setKind] = useState<SwapKind>("exactInput");
  const [payIsCurrency0, setPayIsCurrency0] = useState(true);
  const [amountText, setAmountText] = useState("");
  const [toleranceText, setToleranceText] = useState("1.50");
  const [flow, setFlow] = useState<FlowState>("idle");
  const [txHash, setTxHash] = useState<Hex | undefined>();
  const [approvalError, setApprovalError] = useState("");
  const [swapError, setSwapError] = useState("");
  const [submitted, setSubmitted] = useState<SubmittedSummary | undefined>();
  const [outcome, setOutcome] = useState<
    { kind: "bonded"; bondId: Hex; collateral?: bigint; currency?: Address } | { kind: "unbonded" } | undefined
  >();

  const zeroForOne = payIsCurrency0;
  const payToken = payIsCurrency0 ? token0 : token1;
  const receiveToken = payIsCurrency0 ? token1 : token0;

  const networkCorrect = walletChainId === deployment.chainId;

  // Exact input: the typed amount is the input. Exact output: it is the output.
  const amountToken = kind === "exactInput" ? payToken : receiveToken;
  const parsedAmount = amountToken ? parseUint128Amount(amountText, amountToken.decimals) : undefined;
  const specifiedAmount = parsedAmount?.ok ? parsedAmount.value : undefined;
  const amountProblem = amountText && parsedAmount && !parsedAmount.ok ? parsedAmount.reason : undefined;

  const toleranceBps = parseToleranceBps(toleranceText);

  const thresholds = useMemo(
    () => (poolConfig ? thresholdsFor({ config: poolConfig, deployment, kind, zeroForOne }) : undefined),
    [poolConfig, deployment, kind, zeroForOne],
  );
  const collateralToken = thresholds ? (thresholds.collateralIsCurrency0 ? token0 : token1) : undefined;

  const quoteHookData = useMemo(() => {
    // Quoting needs a valid version-2 payload too: an enabled pool decodes hookData in
    // beforeSwap, and the simulation runs the same code the execution will.
    const recipient = account ?? deployment.hook;
    try {
      return encodeHookData({ refundRecipient: recipient, maxBondAmount: EXACT_INPUT_MAX_BOND_AMOUNT });
    } catch {
      return undefined;
    }
  }, [account, deployment.hook]);

  const quoteEnabled = Boolean(
    protocol.canTrade
      && protocol.rpcOnline
      && constants
      && quoteHookData
      && specifiedAmount !== undefined
      && specifiedAmount > 0n
      && payToken
      && receiveToken,
  );

  const quoteArgs = useMemo(
    () =>
      [
        {
          poolKey: poolKeyOf(deployment),
          zeroForOne,
          exactAmount: specifiedAmount ?? 0n,
          hookData: quoteHookData ?? "0x",
        },
      ] as const,
    [deployment, zeroForOne, specifiedAmount, quoteHookData],
  );

  const quoteRead = useReadContract({
    address: deployment.quoter,
    abi: v4QuoterAbi,
    chainId: deployment.chainId,
    functionName: kind === "exactInput" ? "quoteExactInputSingle" : "quoteExactOutputSingle",
    args: quoteArgs,
    query: {
      enabled: quoteEnabled,
      refetchInterval: 5_000,
      // A rate-limited or briefly unreachable RPC is a transient condition, not a failed
      // quote. Retry with bounded backoff; the figure itself is withheld meanwhile.
      retry: QUOTE_RETRIES,
      retryDelay: (attempt: number) => Math.min(1_000 * 2 ** attempt, 8_000),
    },
  });

  const quoteErrored = quoteEnabled && quoteRead.isError;
  const noLiquidity = quoteErrored && isLiquidityError(quoteRead.error);

  // A QUOTE IN DOUBT IS NO QUOTE. While a refetch is failing, the previous figure is
  // withheld rather than shown: a stale minimum-received is worse than an empty one,
  // because the user could sign against a bound derived from an older pool state.
  const quoteValue = quoteEnabled && !quoteErrored ? readQuote(quoteRead.data) : undefined;
  const quoteReady = quoteEnabled && !quoteErrored && quoteValue !== undefined && quoteValue > 0n;
  const hadQuote = readQuote(quoteRead.data) !== undefined;

  const quotePhase: QuotePhase = !quoteEnabled
    ? "idle"
    : quoteErrored && hadQuote && !noLiquidity
      ? "refreshing"
      : noLiquidity
        ? "empty"
        : quoteErrored
          ? "failed"
          : quoteReady
            ? "ready"
            : "loading";

  // For exact output the collateral currency IS the input, and the variable leg IS the
  // consumed input, so both BMB-01 gates measure the same quantity. The larger of the two is
  // the smallest total input at which this pool could bond this trade — the only thing that
  // makes a zero-derived collateral ceiling provably safe.
  const exactOutputBondingMinimum =
    thresholds && kind === "exactOutput"
      ? thresholds.consumedInputMinimum > thresholds.variableLegMinimum
        ? thresholds.consumedInputMinimum
        : thresholds.variableLegMinimum
      : undefined;

  const [limits, limitProblem] = useMemo(() => {
    if (!constants || quoteValue === undefined || toleranceBps === undefined) {
      return [undefined, undefined] as const;
    }
    try {
      if (kind === "exactInput") {
        const result = exactInputLimits({ quotedNetOutput: quoteValue, toleranceBps, constants });
        return [{ kind, ...result } as const, undefined] as const;
      }
      // quoteValue is the quoter's exact-output result: the TOTAL input, already including
      // the collateral simulated at quote-time state. It is passed through as-is.
      const result = exactOutputLimits({
        quotedTotalInput: quoteValue,
        toleranceBps,
        constants,
        bondingEnabled: Boolean(poolConfig?.bondingEnabled),
        bondingMinimum: exactOutputBondingMinimum,
      });
      return [{ kind, ...result } as const, undefined] as const;
    } catch (error) {
      return [
        undefined,
        error instanceof LimitError ? error.message : "Swap limits could not be prepared.",
      ] as const;
    }
  }, [constants, quoteValue, toleranceBps, kind, poolConfig?.bondingEnabled, exactOutputBondingMinimum]);

  const spend = useMemo(
    () =>
      limits
        ? spendRequirement({
            deployment,
            kind,
            zeroForOne,
            amountIn: kind === "exactInput" ? specifiedAmount : undefined,
            amountInMaximum: limits.kind === "exactOutput" ? limits.amountInMaximum : undefined,
          })
        : undefined,
    [limits, deployment, kind, zeroForOne, specifiedAmount],
  );

  const balanceRead = useReadContract({
    address: payToken?.address,
    abi: erc20Abi,
    chainId: deployment.chainId,
    functionName: "balanceOf",
    args: account ? [account] : undefined,
    query: { enabled: Boolean(account && payToken), refetchInterval: 10_000 },
  });
  const tokenAllowanceRead = useReadContract({
    address: payToken?.address,
    abi: erc20Abi,
    chainId: deployment.chainId,
    functionName: "allowance",
    args: account ? [account, deployment.permit2] : undefined,
    query: { enabled: Boolean(account && payToken), refetchInterval: 10_000 },
  });
  const permit2AllowanceRead = useReadContract({
    address: deployment.permit2,
    abi: permit2Abi,
    chainId: deployment.chainId,
    functionName: "allowance",
    args: account && payToken ? [account, payToken.address, deployment.universalRouter] : undefined,
    query: { enabled: Boolean(account && payToken), refetchInterval: 10_000 },
  });

  const balance = balanceRead.data as bigint | undefined;
  const tokenAllowance = (tokenAllowanceRead.data as bigint | undefined) ?? 0n;
  const permit2Allowance = permit2AllowanceRead.data as readonly [bigint, number, number] | undefined;
  const permit2Amount = permit2Allowance ? BigInt(permit2Allowance[0]) : 0n;
  const permit2Expiry = permit2Allowance ? BigInt(permit2Allowance[1]) : 0n;

  // Sufficiency is judged against THIS swap; the grant, when one is needed, covers a session.
  // That asymmetry is what lets the second and later demo swaps skip approval entirely.
  const allowance = spend
    ? allowanceStatus({
        swapRequirement: spend.amount,
        tokenAllowance,
        permit2Amount,
        permit2Expiration: permit2Expiry,
        nowSeconds: Math.floor(Date.now() / 1000),
      })
    : undefined;
  const spendingReady = Boolean(allowance?.ready);
  const balanceCovers = balance === undefined || (spend ? balance >= spend.amount : true);

  useEffect(() => {
    // Any change to what is being traded invalidates a finished result: a success line must
    // never describe a request the form no longer shows.
    setFlow("idle");
    setApprovalError("");
    setSwapError("");
    setTxHash(undefined);
    setSubmitted(undefined);
    setOutcome(undefined);
  }, [kind, payIsCurrency0, amountText, toleranceText, account, walletChainId]);

  const busy = flow === "approving" || flow === "sending";

  const canSubmit = Boolean(
    isConnected
      && networkCorrect
      && protocol.canTrade
      && protocol.rpcOnline
      && account
      && constants
      && payToken
      && receiveToken
      && specifiedAmount !== undefined
      && specifiedAmount > 0n
      && quoteReady
      && limits
      && spend
      && spendingReady
      && balanceCovers
      && !busy,
  );

  // Wallet setup is a small secondary state, never a wizard bolted onto the main button.
  const needsWalletSetup = Boolean(
    isConnected && networkCorrect && spend && quoteReady && !spendingReady && !busy,
  );

  function intended(): IntendedContext | undefined {
    if (!account || walletChainId === undefined) return undefined;
    return { address: account, chainId: walletChainId };
  }

  async function prepareWallet() {
    const context = intended();
    if (!context || !publicClient || !payToken || !spend) return;
    setFlow("approving");
    // A new attempt clears the previous failure; a stale message must never sit under a
    // subsequently successful action.
    setApprovalError("");
    setSwapError("");
    try {
      // Re-verify before EVERY wallet request, including between the two grants: the user can
      // switch account or network while the first receipt is being awaited.
      assertContext(context, { address: account, chainId: walletChainId });

      const sessionAmount = sessionAllowanceFor(spend.amount);

      if (!allowance?.tokenReady) {
        const call = {
          address: payToken.address,
          abi: erc20Abi,
          functionName: "approve",
          args: [deployment.permit2, sessionAmount],
          account: context.address,
        } as const;

        const { hash } = await submitWithBoundedGas({
          call,
          chainId: context.chainId,
          label: `${payToken.symbol} approval`,
          estimateGas: (c) => publicClient.estimateContractGas(c),
          write: (c) => writeContractAsync(c),
        });

        assertReceiptSucceeded(
          await publicClient.waitForTransactionReceipt({ hash }),
          `${payToken.symbol} approval`,
        );
      }

      assertContext(context, { address: account, chainId: walletChainId });

      if (!allowance?.permit2Ready) {
        // A BOUNDED SESSION grant, expiring in one hour. Not uint160 max, and not exactly one
        // swap either — the latter made every demo trade re-approve.
        const expiration = sessionExpiry(Math.floor(Date.now() / 1000));
        const call = {
          address: deployment.permit2,
          abi: permit2Abi,
          functionName: "approve",
          args: [payToken.address, deployment.universalRouter, sessionAmount, expiration],
          account: context.address,
        } as const;

        const { hash } = await submitWithBoundedGas({
          call,
          chainId: context.chainId,
          label: "Permit2 approval",
          estimateGas: (c) => publicClient.estimateContractGas(c),
          write: (c) => writeContractAsync(c),
        });

        assertReceiptSucceeded(await publicClient.waitForTransactionReceipt({ hash }), "Permit2 approval");
      }

      await Promise.all([tokenAllowanceRead.refetch(), permit2AllowanceRead.refetch()]);
      setApprovalError("");
      setFlow("idle");
    } catch (error) {
      setFlow("error");
      setApprovalError(describeError(error));
    }
  }

  async function submitSwap() {
    const context = intended();
    if (!canSubmit || !context || !publicClient || !payToken || !receiveToken || !limits || !spend) return;
    if (specifiedAmount === undefined) return;

    setFlow("sending");
    setApprovalError("");
    setSwapError("");
    setTxHash(undefined);
    setOutcome(undefined);

    try {
      assertContext(context, { address: account, chainId: walletChainId });

      const plan =
        limits.kind === "exactInput"
          ? buildExactInputPlan({
              deployment,
              zeroForOne,
              amountIn: specifiedAmount,
              amountOutMinimum: limits.amountOutMinimum,
              refundRecipient: context.address,
              recipient: context.address,
              maxBondAmount: limits.maxBondAmount,
            })
          : buildExactOutputPlan({
              deployment,
              zeroForOne,
              amountOut: specifiedAmount,
              amountInMaximum: limits.amountInMaximum,
              refundRecipient: context.address,
              recipient: context.address,
              maxBondAmount: limits.maxBondAmount,
            });

      // Freeze what is being signed. Later edits to the form cannot rewrite this.
      const frozen: SubmittedSummary = {
        kind: limits.kind,
        account: context.address,
        chainId: context.chainId,
        inputSymbol: payToken.symbol,
        outputSymbol: receiveToken.symbol,
        primaryAmount:
          limits.kind === "exactInput"
            ? `${formatAmount(specifiedAmount, payToken.decimals)} ${payToken.symbol}`
            : `${formatAmount(limits.amountInMaximum, payToken.decimals)} ${payToken.symbol} maximum`,
        secondaryAmount:
          limits.kind === "exactInput"
            ? `${formatAmount(limits.amountOutMinimum, receiveToken.decimals)} ${receiveToken.symbol} minimum`
            : `${formatAmount(specifiedAmount, receiveToken.decimals)} ${receiveToken.symbol} exactly`,
        refundRecipient: context.address,
        maxBondAmountLabel:
          limits.kind === "exactInput"
            ? "unbounded ceiling; protection is the minimum output"
            : limits.ceilingIsProvenUnbonded
              ? "none — this trade cannot bond on this pool"
              : `${formatAmount(limits.maxBondAmount, payToken.decimals)} ${payToken.symbol}`,
        hookData: plan.hookData,
        submittedAt: Date.now(),
      };
      setSubmitted(frozen);

      // The deadline is computed ONCE. Estimating one set of arguments and signing another
      // would make the estimate meaningless.
      const deadline = BigInt(Math.floor(Date.now() / 1000) + DEADLINE_SECONDS);

      const execute = {
        address: deployment.universalRouter,
        abi: universalRouterAbi,
        functionName: "execute",
        args: [plan.commands, plan.inputs, deadline],
        account: context.address,
      } as const;

      // Estimate the EXACT transaction about to be sent, through this app's own chain-bound
      // client rather than leaving the limit to the wallet.
      const { hash, gas } = await submitWithBoundedGas({
        call: execute,
        chainId: context.chainId,
        label: "swap",
        estimateGas: (c) => publicClient.estimateContractGas(c),
        write: (c) => writeContractAsync(c),
      });

      setSubmitted({ ...frozen, gasLimit: gas });
      setTxHash(hash);

      const receipt = assertReceiptSucceeded(await publicClient.waitForTransactionReceipt({ hash }), "swap");

      // ---------------------------------------------------------------------------------
      // THE SWAP HAS SUCCEEDED. Nothing below may present it as a failure.
      // ---------------------------------------------------------------------------------
      setFlow("success");
      setSwapError("");

      try {
        const result = interpretSwapReceipt({
          logs: receipt.logs,
          hookAddress: deployment.hook,
          poolId: deployment.poolId,
          refundRecipient: context.address,
        });

        if (result.kind === "bonded") {
          // Straight into the store, so the card is on screen before any log scan runs.
          onBondDiscovered(result.opened, result.taken);
          setOutcome({
            kind: "bonded",
            bondId: result.opened.bondId,
            collateral: result.taken?.bond,
            currency: result.taken?.currency,
          });
          onActivity({
            kind: "OPENED",
            block: receipt.blockNumber.toString(),
            hash,
            logIndex: result.opened.logIndex,
            detail: `Bond opened · matures at block ${result.opened.maturityBlock}`,
          });
        } else {
          // No BondOpened is a normal outcome, not a missing event to keep waiting for.
          setOutcome({ kind: "unbonded" });
          onActivity({
            kind: "UNBONDED",
            block: receipt.blockNumber.toString(),
            hash,
            detail: "Swap executed with no bond",
          });
        }
      } catch {
        // Decoding failed; the swap still happened. Say so, and keep recovering.
        setOutcome(undefined);
      }

      onSwapConfirmed();
    } catch (error) {
      setFlow("error");
      setSwapError(describeError(error));
    }
  }

  const observationBlocks = protocol.observationBlocks ?? 10n;
  const pickable = [token0, token1].filter((item): item is TokenMeta => Boolean(item));
  const boundLabel = kind === "exactInput" ? "Minimum received" : "Maximum input";
  const boundValue =
    limits?.kind === "exactInput" && receiveToken
      ? `${formatAmount(limits.amountOutMinimum, receiveToken.decimals, 6)} ${receiveToken.symbol}`
      : limits?.kind === "exactOutput" && payToken
        ? `${formatAmount(limits.amountInMaximum, payToken.decimals, 6)} ${payToken.symbol}`
        : "—";

  return (
    <div className="page">
      <span className="eyebrow">Refundable collateral</span>
      <h1 className="page-title">Swap normally. Bond automatically.</h1>
      <p className="page-sub">
        Temporary collateral for high-impact swaps. Settles after {observationBlocks.toString()} blocks.
      </p>

      <section className="swap-card">
        <div className="swap-head">
          <h2>Swap</h2>
          <div className="segmented" role="group" aria-label="Swap kind">
            <button
              type="button"
              className={kind === "exactInput" ? "active" : undefined}
              onClick={() => setKind("exactInput")}
            >
              Exact Input
            </button>
            <button
              type="button"
              className={kind === "exactOutput" ? "active" : undefined}
              onClick={() => setKind("exactOutput")}
            >
              Exact Output
            </button>
          </div>
        </div>

        <div className="token-box">
          <div className="token-box-label">
            <span>{kind === "exactInput" ? "Pay" : "Pay at most"}</span>
            <span>
              {payToken && balance !== undefined ? `Balance ${formatAmount(balance, payToken.decimals, 4)}` : ""}
            </span>
          </div>
          <div className="token-row">
            {kind === "exactInput" ? (
              <input
                className="amount"
                aria-label="Amount to pay"
                value={amountText}
                onChange={(event) => setAmountText(event.target.value)}
                inputMode="decimal"
                placeholder="0"
              />
            ) : (
              <span className={`amount readonly${limits ? "" : " dim"}`} aria-live="polite">
                {limits?.kind === "exactOutput" && payToken
                  ? formatAmount(limits.amountInMaximum, payToken.decimals, 6)
                  : "0"}
              </span>
            )}
            <TokenPill token={payToken} options={pickable} onPick={(s) => setPayIsCurrency0(s === token0?.symbol)} />
          </div>
        </div>

        <button
          type="button"
          className="switch-btn"
          aria-label="Switch direction"
          onClick={() => setPayIsCurrency0((value) => !value)}
        >
          ↓
        </button>

        <div className="token-box">
          <div className="token-box-label">
            <span>{kind === "exactInput" ? "Receive" : "Receive exactly"}</span>
            <span>{quotePhase === "refreshing" ? "Refreshing…" : ""}</span>
          </div>
          <div className="token-row">
            {kind === "exactOutput" ? (
              <input
                className="amount"
                aria-label="Amount to receive"
                value={amountText}
                onChange={(event) => setAmountText(event.target.value)}
                inputMode="decimal"
                placeholder="0"
              />
            ) : (
              <span className={`amount readonly${quoteReady ? "" : " dim"}`} aria-live="polite">
                {quoteReady && receiveToken ? formatAmount(quoteValue, receiveToken.decimals, 6) : "0"}
              </span>
            )}
            <TokenPill
              token={receiveToken}
              options={pickable}
              onPick={(s) => setPayIsCurrency0(s !== token0?.symbol)}
            />
          </div>
        </div>

        <div className="detail-list">
          <div className="detail-row">
            <span>{boundLabel}</span>
            <strong>{boundValue}</strong>
          </div>
          <div className="detail-row">
            <span>Pool fee</span>
            <strong>{(deployment.fee / 10_000).toFixed(2)}%</strong>
          </div>
          <div className="detail-row">
            <span>Maturity</span>
            <strong>{observationBlocks.toString()} blocks</strong>
          </div>
        </div>

        <div className="collateral-note">
          Collateral determined at execution. <strong>Maximum protocol collateral: 1%.</strong>
        </div>

        {needsWalletSetup && (
          <>
            <div className="setup-line">
              <span>Wallet setup required.</span>
            </div>
            <button type="button" className="cta-ghost" disabled={busy} onClick={() => void prepareWallet()}>
              {flow === "approving" ? "Preparing wallet…" : "Prepare wallet"}
            </button>
          </>
        )}

        <button
          type="button"
          className="cta"
          disabled={busy || (isConnected && networkCorrect && !canSubmit)}
          onClick={() => {
            if (!isConnected) onConnect();
            else if (!networkCorrect) switchChain({ chainId: deployment.chainId });
            else void submitSwap();
          }}
        >
          {ctaLabel({
            flow,
            isConnected,
            networkCorrect,
            networkName: deployment.networkName,
            canTrade: protocol.canTrade,
            hasAmount: specifiedAmount !== undefined && specifiedAmount > 0n,
            quotePhase,
            balanceCovers,
            spendingReady,
          })}
        </button>

        <StatusLine
          flow={flow}
          quotePhase={quotePhase}
          outcome={outcome}
          collateralToken={collateralToken}
          explorer={txHash ? explorerTx(deployment, txHash) : undefined}
          error={approvalError || swapError || amountProblem || limitProblem}
          onViewBonds={onViewBonds}
          onRetryQuote={() => void quoteRead.refetch()}
        />

        <details className="advanced">
          <summary>Advanced details</summary>
          <div className="detail-list">
            <div className="detail-row">
              <span>Slippage tolerance</span>
              <strong>
                <input
                  className="inline-input"
                  aria-label="Slippage tolerance in percent"
                  value={toleranceText}
                  onChange={(event) => setToleranceText(event.target.value)}
                  inputMode="decimal"
                />
                %
              </strong>
            </div>
            <div className="detail-row">
              <span>Collateral currency</span>
              <strong>{collateralToken?.symbol ?? "—"}</strong>
            </div>
            <div className="detail-row">
              <span>Pool</span>
              <strong>{deployment.poolId.slice(0, 14)}…</strong>
            </div>
            {submitted?.gasLimit !== undefined && (
              <div className="detail-row">
                <span>Gas limit signed</span>
                <strong>{submitted.gasLimit.toString()}</strong>
              </div>
            )}
            {submitted && (
              <div className="detail-row">
                <span>hookData</span>
                <strong>{submitted.hookData}</strong>
              </div>
            )}
          </div>
        </details>
      </section>
    </div>
  );
}

/** Compact inline status. Never a separate full-width card per stage. */
function StatusLine({
  flow,
  quotePhase,
  outcome,
  collateralToken,
  explorer,
  error,
  onViewBonds,
  onRetryQuote,
}: {
  flow: FlowState;
  quotePhase: QuotePhase;
  outcome?: { kind: "bonded"; collateral?: bigint } | { kind: "unbonded" };
  collateralToken?: TokenMeta;
  explorer?: string;
  error?: string;
  onViewBonds: () => void;
  onRetryQuote: () => void;
}) {
  if (flow === "approving") {
    return (
      <div className="status-line">
        <span className="spinner" /> Preparing wallet…
      </div>
    );
  }

  if (flow === "sending") {
    return (
      <div className="status-line">
        <span className="spinner" /> Swapping…
      </div>
    );
  }

  if (flow === "success") {
    const bonded = outcome?.kind === "bonded";
    const held =
      bonded && outcome.collateral !== undefined && collateralToken
        ? ` · ${formatAmount(outcome.collateral, collateralToken.decimals, 6)} ${collateralToken.symbol} held`
        : "";
    return (
      <div className="status-line ok">
        {bonded
          ? `Bond created ✓${held}`
          : outcome
            ? "Swap confirmed ✓ · no bond"
            : "Swap confirmed. Recovering bond details…"}
        {explorer && (
          <a href={explorer} target="_blank" rel="noreferrer">
            View ↗
          </a>
        )}
        {bonded && (
          <button type="button" className="link-btn" onClick={onViewBonds}>
            Bonds →
          </button>
        )}
      </div>
    );
  }

  if (flow === "error" && error) return <div className="status-line bad">{error}</div>;
  if (error) return <div className="status-line warn">{error}</div>;

  if (quotePhase === "loading") {
    return (
      <div className="status-line">
        <span className="spinner" /> Getting quote…
      </div>
    );
  }
  if (quotePhase === "refreshing") {
    return (
      <div className="status-line">
        <span className="spinner" /> Refreshing quote…
      </div>
    );
  }
  if (quotePhase === "empty") return <div className="status-line warn">No liquidity for that size.</div>;
  if (quotePhase === "failed") {
    return (
      <div className="status-line bad">
        Unable to fetch quote.
        <button type="button" className="link-btn" onClick={onRetryQuote}>
          Retry
        </button>
      </div>
    );
  }

  return <div className="status-line" />;
}

function TokenPill({
  token,
  options,
  onPick,
}: {
  token?: TokenMeta;
  options: TokenMeta[];
  onPick: (symbol: string) => void;
}) {
  if (!token) return <span className="token-pill">—</span>;
  return (
    <span className="token-pill">
      <span className="token-mark">{token.symbol.slice(0, 1)}</span>
      {token.symbol}
      <select aria-label="Token" value={token.symbol} onChange={(event) => onPick(event.target.value)}>
        {options.map((option) => (
          <option key={option.symbol} value={option.symbol}>
            {option.symbol}
          </option>
        ))}
      </select>
    </span>
  );
}

function readQuote(data: unknown): bigint | undefined {
  if (Array.isArray(data) && typeof data[0] === "bigint") return data[0];
  return undefined;
}

/** "1.50" -> 150n basis points. Rejects anything finer than a basis point. */
export function parseToleranceBps(text: string): bigint | undefined {
  const normalized = text.trim();
  if (!/^\d*(\.\d{0,2})?$/.test(normalized) || normalized === "" || normalized === ".") return undefined;
  const [whole, fraction = ""] = normalized.split(".");
  const bps = BigInt(whole || "0") * 100n + BigInt(fraction.padEnd(2, "0") || "0");
  return bps <= 10_000n ? bps : undefined;
}

function ctaLabel({
  flow,
  isConnected,
  networkCorrect,
  networkName,
  canTrade,
  hasAmount,
  quotePhase,
  balanceCovers,
  spendingReady,
}: {
  flow: FlowState;
  isConnected: boolean;
  networkCorrect: boolean;
  networkName: string;
  canTrade: boolean;
  hasAmount: boolean;
  quotePhase: QuotePhase;
  balanceCovers: boolean;
  spendingReady: boolean;
}) {
  if (flow === "sending") return "Swapping…";
  if (flow === "success") return "Swap confirmed ✓";
  if (flow === "approving") return "Preparing wallet…";
  if (!canTrade) return "Unavailable";
  if (!isConnected) return "Connect wallet";
  if (!networkCorrect) return `Switch to ${networkName}`;
  if (!hasAmount) return "Enter an amount";
  if (quotePhase === "loading") return "Getting quote…";
  if (quotePhase === "empty" || quotePhase === "failed") return "Quote unavailable";
  if (!balanceCovers) return "Insufficient balance";
  if (!spendingReady) return "Prepare wallet first";
  return "Swap";
}
