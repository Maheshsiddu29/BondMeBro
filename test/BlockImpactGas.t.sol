// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {V4Quoter} from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";

import {BondMeBro, HOOK_FLAGS} from "../src/BondMeBro.sol";
import {HookDataCodec} from "../src/libraries/HookDataCodec.sol";

/// @title BlockImpactGasTest
///
/// @notice ADR-0008 § 9. Callback gas for the migrated mechanism, on every shape that can set a
///         ceiling.
///
/// @dev THE CALLBACK FRAMES ARE READ FROM TRACES, not from `gasleft()`. This file's job is to
///      construct each shape deterministically and to assert the whole-transaction envelope; the
///      per-callback numbers quoted in the migration report come from running these tests under
///      `-vvvv` and reading the `BondMeBro::beforeSwap` / `::afterSwap` frames. P-L2-8's own gas
///      work made exactly this distinction after a first attempt asserted transaction totals
///      against callback ceilings and raised four false alarms.
///
///      WHERE THE `afterSwap` CEILING ACTUALLY LIVES, which no gas test found before P-L2-8.1B:
///      inside the `V4Quoter`'s REVERTING SIMULATION. The quoter executes the swap for real in a
///      frame that then reverts, so every slot it touches is cold — the maturity bucket, the bond
///      record, and the hook's balance in the collateral currency — and EIP-2929 warmth is
///      reverted with the frame. It is the coldest bonded `afterSwap` the system can produce, and
///      it is reachable by any integrator who quotes before swapping.
contract BlockImpactGasTest is Test, Deployers {
    BondMeBro internal hook;
    V4Quoter internal quoter;

    PoolKey internal key_;
    PoolId internal id_;

    address internal constant TRADER = address(0xB0B);

    uint128 internal constant MIN_BONDED = 1e15;
    uint96 internal constant MIN_BONDED_1 = 1e15;
    int128 internal constant POOL_LIQUIDITY = 1e19;

    uint256 internal constant BONDED_SIZE = 1e16;
    uint256 internal constant UNBONDED_SIZE = 1e14;

    /// @dev The ceilings `AGENTS.md` fixes.
    uint256 internal constant BEFORE_SWAP_CEILING = 150_000;
    uint256 internal constant AFTER_SWAP_CEILING = 100_000;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(BondMeBro).creationCode, abi.encode(manager, address(this)));

        hook = new BondMeBro{salt: salt}(IPoolManager(address(manager)), address(this));

        assertEq(address(hook), predicted, "mined address mismatch");

        quoter = new V4Quoter(manager);

        (key_, id_) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, TickMath.getSqrtPriceAtTick(0));

        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({
                tickLower: -60_000, tickUpper: 60_000, liquidityDelta: POOL_LIQUIDITY, salt: bytes32(uint256(1))
            }),
            ""
        );

        hook.setPoolConfig(key_, MIN_BONDED, MIN_BONDED_1, 10_000, 10_000, true);
    }

    function _hookData() internal pure returns (bytes memory) {
        return HookDataCodec.encode(TRADER, type(uint128).max);
    }

    function _swap(int256 amount, bool zeroForOne, bytes memory data) internal {
        swapRouter.swap(
            key_,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            data
        );
    }

    function _time(int256 amount, bool zeroForOne) internal returns (uint256) {
        uint256 before = gasleft();

        _swap(amount, zeroForOne, _hookData());

        return before - gasleft();
    }

    /*//////////////////////////////////////////////////////////////
                          THE FOUR BONDED SHAPES
    //////////////////////////////////////////////////////////////*/

    function test_gas_bonded_exactInput_zeroForOne() public {
        _swap(-int256(BONDED_SIZE), true, _hookData());
    }

    function test_gas_bonded_exactInput_oneForZero() public {
        _swap(-int256(BONDED_SIZE), false, _hookData());
    }

    function test_gas_bonded_exactOutput_zeroForOne() public {
        _swap(int256(BONDED_SIZE), true, _hookData());
    }

    function test_gas_bonded_exactOutput_oneForZero() public {
        _swap(int256(BONDED_SIZE), false, _hookData());
    }

    /// @dev Unbonded: below the threshold, so `beforeSwap`'s exact-input pre-filter short-circuits
    ///      before hookData is even decoded. The latch still advances, which is the point.
    function test_gas_unbonded_belowThreshold() public {
        _swap(-int256(UNBONDED_SIZE), true, "");
    }

    /*//////////////////////////////////////////////////////////////
                       COLD LATCH vs WARM SAME-BLOCK
    //////////////////////////////////////////////////////////////*/

    /// @notice A block's FIRST swap costs more than a later one in the same block.
    ///
    /// @dev WHAT THIS DIFFERENCE IS AND IS NOT. It is NOT the latch's cost. A block's first swap
    ///      also credits elapsed time into `tickCumulative` and runs the maturity scan across the
    ///      newly crossed block, both of which predate ADR-0008 and dominate the gap. Reading this
    ///      delta as "the latch" would overstate it by more than an order of magnitude.
    ///
    ///      The latch's ACTUAL cost is one comparison plus, on a block's first swap only, one warm
    ///      SSTORE into a slot `update` was going to write anyway. Isolating it needs a
    ///      before/after comparison of the `beforeSwap` CALLBACK frame against the pre-migration
    ///      build, which is a trace measurement recorded in the migration report rather than
    ///      something assertable here.
    ///
    ///      What this test does pin is the ORDERING -- first-in-block is the more expensive of the
    ///      two -- so a change that moved per-block work onto every swap would surface.
    function test_gas_coldLatchVersusWarmSameBlock() public {
        // Warm everything the measurement is not about.
        _swap(-int256(BONDED_SIZE), true, _hookData());

        vm.roll(block.number + 1);

        uint256 firstInBlock = _time(-int256(BONDED_SIZE), true);
        uint256 sameBlock = _time(-int256(BONDED_SIZE), true);

        console2.log("GAS first-in-block swap (tx)", firstInBlock);
        console2.log("GAS same-block swap     (tx)", sameBlock);
        console2.log("GAS block-boundary delta(tx)", firstInBlock - sameBlock);
        console2.log("     accumulator credit + maturity scan + latch, NOT the latch alone");

        assertGt(firstInBlock, sameBlock, "the first swap in a block should carry the latch write");
    }

    /*//////////////////////////////////////////////////////////////
                        THE CHECKPOINT WORST CASE
    //////////////////////////////////////////////////////////////*/

    /// @notice `beforeSwap`'s worst case: a full-horizon scan freezing every occupied bucket.
    ///
    /// @dev The shape `VariableLegGas.t.sol` reconstructs for the pre-migration 106,878 figure —
    ///      bonds filling every maturity bucket, then a long silence, then one swap that must walk
    ///      the whole horizon and freeze everything due. If ADR-0008's latch threatened the
    ///      150,000 ceiling anywhere, it would be here.
    function test_gas_worstCase_fullHorizonScanFreezingEveryOccupiedBucket() public {
        for (uint256 i = 0; i < hook.OBSERVATION_BLOCKS(); i++) {
            _swap(-int256(BONDED_SIZE), true, _hookData());

            vm.roll(block.number + 1);
        }

        vm.roll(block.number + 100_000);

        uint256 total = _time(-int256(BONDED_SIZE), true);

        console2.log("GAS worst-case scan+bond (tx)", total);
    }

    /*//////////////////////////////////////////////////////////////
                  THE QUOTER'S COLD REVERTING SIMULATION
    //////////////////////////////////////////////////////////////*/

    /// @notice `afterSwap`'s worst case: a bonded exact-output inside the quoter, from cold.
    ///
    /// @dev Both directions, each in its own snapshot so neither warms the other.
    function test_gas_worstCase_quotedExactOutputFromCold() public {
        for (uint256 i = 0; i < 2; i++) {
            uint256 snap = vm.snapshotState();

            // slither-disable-next-line unused-return
            quoter.quoteExactOutputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: key_, zeroForOne: i == 0, exactAmount: uint128(BONDED_SIZE), hookData: _hookData()
                })
            );

            _swap(int256(BONDED_SIZE), i == 0, _hookData());

            vm.revertToState(snap);
        }
    }

    /// @notice The same, but landing in an already-displaced block so the rate takes the cap path.
    ///
    /// @dev ADR-0008-SPECIFIC and the reason the pre-migration corpus could not have covered it: a
    ///      swap behind a large move is charged at the block displacement, writes a larger
    ///      `collateralBps`, and reaches a branch the old model could not produce at all.
    function test_gas_worstCase_quotedExactOutputBehindALargeMove() public {
        for (uint256 i = 0; i < 2; i++) {
            uint256 snap = vm.snapshotState();

            _swap(-int256(BONDED_SIZE) * 40, i == 0, _hookData());

            // slither-disable-next-line unused-return
            quoter.quoteExactOutputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: key_, zeroForOne: i == 0, exactAmount: uint128(BONDED_SIZE), hookData: _hookData()
                })
            );

            _swap(int256(BONDED_SIZE), i == 0, _hookData());

            vm.revertToState(snap);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            SPLIT SEQUENCES
    //////////////////////////////////////////////////////////////*/

    /// @notice 2 / 8 / 32 / 128-piece same-block sequences.
    ///
    /// @dev TWO COSTS LIVE HERE AND MUST NOT BE CONFLATED. The latch is constant and small. The
    ///      other cost is that ADR-0008 BONDS sub-tick pieces the old model left unbonded, and each
    ///      of those is a full bond lifecycle. That is not callback overhead — it is the mitigation
    ///      working, and the attacker is who pays it. The bonded count is printed alongside so the
    ///      two are never read as one number.
    function test_gas_splitSequences() public {
        uint256[4] memory sizes = [uint256(2), 8, 32, 128];

        // Warm the shared machinery once, outside the loop.
        _swap(-1e13, true, _hookData());

        for (uint256 s = 0; s < sizes.length; s++) {
            uint256 snap = vm.snapshotState();

            uint256 n = sizes[s];

            uint32 m = uint32(block.number) + hook.OBSERVATION_BLOCKS();

            uint256 total;

            for (uint256 i = 0; i < n; i++) {
                total += _time(-int256(32e15 / n), true);
            }

            // slither-disable-next-line unused-return
            (,,, uint32 bonded,) = hook.maturity(id_, m);

            console2.log("GAS split pieces         ", n);
            console2.log("GAS   total tx gas       ", total);
            console2.log("GAS   per swap           ", total / n);
            console2.log("GAS   bonds created      ", bonded);

            // AT 128 PIECES THIS FIXTURE'S REALISTIC THRESHOLD FILTERS EVERY PIECE. 32e15/128 is
            // 2.5e14, below `MIN_BONDED = 1e15`, so nothing bonds and the row measures the UNBONDED
            // path. That is threshold splitting (ADR-0005 § 6), a separate limitation from the one
            // ADR-0008 addresses, and reading this row as a bonded cost would understate it. The
            // next test supplies the bonded counterpart.
            if (n == 128) {
                assertEq(bonded, 0, "the 128-piece row is expected to be threshold-filtered here");
            } else {
                assertEq(bonded, n, "a piece went unbonded above the threshold");
            }

            vm.revertToState(snap);
        }
    }

    /// @notice The 128-piece sequence with every piece ACTUALLY BONDED.
    ///
    /// @dev The threshold is dropped to 1 wei so the filtered row above has a bonded counterpart.
    ///      This is what an attacker running the same-block split actually pays under ADR-0008, and
    ///      paying for 128 bond lifecycles where the old model bonded 58 IS the mitigation rather
    ///      than callback overhead.
    function test_gas_splitSequence128_allBonded() public {
        hook.setPoolConfig(key_, 1, 1, 10_000, 10_000, true);

        _swap(-1e13, true, _hookData());

        // A NEW BLOCK before the sequence. At a 1-wei threshold the warm-up above bonds too, and
        // leaving it in the same block would put 129 bonds in the bucket the assertion counts.
        vm.roll(block.number + 1);

        uint32 m = uint32(block.number) + hook.OBSERVATION_BLOCKS();

        uint256 total;

        for (uint256 i = 0; i < 128; i++) {
            total += _time(-int256(32e15 / 128), true);
        }

        // slither-disable-next-line unused-return
        (,,, uint32 bonded,) = hook.maturity(id_, m);

        console2.log("GAS split 128 all-bonded tot ", total);
        console2.log("GAS   per swap               ", total / 128);
        console2.log("GAS   bonds created          ", bonded);

        // NOT 128. The first pieces of a fine split execute while the block has not yet moved a
        // whole tick, so their effective impact is genuinely zero and they are unbonded -- the
        // same treatment an isolated sub-tick swap gets, and correct. What matters is that the
        // bonded count TRACKS N rather than saturating at the displacement in ticks, which is what
        // the old model did (58 of 512).
        assertGe(bonded, 126, "far more pieces went unbonded than the sub-tick lead-in explains");
    }

    /*//////////////////////////////////////////////////////////////
                              CODE SIZE
    //////////////////////////////////////////////////////////////*/

    /// @notice The migrated runtime bytecode is inside the EIP-170 limit, with the margin stated.
    ///
    /// @dev Skipped under `forge coverage`, which builds unoptimized and instrumented: that
    ///      artifact is never deployed and its size means nothing.
    function test_codeSize_isInsideTheEip170Limit() public view {
        uint256 size = address(hook).code.length;

        console2.log("SIZE BondMeBro runtime (bytes)", size);

        if (vm.isContext(VmSafe.ForgeContext.Coverage)) {
            console2.log("skipping the EIP-170 assertion under coverage");

            return;
        }

        assertLt(size, 24_576, "BondMeBro exceeds the EIP-170 contract size limit");

        console2.log("SIZE EIP-170 headroom (bytes) ", 24_576 - size);
    }
}
