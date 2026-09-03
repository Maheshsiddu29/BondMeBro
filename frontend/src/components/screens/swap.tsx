"use client";

import { useEffect, useMemo, useState } from "react";
import type { Address, Hex } from "viem";
import { usePublicClient, useReadContract, useSwitchChain, useWriteContract } from "wagmi";

import { bondMeBroAbi } from "@/lib/abi/bondMeBro";
import { erc20Abi, permit2Abi, universalRouterAbi, v4QuoterAbi } from "@/lib/abi/external";
import type { Activity } from "@/lib/activity";
import { interpretSwapReceipt, type BondOpenedEvent } from "@/lib/bond";
import { explorerTx, poolKeyOf, type Deployment } from "@/lib/deployment";
import { describeError, isLiquidityError } from "@/lib/errors";
import { formatAmount, formatBps, formatToken, parseUint128Amount, type TokenMeta } from "@/lib/format";
import {
  assertContext,
  assertReceiptSucceeded,
  type IntendedContext,
  type SubmittedSummary,
} from "@/lib/guards";
import { encodeHookData, EXACT_INPUT_MAX_BOND_AMOUNT } from "@/lib/hookData";
import {
  collateralBpsForImpact,
  collateralFromVariableLeg,
  effectiveImpactTicks,
  exactInputLimits,
  exactOutputLimits,
  LimitError,
  toleranceCoversCollateralCap,
} from "@/lib/limits";
import { bondEligibility, thresholdsFor, type SwapKind } from "@/lib/poolConfig";
import { buildExactInputPlan, buildExactOutputPlan, spendRequirement } from "@/lib/swapPlan";
import type { ProtocolState } from "@/lib/useProtocol";
import { StatusDot, TokenPicker } from "@/components/ui";

type FlowState = "idle" | "approving" | "sending" | "success" | "error";

const DEADLINE_SECONDS = 1_200;

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
  onBondDiscovered: (opened: BondOpenedEvent) => void;
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
  const [message, setMessage] = useState("");
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
    () =>
      poolConfig ? thresholdsFor({ config: poolConfig, deployment, kind, zeroForOne }) : undefined,
    [poolConfig, deployment, kind, zeroForOne],
  );
  const collateralToken = thresholds
    ? thresholds.collateralIsCurrency0
      ? token0
      : token1
    : undefined;

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
    query: { enabled: quoteEnabled, refetchInterval: 5_000 },
  });

  const quoteValue = quoteEnabled ? readQuote(quoteRead.data) : undefined;
  const quoteLoading = quoteEnabled && (quoteRead.isLoading || quoteRead.isFetching);
  const quoteFailed = quoteEnabled && quoteRead.isError;
  const noLiquidity = quoteFailed && isLiquidityError(quoteRead.error);
  const quoteReady = quoteEnabled && !quoteLoading && !quoteFailed && quoteValue !== undefined && quoteValue > 0n;

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
      return [undefined, error instanceof LimitError ? error.message : "Swap limits could not be prepared."] as const;
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
  const permit2Live = permit2Expiry > BigInt(Math.floor(Date.now() / 1000) + 60);

  const spendingReady = Boolean(
    spend && tokenAllowance >= spend.amount && permit2Amount >= spend.amount && permit2Live,
  );
  const balanceCovers = balance === undefined || (spend ? balance >= spend.amount : true);

  // Pre-trade collateral estimate. It uses quote-time pool state, and the rate depends on
  // ordering inside the block the transaction lands in, so it is only ever an estimate.
  const accumulatorRead = useReadContract({
    address: deployment.hook,
    abi: bondMeBroAbi,
    chainId: deployment.chainId,
    functionName: "accumulator",
    args: [deployment.poolId],
    query: { enabled: protocol.rpcOnline, refetchInterval: 10_000 },
  });
  const accumulator = accumulatorRead.data as readonly [number, number, number, bigint] | undefined;

  const estimate = useMemo(() => {
    if (!constants || !quoteReady || quoteValue === undefined || !accumulator) return undefined;
    // Without a simulation of this exact swap we cannot know tickAfter. Use the pool's
    // current displacement from the block start as the visible floor of the rate: it is
    // labelled an estimate and never presented as the amount that will be taken.
    const lastTick = BigInt(accumulator[0]);
    const blockStartTick = BigInt(accumulator[2]);
    const impact = effectiveImpactTicks({ tickBefore: lastTick, tickAfter: lastTick, blockStartTick });
    const bps = collateralBpsForImpact(impact, constants);
    // Exact input: the variable leg is the realized output, which the quote already reports
    // NET of collateral, so this is a lower bound. Exact output: the variable leg is the
    // pool input, which the quoted total already includes collateral in.
    const variableLeg = quoteValue;
    return { bps, amount: collateralFromVariableLeg(variableLeg, bps, constants) };
  }, [constants, quoteReady, quoteValue, accumulator]);

  const eligibility = useMemo(() => {
    if (!poolConfig || !thresholds) return undefined;
    return bondEligibility({
      config: poolConfig,
      thresholds,
      consumedInput: kind === "exactInput" ? specifiedAmount : undefined,
      variableLeg: kind === "exactInput" ? quoteValue : quoteValue,
    });
  }, [poolConfig, thresholds, kind, specifiedAmount, quoteValue]);

  useEffect(() => {
    // Any change to what is being traded invalidates a finished result: a success panel
    // must never describe a request the form no longer shows.
    setFlow("idle");
    setMessage("");
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

  function intended(): IntendedContext | undefined {
    if (!account || walletChainId === undefined) return undefined;
    return { address: account, chainId: walletChainId };
  }

  async function approveSpending() {
    const context = intended();
    if (!context || !publicClient || !payToken || !spend) return;
    setFlow("approving");
    setMessage("");
    try {
      // Re-verify before EVERY wallet request, including between the two approvals: the
      // user can switch account or network while the first receipt is being awaited.
      assertContext(context, { address: account, chainId: walletChainId });

      if (tokenAllowance < spend.amount) {
        const hash = await writeContractAsync({
          address: payToken.address,
          abi: erc20Abi,
          functionName: "approve",
          args: [deployment.permit2, spend.amount],
          account: context.address,
          chainId: context.chainId,
        });
        assertReceiptSucceeded(
          await publicClient.waitForTransactionReceipt({ hash }),
          `${payToken.symbol} approval`,
        );
      }

      assertContext(context, { address: account, chainId: walletChainId });

      if (permit2Amount < spend.amount || !permit2Live) {
        // A BOUNDED grant: exactly this swap's requirement, for one hour. The previous
        // build requested uint160 max for 30 days and called it "approve once".
        const expiration = Math.floor(Date.now() / 1000) + 3_600;
        const hash = await writeContractAsync({
          address: deployment.permit2,
          abi: permit2Abi,
          functionName: "approve",
          args: [payToken.address, deployment.universalRouter, spend.amount, expiration],
          account: context.address,
          chainId: context.chainId,
        });
        assertReceiptSucceeded(
          await publicClient.waitForTransactionReceipt({ hash }),
          "Permit2 approval",
        );
      }

      await Promise.all([tokenAllowanceRead.refetch(), permit2AllowanceRead.refetch()]);
      setFlow("idle");
    } catch (error) {
      setFlow("error");
      setMessage(describeError(error));
    }
  }

  async function submitSwap() {
    const context = intended();
    if (!canSubmit || !context || !publicClient || !payToken || !receiveToken || !limits || !spend) return;
    if (specifiedAmount === undefined) return;

    setFlow("sending");
    setMessage("");
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

      const hash = await writeContractAsync({
        address: deployment.universalRouter,
        abi: universalRouterAbi,
        functionName: "execute",
        args: [plan.commands, plan.inputs, BigInt(Math.floor(Date.now() / 1000) + DEADLINE_SECONDS)],
        account: context.address,
        chainId: context.chainId,
      });
      setTxHash(hash);

      const receipt = assertReceiptSucceeded(
        await publicClient.waitForTransactionReceipt({ hash }),
        "swap",
      );

      const result = interpretSwapReceipt({
        logs: receipt.logs,
        hookAddress: deployment.hook,
        poolId: deployment.poolId,
        refundRecipient: context.address,
      });

      if (result.kind === "bonded") {
        onBondDiscovered(result.opened);
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

      setFlow("success");
      onSwapConfirmed();
    } catch (error) {
      setFlow("error");
      setMessage(describeError(error));
    }
  }

  const status = swapStatus({
    isConnected,
    networkCorrect,
    canTrade: protocol.canTrade,
    rpcOnline: protocol.rpcOnline,
    metadataReady: Boolean(payToken && receiveToken),
    amountProblem,
    hasAmount: specifiedAmount !== undefined && specifiedAmount > 0n,
    quoteLoading,
    quoteFailed,
    noLiquidity,
    quoteReady,
    balanceCovers,
    spendingReady,
    flow,
  });

  const pickerOptions = [token0, token1]
    .filter((token): token is TokenMeta => Boolean(token))
    .map((token) => ({ symbol: token.symbol, icon: token.symbol.slice(0, 1) }));

  return (
    <div className="swap-screen-uniswap swap-screen-minimal">
      <section className="swap-layout swap-layout-uniswap swap-layout-solo">
        <article className="neo-card swap-card">
          <div className="swap-mode-switch" role="group" aria-label="Swap kind">
            <button
              type="button"
              className={kind === "exactInput" ? "outline-button swap-mode-active" : "outline-button"}
              onClick={() => setKind("exactInput")}
            >
              Exact input
            </button>
            <button
              type="button"
              className={kind === "exactOutput" ? "outline-button swap-mode-active" : "outline-button"}
              onClick={() => setKind("exactOutput")}
            >
              Exact output
            </button>
          </div>

          <div className="swap-token-panel swap-sell-panel">
            <div className="field-label uniswap-field-label">
              <span>{kind === "exactInput" ? "Sell exactly" : "Sell at most"}</span>
              <span>
                Balance {payToken ? formatToken(balance, payToken) : "—"}
              </span>
            </div>
            <div className="amount-line uniswap-amount-line">
              {kind === "exactInput" ? (
                <input
                  aria-label="Input amount"
                  value={amountText}
                  onChange={(event) => setAmountText(event.target.value)}
                  inputMode="decimal"
                  placeholder="0.00"
                />
              ) : (
                <strong className="quoted-output-value" aria-live="polite">
                  {limits?.kind === "exactOutput" && payToken
                    ? formatAmount(limits.amountInMaximum, payToken.decimals)
                    : quoteLoading
                      ? "…"
                      : "—"}
                </strong>
              )}
              {payToken && (
                <TokenPicker
                  label="Pay token"
                  token={{ symbol: payToken.symbol, icon: payToken.symbol.slice(0, 1) }}
                  options={pickerOptions}
                  onChange={(symbol) => setPayIsCurrency0(symbol === token0?.symbol)}
                />
              )}
            </div>
          </div>

          <button
            type="button"
            className="direction-button swap-direction-button"
            aria-label="Switch swap direction"
            onClick={() => setPayIsCurrency0((value) => !value)}
          >
            ↕
          </button>

          <div className="swap-token-panel swap-buy-panel">
            <div className="field-label uniswap-field-label">
              <span>{kind === "exactInput" ? "Buy at least" : "Buy exactly"}</span>
              <span>{quoteLoading ? "Quoting…" : kind === "exactInput" ? "Net of collateral" : "Exact"}</span>
            </div>
            <div className="amount-line uniswap-amount-line">
              {kind === "exactOutput" ? (
                <input
                  aria-label="Output amount"
                  value={amountText}
                  onChange={(event) => setAmountText(event.target.value)}
                  inputMode="decimal"
                  placeholder="0.00"
                />
              ) : (
                <strong className="quoted-output-value" aria-live="polite">
                  {quoteReady && receiveToken ? formatAmount(quoteValue, receiveToken.decimals) : quoteLoading ? "…" : "—"}
                </strong>
              )}
              {receiveToken && (
                <TokenPicker
                  label="Receive token"
                  token={{ symbol: receiveToken.symbol, icon: receiveToken.symbol.slice(0, 1) }}
                  options={pickerOptions}
                  onChange={(symbol) => setPayIsCurrency0(symbol !== token0?.symbol)}
                />
              )}
            </div>
            <div className="minimum-output-control">
              <div>
                <span>Slippage tolerance</span>
                <small>
                  {constants && toleranceBps !== undefined && toleranceCoversCollateralCap(toleranceBps, constants)
                    ? "covers the collateral cap"
                    : "below the 1% collateral cap"}
                </small>
              </div>
              <input
                aria-label="Slippage tolerance in percent"
                value={toleranceText}
                onChange={(event) => setToleranceText(event.target.value)}
                inputMode="decimal"
                placeholder="1.50"
              />
            </div>
          </div>

          <div className="swap-detail-list">
            {kind === "exactInput" && limits?.kind === "exactInput" && receiveToken && (
              <div>
                <span>Minimum received</span>
                <strong>{formatAmount(limits.amountOutMinimum, receiveToken.decimals)} {receiveToken.symbol}</strong>
              </div>
            )}
            {kind === "exactOutput" && limits?.kind === "exactOutput" && payToken && (
              <>
                <div>
                  <span>Quoted total input</span>
                  <strong>
                    {formatAmount(limits.quotedTotalInput, payToken.decimals)} {payToken.symbol}
                  </strong>
                </div>
                <div>
                  <span>Maximum total input</span>
                  <strong>{formatAmount(limits.amountInMaximum, payToken.decimals)} {payToken.symbol}</strong>
                </div>
                <div>
                  <span>Maximum refundable collateral</span>
                  <strong>
                    {limits.ceilingIsProvenUnbonded
                      ? "none — this trade cannot bond"
                      : `${formatAmount(limits.maxBondAmount, payToken.decimals)} ${payToken.symbol}`}
                  </strong>
                </div>
              </>
            )}
            {estimate && collateralToken && (
              <div>
                <span>Estimated collateral</span>
                <strong>
                  {formatAmount(estimate.amount, collateralToken.decimals)} {collateralToken.symbol}
                  {" · "}
                  {formatBps(estimate.bps)}
                </strong>
              </div>
            )}
            {collateralToken && (
              <div>
                <span>Collateral currency</span>
                <strong>{collateralToken.symbol}</strong>
              </div>
            )}
            {protocol.observationBlocks !== undefined && protocol.blockNumber !== undefined && (
              <div>
                <span>Estimated maturity</span>
                <strong>Block {(protocol.blockNumber + protocol.observationBlocks).toString()}</strong>
              </div>
            )}
          </div>

          <div className="risk-callout">
            <span>ⓘ</span>
            <p>
              {kind === "exactInput"
                ? "You choose how much input to swap. BondMeBro may temporarily withhold a small part of the output as refundable collateral."
                : "You choose the exact output. BondMeBro may temporarily require additional input as refundable collateral."}{" "}
              How much depends on how far this pool&apos;s price has already moved in the block your transaction lands
              in, which depends on transaction ordering and cannot be known in advance. It never exceeds 1% of the
              realized variable side. The figure above is an estimate, not a maximum.
            </p>
          </div>

          {!protocol.canTrade && (
            <div className="pair-warning">Configuration error: {protocol.configurationProblems[0]}</div>
          )}
          {protocol.tokenMetadataError && <div className="pair-warning">{protocol.tokenMetadataError}</div>}
          {!protocol.rpcOnline && <div className="pair-warning">RPC unavailable.</div>}
          {amountProblem && <div className="pair-warning">{amountProblem}</div>}
          {noLiquidity && <div className="pair-warning">This pool has no usable liquidity for that size.</div>}
          {limitProblem && quoteReady && <div className="pair-warning">{limitProblem}</div>}
          {quoteFailed && !noLiquidity && <div className="pair-warning">Quote unavailable.</div>}
          {eligibility && !eligibility.eligible && quoteReady && (
            <div className="pair-warning">{eligibility.reason} The swap itself is unaffected.</div>
          )}
          {spend && !spendingReady && isConnected && networkCorrect && payToken && (
            <div className="pair-warning">
              Approve {formatAmount(spend.amount, payToken.decimals)} {payToken.symbol} for this swap.
            </div>
          )}

          <div className={`swap-status swap-status-${status.tone}`}>
            <StatusDot live={status.tone === "ready" || status.tone === "success"} />
            <div>
              <strong>{status.title}</strong>
              <span>{status.detail}</span>
            </div>
          </div>

          {spend && !spendingReady && isConnected && networkCorrect && payToken && quoteReady && (
            <button
              type="button"
              className="outline-button full-button prepare-token-button"
              disabled={busy}
              onClick={() => void approveSpending()}
            >
              {flow === "approving"
                ? `Approving ${payToken.symbol}…`
                : `Approve ${formatAmount(spend.amount, payToken.decimals)} ${payToken.symbol}`}
            </button>
          )}
          {spend && !spendingReady && payToken && (
            <p className="approval-disclosure">
              Two approvals, both bounded to this swap: {payToken.symbol} to Permit2 for{" "}
              {formatAmount(spend.amount, payToken.decimals)} {payToken.symbol}, then Permit2 to the Universal Router at{" "}
              {deployment.universalRouter} for the same amount, expiring in one hour.
            </p>
          )}

          <button
            type="button"
            className="primary-button large-button full-button swap-submit-button"
            disabled={busy || (isConnected && networkCorrect && !canSubmit)}
            onClick={() => {
              if (!isConnected) onConnect();
              else if (!networkCorrect) switchChain({ chainId: deployment.chainId });
              else void submitSwap();
            }}
          >
            {submitLabel({
              flow,
              isConnected,
              networkCorrect,
              networkName: deployment.networkName,
              canTrade: protocol.canTrade,
              quoteReady,
              spendingReady,
              balanceCovers,
              kind,
            })}{" "}
            <span>→</span>
          </button>

          {flow === "error" && <div className="transaction-message transaction-error">{message}</div>}

          {submitted && (flow === "sending" || flow === "success") && (
            <div className="submitted-summary">
              <span className="eyebrow">SUBMITTED REQUEST</span>
              <div>
                <span>Kind</span>
                <strong>{submitted.kind === "exactInput" ? "Exact input" : "Exact output"}</strong>
              </div>
              <div>
                <span>Pay</span>
                <strong>{submitted.primaryAmount}</strong>
              </div>
              <div>
                <span>Receive</span>
                <strong>{submitted.secondaryAmount}</strong>
              </div>
              <div>
                <span>Refund recipient</span>
                <strong>{submitted.refundRecipient}</strong>
              </div>
              <div>
                <span>Collateral ceiling</span>
                <strong>{submitted.maxBondAmountLabel}</strong>
              </div>
            </div>
          )}

          {flow === "success" && txHash && (
            <div className="transaction-message transaction-success">
              {outcome?.kind === "bonded" ? (
                <>
                  Swap succeeded and opened a bond.
                  {outcome.collateral !== undefined && collateralToken && (
                    <> Actual collateral {formatAmount(outcome.collateral, collateralToken.decimals)} {collateralToken.symbol}.</>
                  )}{" "}
                  <a href={explorerTx(deployment, txHash)} target="_blank" rel="noreferrer">
                    View ↗
                  </a>
                  <button type="button" className="text-button success-next-button" onClick={onViewBonds}>
                    Track →
                  </button>
                </>
              ) : (
                <>
                  Unbonded swap. This trade executed in full and created no bond, which is a normal outcome.{" "}
                  <a href={explorerTx(deployment, txHash)} target="_blank" rel="noreferrer">
                    View ↗
                  </a>
                </>
              )}
            </div>
          )}
        </article>
      </section>
    </div>
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

function swapStatus({
  isConnected,
  networkCorrect,
  canTrade,
  rpcOnline,
  metadataReady,
  amountProblem,
  hasAmount,
  quoteLoading,
  quoteFailed,
  noLiquidity,
  quoteReady,
  balanceCovers,
  spendingReady,
  flow,
}: {
  isConnected: boolean;
  networkCorrect: boolean;
  canTrade: boolean;
  rpcOnline: boolean;
  metadataReady: boolean;
  amountProblem?: string;
  hasAmount: boolean;
  quoteLoading: boolean;
  quoteFailed: boolean;
  noLiquidity: boolean;
  quoteReady: boolean;
  balanceCovers: boolean;
  spendingReady: boolean;
  flow: FlowState;
}) {
  if (flow === "approving") return { tone: "pending", title: "Approving", detail: "Confirm the bounded approval." };
  if (flow === "sending") return { tone: "pending", title: "Confirming swap", detail: "Waiting for a successful receipt." };
  if (flow === "success") return { tone: "success", title: "Swap succeeded", detail: "Receipt confirmed and parsed." };
  if (flow === "error") return { tone: "error", title: "Swap not completed", detail: "Read the message and retry." };
  if (!canTrade) return { tone: "error", title: "Configuration error", detail: "Trading is disabled." };
  if (!isConnected) return { tone: "warning", title: "Connect your wallet", detail: "The wallet pays and receives." };
  if (!networkCorrect) return { tone: "warning", title: "Wrong network", detail: "Switch to the configured chain." };
  if (!rpcOnline) return { tone: "warning", title: "RPC unavailable", detail: "Reads are failing." };
  if (!metadataReady) return { tone: "pending", title: "Reading token metadata", detail: "Decimals and symbols." };
  if (amountProblem) return { tone: "warning", title: "Check the amount", detail: amountProblem };
  if (!hasAmount) return { tone: "warning", title: "Enter an amount", detail: "Nothing to quote yet." };
  if (quoteLoading) return { tone: "pending", title: "Getting a quote", detail: "Simulating against the pool." };
  if (noLiquidity) return { tone: "warning", title: "No liquidity", detail: "Try a smaller size." };
  if (quoteFailed) return { tone: "error", title: "Quote unavailable", detail: "The quoter reverted." };
  if (!quoteReady) return { tone: "pending", title: "Waiting for a quote", detail: "No usable quote yet." };
  if (!balanceCovers) return { tone: "warning", title: "Insufficient balance", detail: "The wallet cannot cover this." };
  if (!spendingReady) return { tone: "warning", title: "Approval needed", detail: "Approve the exact amount below." };
  return { tone: "ready", title: "Ready", detail: "One confirmation submits the swap." };
}

function submitLabel({
  flow,
  isConnected,
  networkCorrect,
  networkName,
  canTrade,
  quoteReady,
  spendingReady,
  balanceCovers,
  kind,
}: {
  flow: FlowState;
  isConnected: boolean;
  networkCorrect: boolean;
  networkName: string;
  canTrade: boolean;
  quoteReady: boolean;
  spendingReady: boolean;
  balanceCovers: boolean;
  kind: SwapKind;
}) {
  if (flow === "approving") return "Approving…";
  if (flow === "sending") return "Confirming…";
  if (flow === "success") return "Done";
  if (!canTrade) return "Trading disabled";
  if (!isConnected) return "Connect wallet";
  if (!networkCorrect) return `Switch to ${networkName}`;
  if (!quoteReady) return "Quote unavailable";
  if (!balanceCovers) return "Insufficient balance";
  if (!spendingReady) return "Approve first";
  return kind === "exactInput" ? "Swap exact input" : "Swap exact output";
}
