// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {BondMeBro, HOOK_FLAGS} from "../../src/BondMeBro.sol";
import {HookDataCodec} from "../../src/libraries/HookDataCodec.sol";

/// @title ScaledPoolFixture
///
/// @notice A pool whose two tokens can have DIFFERENT decimals, and whose starting price can be
///         set far from parity.
///
/// @dev WHY THIS EXISTS. Every other fixture in this suite pairs two 18-decimal tokens at tick 0.
///      In that shape an exact-input swap's input and output are numerically similar, so a
///      threshold expressed in input units happens to bound the output as well. That coincidence
///      hid a real availability bug: the two quantities are in different currencies, and on a pool
///      whose tokens differ in decimals or unit value they can be many orders of magnitude apart.
///
///      Tests that care about raw-unit sizes should build on this fixture, not on the parity one.
abstract contract ScaledPoolFixture is Test, Deployers {
    using StateLibrary for IPoolManager;

    BondMeBro internal hook;

    PoolKey internal key_;
    PoolId internal id_;

    Currency internal c0;
    Currency internal c1;

    uint8 internal dec0;
    uint8 internal dec1;

    address internal constant TRADER = address(0xB0B);

    /// @dev Deploys the hook and a pool whose currency0/currency1 carry `decA`/`decB` decimals in
    ///      ADDRESS ORDER, priced at `startTick`, with `liquidity` spread across a wide range.
    ///
    ///      Token order in Uniswap is by address, which is not something a test can choose. So the
    ///      caller says which decimals it wants on the LOW-address token and which on the high one,
    ///      and the loop below mines addresses until the sort order matches. That keeps
    ///      "18 decimals as currency0" and "18 decimals as currency1" both reachable, which matters
    ///      because the swap direction decides which side is the variable leg.
    function _deployScaledPool(uint8 decForCurrency0, uint8 decForCurrency1, int24 startTick, int128 liquidity)
        internal
    {
        deployFreshManagerAndRouters();

        MockERC20 lo;
        MockERC20 hi;

        for (uint256 salt = 0; salt < 200; salt++) {
            MockERC20 a = new MockERC20("A", "A", decForCurrency0);
            MockERC20 b = new MockERC20("B", "B", decForCurrency1);

            if (address(a) < address(b)) {
                (lo, hi) = (a, b);
                break;
            }
        }

        require(address(lo) != address(0), "could not order the two tokens as requested");

        c0 = Currency.wrap(address(lo));
        c1 = Currency.wrap(address(hi));

        dec0 = decForCurrency0;
        dec1 = decForCurrency1;

        lo.mint(address(this), type(uint128).max);
        hi.mint(address(this), type(uint128).max);

        lo.approve(address(swapRouter), type(uint256).max);
        hi.approve(address(swapRouter), type(uint256).max);
        lo.approve(address(modifyLiquidityRouter), type(uint256).max);
        hi.approve(address(modifyLiquidityRouter), type(uint256).max);

        (address predicted, bytes32 salt2) =
            HookMiner.find(address(this), HOOK_FLAGS, type(BondMeBro).creationCode, abi.encode(manager, address(this)));

        hook = new BondMeBro{salt: salt2}(IPoolManager(address(manager)), address(this));

        assertEq(address(hook), predicted, "mined address mismatch");

        key_ = PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(hook))});
        id_ = key_.toId();

        manager.initialize(key_, TickMath.getSqrtPriceAtTick(startTick));

        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({
                tickLower: -600_000, tickUpper: 600_000, liquidityDelta: liquidity, salt: bytes32(0)
            }),
            ""
        );
    }

    function _hookData() internal pure returns (bytes memory) {
        return HookDataCodec.encode(TRADER, type(uint128).max);
    }

    function _tick() internal view returns (int24 t) {
        // slither-disable-next-line unused-return
        (, t,,) = manager.getSlot0(id_);
    }

    function _swap(int256 amountSpecified, bool zeroForOne) internal {
        swapRouter.swap(
            key_,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            _hookData()
        );
    }

    /// @dev Swap through an external call so a revert can be caught instead of aborting the test.
    function externalSwap(int256 amountSpecified, bool zeroForOne) external {
        require(msg.sender == address(this), "self only");

        _swap(amountSpecified, zeroForOne);
    }

    function _swapReverts(int256 amountSpecified, bool zeroForOne) internal returns (bool) {
        try this.externalSwap(amountSpecified, zeroForOne) {
            return false;
        } catch {
            return true;
        }
    }

    /// @dev The realized variable leg a swap WOULD produce, measured with bonding out of the way.
    ///      Snapshots and restores, so the caller's pool state is untouched.
    function _measureVariableLeg(int256 amountSpecified, bool zeroForOne) internal returns (uint256 leg) {
        uint256 snap = vm.snapshotState();

        hook.setPoolConfig(key_, type(uint128).max, type(uint96).max, 10_000, 10_000, true);

        bool exactInput = amountSpecified < 0;

        // Exact input pays collateral from the OUTPUT; exact output pays it from the INPUT.
        Currency legCurrency = exactInput ? (zeroForOne ? c1 : c0) : (zeroForOne ? c0 : c1);

        uint256 before = legCurrency.balanceOf(address(this));

        _swap(amountSpecified, zeroForOne);

        leg = exactInput ? legCurrency.balanceOf(address(this)) - before : before - legCurrency.balanceOf(address(this));

        vm.revertToState(snap);
    }

    /// @dev The currency collateral is taken in, which depends on BOTH the direction and the kind.
    ///      Exact input pays out of what it receives; exact output pays out of what it consumes.
    function _collateralCurrency(bool zeroForOne, bool exactInput) internal view returns (Currency) {
        return exactInput ? (zeroForOne ? c1 : c0) : (zeroForOne ? c0 : c1);
    }

    function _hookHolds(bool zeroForOne, bool exactInput) internal view returns (uint256) {
        return _collateralCurrency(zeroForOne, exactInput).balanceOf(address(hook));
    }

    function _pendingNow() internal view returns (uint32 pending) {
        // slither-disable-next-line unused-return
        (,,, pending,) = hook.maturity(id_, uint32(block.number) + hook.OBSERVATION_BLOCKS());
    }

    function _nextBondId() internal view returns (bytes32) {
        uint32 m = uint32(block.number) + hook.OBSERVATION_BLOCKS();

        // slither-disable-next-line unused-return
        (,,, uint32 pending,) = hook.maturity(id_, m);

        return keccak256(abi.encode(id_, m, pending));
    }
}
