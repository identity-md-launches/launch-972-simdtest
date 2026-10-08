// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SIMDTEST} from "src/SIMDTEST.sol";
import {SIMDTESTHook} from "src/SIMDTESTHook.sol";
import {HookTestFixture} from "./SIMDTESTHook.t.sol";

contract WrongDecimalLaunchToken is ERC20 {
    constructor() ERC20("Six decimals", "SIX") {
        _mint(msg.sender, 1_000_000_000 ether);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

abstract contract HookAdversarialBase is HookTestFixture {
    using StateLibrary for IPoolManager;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    struct ReferenceSwap {
        BalanceDelta delta;
        uint160 price;
        int24 tick;
        uint256 growth0;
        uint256 growth1;
    }

    // Reuse the same fixed token supply, currencies, price and liquidity in a snapshot.
    // The reference pool has no callbacks and charges only the specified 1.25% LP fee.
    function _referenceSwap(IPoolManager.SwapParams memory params) internal returns (ReferenceSwap memory ref) {
        uint256 snapshot = vm.snapshotState();
        driver.liquidity(key, _liquidity(-int256(uint256(initialLiquidity))));
        token.approve(address(driver), type(uint256).max);
        PoolKey memory referenceKey = key;
        referenceKey.hooks = IHooks(address(0));
        manager.initialize(referenceKey, Q96);
        driver.liquidity(referenceKey, _liquidity(int256(uint256(initialLiquidity))));
        ref.delta = driver.swap(referenceKey, params);
        (ref.price, ref.tick,,) = manager.getSlot0(referenceKey.toId());
        (ref.growth0, ref.growth1) = manager.getFeeGrowthGlobals(referenceKey.toId());
        assertTrue(vm.revertToStateAndDelete(snapshot));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_MatchesIndependentPoolPlusOnlyIMDDonation(
        bool buy,
        bool exactInput,
        uint96 rawAmount,
        uint8 rawBlock,
        bool hourExpired
    ) public {
        uint256 elapsed = bound(rawBlock, 0, 15);
        vm.roll(openedAtBlock + elapsed);
        if (hourExpired) vm.warp(openedAtTime + 3600);
        uint256 rate = elapsed < 10 ? 300_000 - 30_000 * elapsed : 0;
        uint256 amount = bound(rawAmount, 1, hourExpired ? CAP * 2 : 1_000_000 ether);
        IPoolManager.SwapParams memory params = _params(buy, exactInput ? -int256(amount) : int256(amount));
        IPoolManager.SwapParams memory coreParams = _params(buy, params.amountSpecified);
        uint256 fee;
        if (buy && exactInput) fee = amount * rate / D;
        if (!buy && !exactInput) fee = amount * rate / (D - rate);
        coreParams.amountSpecified += int256(fee);
        ReferenceSwap memory ref = _referenceSwap(coreParams);
        if (buy && !exactInput) fee = uint256(-_pair(ref.delta)) * rate / (D - rate);
        if (!buy && exactInput) fee = uint256(_pair(ref.delta)) * rate / D;

        uint256 poolPairBefore = imd.balanceOf(address(manager));
        vm.recordLogs();
        BalanceDelta actual = driver.swap(key, params);
        _assertDonationLogs(vm.getRecordedLogs(), fee, rate);
        assertEq(_token(actual), _token(ref.delta), "no token tax or changed execution");
        assertEq(_pair(actual), _pair(ref.delta) - int256(fee), "only extra charge is donated IMD");
        assertEq(int256(imd.balanceOf(address(manager))) - int256(poolPairBefore), -_pair(actual));
        (uint160 price, int24 tick,, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(price, ref.price);
        assertEq(tick, ref.tick);
        assertEq(lpFee, 12500);
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(key.toId());
        uint256 donationGrowth = FullMath.mulDiv(fee, 1 << 128, initialLiquidity);
        assertEq(growth0, ref.growth0 + (pair0 ? donationGrowth : 0));
        assertEq(growth1, ref.growth1 + (pair0 ? 0 : donationGrowth));
        assertEq(manager.getLiquidity(key.toId()), initialLiquidity);
        _assertSettled();
    }

    function _assertDonationLogs(Vm.Log[] memory logs, uint256 expected, uint256 rate) internal view {
        uint256 managerEvents;
        uint256 hookEvents;
        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].emitter == address(manager)
                    && logs[i].topics[0] == keccak256("Donate(bytes32,address,uint256,uint256)")
            ) {
                (uint256 amount0, uint256 amount1) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(logs[i].topics[1], PoolId.unwrap(key.toId()));
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(hook));
                assertEq(pair0 ? amount0 : amount1, expected);
                assertEq(pair0 ? amount1 : amount0, 0);
                managerEvents++;
            }
            if (
                logs[i].emitter == address(hook)
                    && logs[i].topics[0] == keccak256("AntiSnipeDonation(bytes32,uint256,uint256)")
            ) {
                (uint256 actualRate, uint256 amount) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(logs[i].topics[1], PoolId.unwrap(key.toId()));
                assertEq(actualRate, rate);
                assertEq(amount, expected);
                hookEvents++;
            }
        }
        assertEq(managerEvents, expected == 0 ? 0 : 1);
        assertEq(hookEvents, managerEvents);
    }

    function _stateHash() internal view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(key.toId());
        return keccak256(
            abi.encode(
                price,
                tick,
                protocolFee,
                lpFee,
                growth0,
                growth1,
                manager.getLiquidity(key.toId()),
                token.balanceOf(address(this)),
                imd.balanceOf(address(this)),
                token.balanceOf(address(manager)),
                imd.balanceOf(address(manager)),
                hook.openingBlock(),
                hook.openingTimestamp()
            )
        );
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_CapViolationRollsBackAllAccounting(uint96 rawExcess, uint16 rawTime, uint8 rawBlock) public {
        uint256 requested = CAP + bound(rawExcess, 1, CAP);
        vm.warp(openedAtTime + bound(rawTime, 0, 3599));
        vm.roll(openedAtBlock + bound(rawBlock, 0, 12));
        bytes32 beforeState = _stateHash();
        _expectHookError(
            IHooks.afterSwap.selector, abi.encodeWithSelector(SIMDTESTHook.MaxBuyExceeded.selector, requested, CAP)
        );
        driver.swap(key, _params(true, int256(requested)));
        assertEq(_stateHash(), beforeState, "rejected buy changed pool or balances");
        _assertSettled();
        // A revert cannot poison the next swap in the same transaction.
        assertEq(_token(driver.swap(key, _params(true, int256(CAP)))), int256(CAP));
        _assertSettled();
    }

    function test_ZeroSwapRevertsAndPreservesState() public {
        bytes32 beforeState = _stateHash();
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        driver.swap(key, _params(true, 0));
        assertEq(_stateHash(), beforeState);
        _assertSettled();
    }

    function test_FailedSettlementRollsBackSwapAndDonation() public {
        bytes32 beforeState = _stateHash();
        imd.approve(address(driver), 0);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientAllowance(address,uint256,uint256)", address(driver), 0, 1000 ether
            )
        );
        driver.swap(key, _params(true, -1000 ether));
        assertEq(_stateHash(), beforeState);
        _assertSettled();
        imd.approve(address(driver), type(uint256).max);
        assertEq(_pair(driver.swap(key, _params(true, -1000 ether))), -1000 ether);
    }

    function test_AllPoolKeyFieldsAreBoundForBothSwapCallbacks() public {
        for (uint256 field; field < 5; field++) {
            PoolKey memory wrong = key;
            if (field == 0) wrong.currency0 = Currency.wrap(makeAddr("other currency0"));
            if (field == 1) wrong.currency1 = Currency.wrap(makeAddr("other currency1"));
            if (field == 2) wrong.fee = 0;
            if (field == 3) wrong.tickSpacing = 1;
            if (field == 4) wrong.hooks = IHooks(makeAddr("other hook"));
            vm.startPrank(address(manager));
            vm.expectRevert(SIMDTESTHook.WrongPool.selector);
            hook.beforeSwap(address(this), wrong, _params(true, -1 ether), "");
            vm.expectRevert(SIMDTESTHook.WrongPool.selector);
            hook.afterSwap(address(this), wrong, _params(true, -1 ether), BalanceDelta.wrap(0), "");
            vm.stopPrank();
        }
    }

    function test_AfterSwapBeforeOpeningCannotStartClock() public {
        SIMDTEST freshToken = new SIMDTEST();
        SIMDTESTHook fresh = _deployHook(address(freshToken));
        bool first = IMD < address(freshToken);
        PoolKey memory freshKey = PoolKey(
            Currency.wrap(first ? IMD : address(freshToken)),
            Currency.wrap(first ? address(freshToken) : IMD),
            12500,
            60,
            IHooks(address(fresh))
        );
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.NotOpened.selector);
        fresh.afterSwap(address(this), freshKey, _params(true, -1 ether), BalanceDelta.wrap(0), "");
        assertFalse(fresh.opened());
        assertEq(fresh.openingBlock(), 0);
        assertEq(fresh.openingTimestamp(), 0);
    }

    function test_CorrectSupplyWithWrongDecimalsIsRejected() public {
        WrongDecimalLaunchToken wrong = new WrongDecimalLaunchToken();
        vm.expectRevert(SIMDTESTHook.InvalidDeployment.selector);
        new SIMDTESTHook(manager, address(wrong));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_SpecifiedFeeAtInt128Boundary(uint8 rawBlock, uint128 rawAmount) public {
        uint256 elapsed = bound(rawBlock, 0, 9);
        vm.roll(openedAtBlock + elapsed);
        uint256 rate = 300_000 - elapsed * 30_000;
        uint256 amount = bound(rawAmount, 1, uint256(uint128(type(int128).max)));
        vm.prank(address(manager));
        (, BeforeSwapDelta delta, uint24 overrideFee) =
            hook.beforeSwap(address(this), key, _params(true, -int256(amount)), "");
        assertEq(delta.getSpecifiedDelta(), int256(amount * rate / D));
        assertEq(delta.getUnspecifiedDelta(), 0);
        assertEq(overrideFee, 0);
        uint256 gross = amount + amount * rate / (D - rate);
        vm.prank(address(manager));
        if (gross > uint256(uint128(type(int128).max))) {
            vm.expectRevert(SIMDTESTHook.SwapAmountTooLarge.selector);
            hook.beforeSwap(address(this), key, _params(false, int256(amount)), "");
        } else {
            (, delta,) = hook.beforeSwap(address(this), key, _params(false, int256(amount)), "");
            assertEq(delta.getSpecifiedDelta(), int256(gross - amount));
            assertEq(delta.getUnspecifiedDelta(), 0);
        }
    }
}

/// forge-config: default.fuzz.runs = 1000
contract SIMDTESTHookAdversarialPair0Test is HookAdversarialBase {
    function _pair0() internal pure override returns (bool) {
        return true;
    }
}

/// forge-config: default.fuzz.runs = 1000
contract SIMDTESTHookAdversarialPair1Test is HookAdversarialBase {
    function _pair0() internal pure override returns (bool) {
        return false;
    }
}
