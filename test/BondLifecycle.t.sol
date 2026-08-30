// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {BondMeBro} from "../src/BondMeBro.sol";

interface ERC20Like {
    function balanceOf(address) external view returns (uint256);
}

/// @notice Phase 1 acceptance suite: the full bond lifecycle with the two settlement
///         triggers (Problem 2). Every test drives a real PoolManager, real swaps and real
///         token flows — no mocks of the mechanism under test.
///
///         Timeline conventions: the opening swap fires at block B; the arb (when present)
///         fires at B+2; observation = 10 blocks, so maturity is B+10.
contract BondLifecycleTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    BondMeBro internal hook;
    PoolKey internal key_;
    PoolId internal pid;

    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");

    uint160 internal constant FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    function config() internal pure returns (BondMeBro.Config memory) {
        return BondMeBro.Config({
            bondBps: 1000, // 10%
            minImpactTicks: 10,
            refundTolTicks: 5,
            observationBlocks: 10,
            maxAbsTickDelta: 1000,
            settlerFeeBps: 500, // 5% of the slash, to the piggyback owner or direct settler
            maxSettlesPerSwap: 4
        });
    }

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, type(BondMeBro).creationCode, abi.encode(manager, config()));
        hook = new BondMeBro{salt: salt}(IPoolManager(address(manager)), config());
        assertEq(address(hook), predicted);

        (key_,) = initPool(currency0, currency1, IHooks(address(hook)), 3000, TickMath.getSqrtPriceAtTick(0));
        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e18, salt: bytes32(0)}),
            ZERO_BYTES
        );
        pid = key_.toId();

        vm.roll(1000); // keep away from block 0 semantics everywhere
    }

    // ---------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------

    function token1() internal view returns (ERC20Like) {
        return ERC20Like(Currency.unwrap(currency1));
    }

    function token0() internal view returns (ERC20Like) {
        return ERC20Like(Currency.unwrap(currency0));
    }

    function _ownerData() internal view returns (bytes memory) {
        return abi.encode(address(this));
    }

    /// @dev One big zeroForOne swap from the test contract; posts a bond given the setup.
    function _bigSwapDown() internal returns (BalanceDelta) {
        return swapRouter.swap(
            key_,
            SwapParams({zeroForOne: true, amountSpecified: -1e16, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            _ownerData()
        );
    }

    function _bigSwapUp() internal returns (BalanceDelta) {
        return swapRouter.swap(
            key_,
            SwapParams({zeroForOne: false, amountSpecified: -1e16, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            _ownerData()
        );
    }

    function _tinySwap() internal {
        _tinySwap("");
    }

    function _tinySwap(bytes memory hookData) internal returns (BalanceDelta delta) {
        return swapRouter.swap(
            key_,
            SwapParams({zeroForOne: true, amountSpecified: -1e13, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    function _onlyBondId() internal view returns (bytes32 id) {
        (bytes32 head, bytes32 tail) = hook.queueBounds(pid);
        assertEq(head, tail, "expected exactly one bond");
        return head;
    }

    // ---------------------------------------------------------------
    // The two ending branches of the whole design
    // ---------------------------------------------------------------

    /// @notice ENDING 1 — the trade was noise. Arb reverts the move early and the reversion
    ///         holds for the rest of the window, so the TWA reads "mostly reverted" and the
    ///         trader gets most of the bond back. Not 100%: the revert becomes visible one
    ///         block after it happened, and honest residue is the documented price of a
    ///         manipulation-resistant reference.
    function test_revertedTrade_mostlyRefunded() public {
        uint256 owner1Before = token1().balanceOf(address(this));

        _bigSwapDown(); // B: tick pushed down, bond A posts in token1
        assertEq(hook.queueLength(pid), 1, "bond A not opened");
        uint256 bondA = token1().balanceOf(address(hook));
        assertGt(bondA, 0, "hook must hold bond A");

        vm.roll(block.number + 2);
        _bigSwapUp(); // B+2: arb — also bonded (bond B, in token0), tick back near 0

        vm.roll(block.number + 11); // B+13: both bonds well past their 10-block windows
        uint256 owner1AtSettle = token1().balanceOf(address(this));

        vm.prank(keeper);
        uint256 settled = hook.settleBonds(key_, 10);
        assertEq(settled, 2, "both bonds matured");

        uint256 refundA = token1().balanceOf(address(this)) - owner1AtSettle;
        assertGt(refundA, bondA / 2, "early-reverted trade must be mostly refunded");
        assertLt(refundA, bondA, "some honest residue: the revert is visible one block late");

        // exact relationships: fee = 5% of the slash, and the pot holds the remainder.
        uint256 slashA = bondA - refundA;
        uint256 feeA = (slashA * 500) / 10_000;
        assertEq(token1().balanceOf(keeper), feeA, "keeper fee must come out of the slash");
        assertEq(token1().balanceOf(address(hook)), slashA - feeA, "pot residue accounting");
        assertEq(hook.insurancePot(pid, currency1), slashA - feeA);

        // sanity: we spent the gross output net of bond at open, and got refundA back.
        assertLt(token1().balanceOf(address(this)), owner1Before, "opening a bond always costs output");
    }

    /// @notice ENDING 2 — the trade persisted. Nothing reverts during the window; the quiet
    ///         pool extrapolates the post-swap tick, the TWA equals tickAfter, persistence is
    ///         100%, and the whole bond pays LPs (minus the settler's cut of the slash).
    function test_persistedTrade_fullySlashed_permissionlessSettle() public {
        _bigSwapDown();
        bytes32 bondId = _onlyBondId();
        uint256 bondA = token1().balanceOf(address(hook));

        vm.roll(block.number + 11);
        uint256 owner1Before = token1().balanceOf(address(this));

        vm.prank(keeper);
        uint256 settled = hook.settleBonds(key_, 10);
        assertEq(settled, 1);

        // owner: nothing back. keeper: 5% of the slash. pot: the rest. hook holds exactly pot.
        assertEq(token1().balanceOf(address(this)), owner1Before, "full slash: no refund");
        assertEq(token1().balanceOf(keeper), (bondA * 500) / 10_000, "settler fee from slash only");
        assertEq(hook.insurancePot(pid, currency1), bondA - (bondA * 500) / 10_000);
        assertEq(token1().balanceOf(address(hook)), hook.insurancePot(pid, currency1));

        BondMeBro.Bond memory gone = hook.getBond(pid, bondId);
        assertEq(gone.amount, 0, "settled bond must be deleted");
        assertEq(hook.queueLength(pid), 0);
    }

    // ---------------------------------------------------------------
    // Problem 2 — who triggers settlement
    // ---------------------------------------------------------------

    /// @notice Piggyback path: nobody calls settleBonds. A later routine swap (one far too
    ///         small to be bonded itself) settles the matured bond as a side effect. Pool
    ///         activity IS the keeper. The swap's resolved owner receives the settler fee
    ///         from the slash, while the rest lands in the pot.
    function test_piggyback_laterSwapSettlesMaturedBond() public {
        _bigSwapDown();
        uint256 bondA = token1().balanceOf(address(hook));

        vm.roll(block.number + 11);
        assertEq(hook.queueLength(pid), 1, "bond must sit until triggered");

        uint256 ownerBefore = token1().balanceOf(address(this));
        BalanceDelta tinyDelta = _tinySwap(_ownerData()); // not bonded itself; it still drains the queue
        assertEq(hook.queueLength(pid), 0, "piggyback settlement did not fire");

        // The quiet window fully slashes bond A. The current swap's resolved owner receives
        // the configured 5% settler fee; only the remainder enters the LP pot.
        uint256 fee = (bondA * 500) / 10_000;
        assertEq(hook.insurancePot(pid, currency1), bondA - fee);
        assertEq(
            token1().balanceOf(address(this)) - ownerBefore,
            uint256(uint128(tinyDelta.amount1())) + fee,
            "piggyback reward must be paid from the slash"
        );
        assertEq(token1().balanceOf(keeper), 0);
    }

    /// @notice The piggyback budget caps how many bonds one swap settles, so no swapper is
    ///         forced to fund an unbounded cleanup. The queue drains across swaps.
    function test_piggyback_capPerSwapIsRespected() public {
        for (uint256 i = 0; i < 6; i++) {
            // alternate directions so every swap re-crosses the threshold
            if (i % 2 == 0) _bigSwapDown();
            else _bigSwapUp();
        }
        assertEq(hook.queueLength(pid), 6, "six bonds should be open");

        vm.roll(block.number + 11);

        _tinySwap();
        assertEq(hook.queueLength(pid), 2, "cap = 4: exactly four settle per swap");
        _tinySwap();
        assertEq(hook.queueLength(pid), 0, "next swap drains the rest");

        // Six full-slash quiet-window settlements. Piggyback fees are paid to the
        // triggering swap's resolved owner, so the hook balance equals pot accounting.
        uint256 potTotal = hook.insurancePot(pid, currency1) + hook.insurancePot(pid, currency0);
        assertGt(potTotal, 0);
        assertEq(
            token0().balanceOf(address(hook)) + token1().balanceOf(address(hook)),
            potTotal,
            "hook balance must equal pot accounting (no leaks, no double pays)"
        );
    }

    /// @notice Maturity gate: settling early must be a no-op, not a revert and not a loss.
    function test_settle_beforeMaturity_isNoOp() public {
        _bigSwapDown();
        uint256 bondA = token1().balanceOf(address(hook));

        vm.roll(block.number + 3); // < observationBlocks
        vm.prank(keeper);
        uint256 settled = hook.settleBonds(key_, 10);
        assertEq(settled, 0, "immature bonds must not settle");
        assertEq(hook.queueLength(pid), 1);
        assertEq(token1().balanceOf(address(hook)), bondA, "no value may move");

        vm.roll(block.number + 8); // past maturity now
        vm.prank(keeper);
        assertEq(hook.settleBonds(key_, 10), 1);
    }

    // ---------------------------------------------------------------
    // Pot distribution
    // ---------------------------------------------------------------

    /// @notice Native-currency bonds use the same custody and donation path as ERC-20
    ///         bonds. This catches the address-zero branch in both settle and unlockCallback.
    function test_nativeBondAndPotDonation() public {
        vm.deal(address(this), 1 ether);
        (PoolKey memory nativeKey,) = initPool(
            CurrencyLibrary.ADDRESS_ZERO, currency1, IHooks(address(hook)), 3000, TickMath.getSqrtPriceAtTick(0)
        );
        modifyLiquidityRouter.modifyLiquidity{value: 1 ether}(
            nativeKey,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e18, salt: bytes32(0)}),
            ZERO_BYTES
        );
        PoolId nativePid = nativeKey.toId();

        // One-for-zero exact input takes token1 and outputs native currency; native is the
        // unspecified side, so the bond is held as ETH by the hook. Move to a new block so
        // the once-per-block accumulator records this first post-initialization move.
        vm.roll(block.number + 1);
        swapRouter.swap(
            nativeKey,
            SwapParams({zeroForOne: false, amountSpecified: -1e16, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            _ownerData()
        );
        uint256 bond = address(hook).balance;
        assertGt(bond, 0, "hook must hold native bond");
        assertEq(hook.queueLength(nativePid), 1);

        vm.roll(block.number + 11);
        vm.prank(keeper);
        hook.settleBonds(nativeKey, 10);
        uint256 pot = hook.insurancePot(nativePid, CurrencyLibrary.ADDRESS_ZERO);
        assertGt(pot, 0);
        assertEq(address(hook).balance, pot, "native hook balance must equal native pot");

        vm.prank(alice);
        hook.donatePot(nativeKey, CurrencyLibrary.ADDRESS_ZERO);
        assertEq(hook.insurancePot(nativePid, CurrencyLibrary.ADDRESS_ZERO), 0);
        assertEq(address(hook).balance, 0, "native pot must be paid into the pool");
    }

    /// @notice A callback-capable native receiver cannot freeze the queue. Its settler fee
    ///         becomes a pull payment, then succeeds after the receiver enables withdrawals.
    function test_rejectingReceiverGetsDeferredPayment() public {
        vm.deal(address(this), 1 ether);
        (PoolKey memory nativeKey,) = initPool(
            CurrencyLibrary.ADDRESS_ZERO, currency1, IHooks(address(hook)), 3000, TickMath.getSqrtPriceAtTick(0)
        );
        modifyLiquidityRouter.modifyLiquidity{value: 1 ether}(
            nativeKey,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e18, salt: bytes32(0)}),
            ZERO_BYTES
        );
        PoolId nativePid = nativeKey.toId();
        ToggleReceiver receiver = new ToggleReceiver();

        vm.roll(block.number + 1);
        swapRouter.swap(
            nativeKey,
            SwapParams({zeroForOne: false, amountSpecified: -1e16, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            _ownerData()
        );
        assertEq(hook.queueLength(nativePid), 1);

        vm.roll(block.number + 11);
        receiver.settle(hook, nativeKey);
        uint256 deferred = hook.claimablePayments(address(receiver), CurrencyLibrary.ADDRESS_ZERO);
        assertGt(deferred, 0, "rejecting receiver should get a deferred settler reward");
        assertEq(hook.queueLength(nativePid), 0, "receiver must not block queue progress");

        receiver.setAccepting(true);
        receiver.claim(hook, CurrencyLibrary.ADDRESS_ZERO);
        assertEq(hook.claimablePayments(address(receiver), CurrencyLibrary.ADDRESS_ZERO), 0);
        assertEq(address(receiver).balance, deferred);
    }

    /// @notice Unsolicited ETH cannot inflate the hook's accounted native balance.
    function test_directNativeTransferRejected() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool success,) = address(hook).call{value: 1 wei}("");
        assertFalse(success);
    }

    /// @notice A pot can only be donated as one of the pool's two currencies.
    function test_donatePot_rejectsUnrelatedCurrency() public {
        _bigSwapDown();
        vm.roll(block.number + 11);
        vm.prank(keeper);
        hook.settleBonds(key_, 10);

        vm.expectRevert(BondMeBro.InvalidCurrency.selector);
        hook.donatePot(key_, Currency.wrap(address(0x1234)));
    }

    /// @notice Anyone can push the pot to in-range LPs via PoolManager.donate; afterwards
    ///         the hook no longer holds those funds and the accounting resets.
    function test_donatePot_permissionless() public {
        _bigSwapDown();
        vm.roll(block.number + 11);
        vm.prank(keeper);
        hook.settleBonds(key_, 10);
        uint256 pot = hook.insurancePot(pid, currency1);
        assertGt(pot, 0);

        vm.prank(alice);
        hook.donatePot(key_, currency1);

        assertEq(hook.insurancePot(pid, currency1), 0, "pot accounting must reset");
        assertEq(token1().balanceOf(address(hook)), 0, "hook must no longer hold donated funds");

        vm.expectRevert(BondMeBro.NothingToDonate.selector);
        hook.donatePot(key_, currency1);
    }

    // ---------------------------------------------------------------
    // Bond accounting edges
    // ---------------------------------------------------------------

    /// @notice The bond currency is the swap's unspecified side: for exact-output the hook
    ///         raises the INPUT owed instead of shaving output.
    function test_exactOutput_bondComesFromInputSide() public {
        uint256 hook0Before = token0().balanceOf(address(hook));

        swapRouter.swap(
            key_,
            SwapParams({zeroForOne: true, amountSpecified: 4e15, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            _ownerData()
        );

        assertEq(hook.queueLength(pid), 1, "exact-output big-impact swap should also bond");
        bytes32 bondId = _onlyBondId();
        BondMeBro.Bond memory b = hook.getBond(pid, bondId);
        assertEq(Currency.unwrap(b.currency), Currency.unwrap(currency0), "bond must ride the input side");
        assertGt(b.amount, 0);
        assertEq(token0().balanceOf(address(hook)) - hook0Before, b.amount, "hook must hold the bond in token0");
    }

    /// @notice Without 32-byte hookData the bond owner falls back to the direct swap caller
    ///         (in production: the router; identity via hookData is the documented path).
    function test_owner_fallsBackToSwapCaller() public {
        swapRouter.swap(
            key_,
            SwapParams({zeroForOne: true, amountSpecified: -1e16, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        BondMeBro.Bond memory b = hook.getBond(pid, _onlyBondId());
        assertEq(b.owner, address(swapRouter));
    }
}

contract ToggleReceiver {
    bool public accepting;

    receive() external payable {
        if (!accepting) revert();
    }

    function setAccepting(bool value) external {
        accepting = value;
    }

    function settle(BondMeBro hook, PoolKey calldata key) external {
        hook.settleBonds(key, 32);
    }

    function claim(BondMeBro hook, Currency currency) external {
        hook.claimPayments(currency);
    }
}
