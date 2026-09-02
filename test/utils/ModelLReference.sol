// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

/// @title ModelLReference
///
/// @notice An INDEPENDENT reference implementation of the Model L2 collateral rate and the
///         variable-leg custody rule, for use by tests.
///
/// @dev WHY THIS EXISTS, AND WHY IT IS NOT A WRAPPER.
///
///      `docs/INVARIANTS-L2.md` opens with the rule that governs this whole file: *"A checkpoint
///      invariant that compares the hook against its own accumulator proves nothing. Every 'exact'
///      claim must be checked against a reference the test builds itself."* The same reasoning
///      applies to collateral sizing. A test that asserts
///
///          takenBond == hook.collateralAmountOf(bondId)
///
///      asserts only that the hook agrees with itself, and would pass unchanged if the entire
///      Model L rate were wrong. So the rate is re-derived here from the SPECIFICATION
///      (ADR-0005 section 2.2) rather than copied from `src/BondMeBro.sol`, and the tests compare
///      the two.
///
///      Concretely, this file is written from the prose:
///
///          collateralBps = min(MAX, ceil(|tickAfter - tickBefore| * SCALE))
///          bond          = variableLegAmount * collateralBps / 10_000
///
///      with `SCALE = 0.25` expressed as `* 25 / 100` so the ceiling is exact in integers. If a
///      future edit to the hook changes the rate, this file must be updated from the ADR by hand
///      and the ADR changed first -- that friction is the point. Do NOT "fix" a failing test by
///      importing the hook's constants here; that would silently convert every assertion below
///      into a tautology.
///
///      CONSTANTS ARE RESTATED, NOT IMPORTED, for the same reason. They are pinned against the
///      hook's public constants in exactly one place (`test/ModelLReferenceAgreement.t.sol`), so a
///      divergence is reported once, loudly, as its own failure -- instead of being absorbed
///      invisibly into every test that uses this library.
library ModelLReference {
    /// @dev Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @dev The rate cap, in bps. ADR-0005 section 2.2: collateral never exceeds 1% of the
    ///      variable leg, however large the impact.
    uint256 internal constant MAX_BOND_BPS = 100;

    /// @dev SCALE = 0.25 bps of collateral per tick of impact, as a percentage numerator so the
    ///      ceiling division stays exact in integer arithmetic: `ticks * 25 / 100`.
    uint256 internal constant COLLATERAL_SCALE = 25;

    /// @dev The impact at which the cap first binds. `ceil(396 * 25 / 100) = 99`, and
    ///      `ceil(397 * 25 / 100) = 100`, so 397 is the first impact that reaches MAX_BOND_BPS.
    ///      Stated as a constant so the boundary tests cannot drift from the ADR by a tick.
    uint32 internal constant CAP_ACTIVATION_TICKS = 397;

    /// @notice The Model L collateral rate for a realized tick impact.
    ///
    /// @dev `ceil` is load-bearing and is written as `(x + 99) / 100` rather than a rounding
    ///      helper so the reader can check it against the ADR by eye. With `floor`, impacts of
    ///      1-3 ticks would produce a ZERO rate, so a swap that visibly moved the price would post
    ///      nothing at all.
    ///
    ///      The rate depends on the ABSOLUTE impact. A hook that charged more for one direction
    ///      than the other would be a directional tax, and INV-L2-2's direction-symmetry check
    ///      exists to catch exactly that.
    ///
    /// @param tickBefore Pool tick immediately before the swap.
    /// @param tickAfter Pool tick immediately after the swap.
    /// @return collateralBps The rate, in bps of the variable leg, never above `MAX_BOND_BPS`.
    function collateralBps(int24 tickBefore, int24 tickAfter) internal pure returns (uint256) {
        int256 diff = int256(tickAfter) - int256(tickBefore);

        uint256 impactTicks = uint256(diff < 0 ? -diff : diff);

        uint256 bps = (impactTicks * COLLATERAL_SCALE + 99) / 100;

        return bps > MAX_BOND_BPS ? MAX_BOND_BPS : bps;
    }

    /// @notice The collateral a bond of this variable leg and impact must post.
    ///
    /// @dev Truncating division, matching the hook. The direction matters: truncation means the
    ///      hook takes at most what the rate implies and never a wei more, so `bond <= leg` holds
    ///      trivially and INV-NOOP-VL's strict upper bound is never threatened by rounding.
    ///
    /// @param variableLegAmount The realized variable leg -- the output for an exact-input swap,
    ///        the pool input for an exact-output swap.
    /// @param tickBefore Pool tick immediately before the swap.
    /// @param tickAfter Pool tick immediately after the swap.
    function collateralFor(uint256 variableLegAmount, int24 tickBefore, int24 tickAfter)
        internal
        pure
        returns (uint256)
    {
        return (variableLegAmount * collateralBps(tickBefore, tickAfter)) / BPS;
    }

    /// @notice Which currency the collateral is taken in, as a `currency0` predicate.
    ///
    /// @dev The unified custody rule from ADR-0006, restated independently:
    ///
    ///        exact-input  : the INPUT is the fixed leg, so the collateral is the OUTPUT
    ///        exact-output : the OUTPUT is the fixed leg, so the collateral is the INPUT
    ///
    ///      Combined with direction, the four cases collapse to one expression. The mirror is
    ///      exact, which is worth stating because it is the property that makes a single custody
    ///      path possible at all:
    ///
    ///        exactInput  zeroForOne : in c0, out c1 -> collateral c1  -> !zeroForOne == false
    ///        exactInput  oneForZero : in c1, out c0 -> collateral c0  -> !zeroForOne == true
    ///        exactOutput zeroForOne : in c0, out c1 -> collateral c0  ->  zeroForOne == true
    ///        exactOutput oneForZero : in c1, out c0 -> collateral c1  ->  zeroForOne == false
    ///
    /// @param zeroForOne Swap direction.
    /// @param exactInput True when `amountSpecified < 0`.
    function collateralIsCurrency0(bool zeroForOne, bool exactInput) internal pure returns (bool) {
        return exactInput ? !zeroForOne : zeroForOne;
    }

    /// @notice The minimum impact, in ticks, that produces a non-zero rate.
    ///
    /// @dev One. `ceil(1 * 25 / 100) = 1`. Named because several tests need to state "this swap
    ///      moved the price, so it MUST have posted something" without re-deriving the ceiling.
    function minimumChargeableImpact() internal pure returns (uint32) {
        return 1;
    }
}
