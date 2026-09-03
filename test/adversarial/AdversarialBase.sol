// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {BondMeBro, HOOK_FLAGS} from "../../src/BondMeBro.sol";
import {HookDataCodec} from "../../src/libraries/HookDataCodec.sol";

/// @title AdversarialBase
///
/// @notice Shared fixture for the P-L2-8 adversarial suites: a live pool, an independent per-block
///         tick reference, and helpers for driving and measuring attacks.
///
/// @dev THE REFERENCE IS BUILT FROM THE POOL, NEVER FROM THE HOOK. Every swap routed through
///      `_swapT` records `PoolManager.getSlot0`'s tick afterwards, so expected settlements can be
///      recomputed from the price path the pool actually followed. Asserting the hook against its
///      own accumulator would make every "exact" claim below circular.
///
///      DEPTH IS LOAD-BEARING. `POOL_LIQUIDITY = 1e19` puts a 1e16 swap at roughly 19 ticks of
///      impact -- clear of the `D = 5` dead zone, so the charged paths are actually reachable. On a
///      deeper pool every bonded swap would sit inside the dead zone and every attack below would
///      "pass" by charging nothing.
abstract contract AdversarialBase is Test, Deployers {
    using StateLibrary for IPoolManager;

    BondMeBro internal hook;

    PoolKey internal key_;
    PoolId internal id_;

    address internal constant TRADER = address(0xB0B);
    address internal constant ATTACKER = address(0xBAD);
    address internal constant BYSTANDER = address(0xCAFE);

    uint128 internal constant MIN_BONDED = 1e15;
    uint96 internal constant MIN_BONDED_1 = 1e15;

    uint128 internal constant GENEROUS_CEILING = type(uint128).max;

    int128 internal constant POOL_LIQUIDITY = 1e19;

    int256 internal constant BONDED = -1e16;
    int256 internal constant NUDGE = -1e13;

    /// @dev One observation of the pool: from `blockNumber` onward the effective tick is `tick`.
    struct RefPoint {
        uint32 blockNumber;
        int24 tick;
    }

    RefPoint[] internal refPoints;

    function _deployAndOpenPool() internal {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(BondMeBro).creationCode, abi.encode(manager, address(this)));

        hook = new BondMeBro{salt: salt}(IPoolManager(address(manager)), address(this));

        assertEq(address(hook), predicted, "mined address mismatch");

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

        refPoints.push(RefPoint({blockNumber: uint32(block.number), tick: _tick()}));
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _tick() internal view returns (int24 t) {
        // slither-disable-next-line unused-return
        (, t,,) = manager.getSlot0(id_);
    }

    function _hookData() internal pure returns (bytes memory) {
        return HookDataCodec.encode(TRADER, GENEROUS_CEILING);
    }

    /// @dev Swap and extend the independent reference.
    function _swapT(int256 amountSpecified, bool zeroForOne, bytes memory hookData) internal {
        swapRouter.swap(
            key_,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        refPoints.push(RefPoint({blockNumber: uint32(block.number), tick: _tick()}));
    }

    /// @dev Swap on an arbitrary key. Does NOT extend the reference, which tracks `key_` only.
    function _swapOn(PoolKey memory k, int256 amountSpecified, bool zeroForOne, bytes memory hookData) internal {
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    /// @dev The pool's effective tick across `[atBlock, atBlock+1)`, from the observed path.
    function _tickDuring(uint32 atBlock) internal view returns (int24) {
        for (uint256 i = refPoints.length; i > 0; i--) {
            if (refPoints[i - 1].blockNumber <= atBlock) return refPoints[i - 1].tick;
        }

        revert("reference does not cover a block before initialization");
    }

    /// @dev A bond's ten observation blocks, as `ModelL2Reference` wants them.
    function _observedPath(uint32 openBlock) internal view returns (int24[10] memory path) {
        for (uint256 k = 0; k < 10; k++) {
            path[k] = _tickDuring(openBlock + uint32(k));
        }
    }

    function _bondIdAt(uint32 maturityBlock, uint32 index) internal view returns (bytes32) {
        return keccak256(abi.encode(id_, maturityBlock, index));
    }

    function _maturityOfNow() internal view returns (uint32) {
        return uint32(block.number) + hook.OBSERVATION_BLOCKS();
    }

    /// @dev Opens one bonded swap; returns its id, opening block and maturity.
    function _open(int256 amount, bool zeroForOne)
        internal
        returns (bytes32 bondId, uint32 openBlock, uint32 maturityBlock)
    {
        openBlock = uint32(block.number);
        maturityBlock = openBlock + hook.OBSERVATION_BLOCKS();
        bondId = _bondIdAt(maturityBlock, 0);

        _swapT(amount, zeroForOne, _hookData());
    }

    /// @dev What a settlement actually moved.
    struct Settled {
        Currency currency;
        uint128 collateral;
        uint256 refund;
        uint256 slash;
    }

    function _settle(bytes32 bondId) internal returns (Settled memory out) {
        BondMeBro.Bond memory b = hook.getBond(bondId);

        out.currency = b.collateralIsCurrency0 ? currency0 : currency1;
        out.collateral = hook.collateralAmountOf(bondId);

        uint256 traderBefore = out.currency.balanceOf(b.refundRecipient);
        uint256 potBefore = hook.insurancePot(id_, out.currency);

        hook.settleBond(bondId);

        out.refund = out.currency.balanceOf(b.refundRecipient) - traderBefore;
        out.slash = hook.insurancePot(id_, out.currency) - potBefore;
    }

    /// @dev Rolls to `target` and runs one unbonded swap so the scheduler advances.
    function _nudgeAt(uint32 target) internal {
        vm.roll(target);

        _swapT(NUDGE, true, "");
    }
}
