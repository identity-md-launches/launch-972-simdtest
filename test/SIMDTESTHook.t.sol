// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SIMDTEST} from "../src/SIMDTEST.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {PoolDriver} from "./helpers/PoolDriver.sol";

contract MockIMD is ERC20 {
    constructor() ERC20("Test IMD", "IMD") {}

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }
}

abstract contract HookTestFixture is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint160 constant Q96 = 79228162514264337593543950336;
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant CAP = SUPPLY / 100;
    uint256 constant D = 1_000_000;
    uint160 constant FLAGS = 0x20cc;
    int24 constant LOWER = -887220;
    int24 constant UPPER = 887220;

    IPoolManager manager;
    SIMDTEST token;
    SIMDTESTHook hook;
    MockIMD imd;
    PoolDriver driver;
    PoolKey key;
    bool pair0;
    uint128 initialLiquidity;
    uint256 openedAtBlock;
    uint256 openedAtTime;

    function _pair0() internal pure virtual returns (bool);

    function setUp() public virtual {
        vm.chainId(1);
        vm.roll(100);
        vm.warp(10_000);
        manager = IPoolManager(address(new PoolManager(address(this))));
        pair0 = _pair0();
        bytes32 tokenHash = keccak256(type(SIMDTEST).creationCode);
        uint256 salt;
        for (;; salt++) {
            address predicted = _address(bytes32(salt), tokenHash);
            if ((IMD < predicted) == pair0 && predicted != IMD) break;
        }
        token = new SIMDTEST{salt: bytes32(salt)}();
        MockIMD template = new MockIMD();
        vm.etch(IMD, address(template).code);
        imd = MockIMD(IMD);
        imd.mint(address(this), SUPPLY * 3);
        hook = _deployHook(address(token));
        key = PoolKey({
            currency0: Currency.wrap(pair0 ? IMD : address(token)),
            currency1: Currency.wrap(pair0 ? address(token) : IMD),
            fee: 12_500,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, Q96);
        openedAtBlock = block.number;
        openedAtTime = block.timestamp;
        driver = new PoolDriver(manager);
        token.approve(address(driver), SUPPLY);
        imd.approve(address(driver), SUPPLY * 3);
        // Full range at 1:1. Select L such that the rounded token deposit is exactly 90%.
        uint256 allocation = SUPPLY * 9 / 10;
        if (pair0) {
            initialLiquidity = uint128(FullMath.mulDiv(allocation, Q96, Q96 - TickMath.getSqrtPriceAtTick(LOWER)));
        } else {
            uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(UPPER);
            initialLiquidity = uint128(FullMath.mulDiv(allocation, sqrtUpper, sqrtUpper - Q96));
        }
        driver.liquidity(key, _liquidity(int256(uint256(initialLiquidity))));
        assertEq(token.balanceOf(address(manager)), allocation, "90% seeded");
    }

    function _deployHook(address tokenAddress) internal returns (SIMDTESTHook deployed) {
        bytes32 codeHash =
            keccak256(abi.encodePacked(type(SIMDTESTHook).creationCode, abi.encode(manager, tokenAddress)));
        for (uint256 salt;; salt++) {
            address predicted = _address(bytes32(salt), codeHash);
            if (uint160(predicted) & ((1 << 14) - 1) == FLAGS) {
                deployed = new SIMDTESTHook{salt: bytes32(salt)}(manager, tokenAddress);
                assertEq(address(deployed), predicted);
                return deployed;
            }
        }
    }

    function _address(bytes32 salt, bytes32 codeHash) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, codeHash)))));
    }

    function _liquidity(int256 amount) internal pure returns (IPoolManager.ModifyLiquidityParams memory) {
        return IPoolManager.ModifyLiquidityParams(LOWER, UPPER, amount, bytes32(0));
    }

    function _params(bool buy, int256 amount) internal view returns (IPoolManager.SwapParams memory) {
        bool zeroForOne = buy == pair0;
        return IPoolManager.SwapParams(
            zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    function _pair(BalanceDelta delta) internal view returns (int256) {
        return pair0 ? delta.amount0() : delta.amount1();
    }

    function _token(BalanceDelta delta) internal view returns (int256) {
        return pair0 ? delta.amount1() : delta.amount0();
    }

    function _wrapped(bytes4 callback, bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSignature(
            "WrappedError(address,bytes4,bytes,bytes)",
            address(hook),
            callback,
            reason,
            abi.encodePacked(Hooks.HookCallFailed.selector)
        );
    }

    function _expectHookError(bytes4 callback, bytes memory reason) internal {
        vm.expectRevert(_wrapped(callback, reason));
    }

    function _assertSettled() internal view {
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), 0);
        assertEq(manager.balanceOf(address(hook), uint160(address(token))), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
    }
}

abstract contract HookTestBase is HookTestFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    function testInitializationAndPermissions() public view {
        assertTrue(hook.opened());
        assertEq(hook.openingBlock(), openedAtBlock);
        assertEq(hook.openingTimestamp(), openedAtTime);
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.token(), address(token));
        Hooks.validateHookPermissions(IHooks(address(hook)), hook.getHookPermissions());
        (,,, uint24 fee) = manager.getSlot0(key.toId());
        assertEq(fee, 12500);
    }

    function testUnauthorizedCallbacks() public {
        IPoolManager.SwapParams memory params = _params(true, -1 ether);
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, Q96);
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
    }

    function testCannotReinitializeOrResetClock() public {
        _expectHookError(IHooks.beforeInitialize.selector, abi.encodeWithSelector(SIMDTESTHook.AlreadyOpened.selector));
        manager.initialize(key, Q96);
        assertEq(hook.openingBlock(), openedAtBlock);
    }

    function testWrongPoolKeysRejected() public {
        PoolKey memory other = key;
        other.fee = 3000;
        _expectHookError(IHooks.beforeInitialize.selector, abi.encodeWithSelector(SIMDTESTHook.WrongPool.selector));
        manager.initialize(other, Q96);
        other = key;
        other.tickSpacing = 10;
        _expectHookError(IHooks.beforeInitialize.selector, abi.encodeWithSelector(SIMDTESTHook.WrongPool.selector));
        manager.initialize(other, Q96);
        other = key;
        other.currency0 = Currency.wrap(address(new MockIMD()));
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.WrongPool.selector);
        hook.beforeInitialize(address(this), other, Q96);
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.WrongPool.selector);
        hook.beforeSwap(address(this), other, _params(true, -1 ether), "");
    }

    function testAllTenBlocksAndEndDonateExactAmounts() public {
        for (uint256 elapsed; elapsed <= 10; elapsed++) {
            vm.roll(openedAtBlock + elapsed);
            uint256 rate = elapsed < 10 ? 300_000 - elapsed * 30_000 : 0;
            assertEq(hook.antiSnipeFee(), rate);
            _checkAccounting(true, true, 1000 ether, rate);
            _checkAccounting(true, false, 1000 ether, rate);
            _checkAccounting(false, true, 1000 ether, rate);
            _checkAccounting(false, false, 1000 ether, rate);
        }
    }

    struct Accounting {
        uint256 imdBefore;
        uint256 tokenBefore;
        uint256 managerIMDBefore;
        uint256 managerTokenBefore;
        uint256 growth0Before;
        uint256 growth1Before;
        int256 corePair;
        int256 coreToken;
        uint256 donated;
        uint256 donationCount;
    }

    function _checkAccounting(bool buy, bool exactInput, uint256 amount, uint256 rate) internal {
        Accounting memory a;
        a.imdBefore = imd.balanceOf(address(this));
        a.tokenBefore = token.balanceOf(address(this));
        a.managerIMDBefore = imd.balanceOf(address(manager));
        a.managerTokenBefore = token.balanceOf(address(manager));
        (a.growth0Before, a.growth1Before) = manager.getFeeGrowthGlobals(key.toId());
        vm.recordLogs();
        BalanceDelta result = driver.swap(key, _params(buy, exactInput ? -int256(amount) : int256(amount)));
        _readSwapEvents(a);
        uint256 expected;
        if (buy && exactInput) expected = amount * rate / D;
        if (buy && !exactInput) expected = uint256(-a.corePair) * rate / (D - rate);
        if (!buy && exactInput) expected = uint256(a.corePair) * rate / D;
        if (!buy && !exactInput) expected = amount * rate / (D - rate);
        assertEq(a.donated, expected, "donation matches fee formula");
        assertEq(a.donationCount, expected == 0 ? 0 : 1);
        assertEq(_pair(result), a.corePair - int256(expected));
        assertEq(_token(result), a.coreToken);
        if (buy) {
            assertEq(a.imdBefore - imd.balanceOf(address(this)), uint256(-_pair(result)));
            assertEq(token.balanceOf(address(this)) - a.tokenBefore, uint256(_token(result)));
            assertEq(imd.balanceOf(address(manager)) - a.managerIMDBefore, uint256(-a.corePair) + expected);
            assertEq(a.managerTokenBefore - token.balanceOf(address(manager)), uint256(a.coreToken));
        } else {
            assertEq(imd.balanceOf(address(this)) - a.imdBefore, uint256(_pair(result)));
            assertEq(a.tokenBefore - token.balanceOf(address(this)), uint256(-a.coreToken));
            assertEq(a.managerIMDBefore - imd.balanceOf(address(manager)), uint256(a.corePair) - expected);
            assertEq(token.balanceOf(address(manager)) - a.managerTokenBefore, uint256(-a.coreToken));
        }
        if (exactInput) assertEq(buy ? -_pair(result) : -_token(result), int256(amount));
        else assertEq(buy ? _token(result) : _pair(result), int256(amount));
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(key.toId());
        uint256 donatedGrowth = FullMath.mulDiv(expected, 1 << 128, initialLiquidity);
        uint256 pairGrowth = pair0 ? growth0 - a.growth0Before : growth1 - a.growth1Before;
        if (buy) assertGe(pairGrowth, donatedGrowth);
        else assertEq(pairGrowth, donatedGrowth, "sell pair fee growth solely from donation");
        assertEq(manager.getLiquidity(key.toId()), initialLiquidity, "donation accrues fees, not position units");
        _assertSettled();
    }

    function _readSwapEvents(Accounting memory a) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(manager)) continue;
            if (logs[i].topics[0] == keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")) {
                (int128 pool0, int128 pool1,,,, uint24 lpFee) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                a.corePair = pair0 ? pool0 : pool1;
                a.coreToken = pair0 ? pool1 : pool0;
                assertEq(lpFee, 12500, "LP fee unchanged");
            }
            if (logs[i].topics[0] == keccak256("Donate(bytes32,address,uint256,uint256)")) {
                (uint256 amount0, uint256 amount1) = abi.decode(logs[i].data, (uint256, uint256));
                a.donated += pair0 ? amount0 : amount1;
                assertEq(pair0 ? amount1 : amount0, 0, "no SIMDTEST fee");
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(hook));
                a.donationCount++;
            }
        }
    }

    function testBuyCapExactOutputAndOneWeiOver() public {
        _expectHookError(
            IHooks.afterSwap.selector, abi.encodeWithSelector(SIMDTESTHook.MaxBuyExceeded.selector, CAP + 1, CAP)
        );
        driver.swap(key, _params(true, int256(CAP + 1)));
        BalanceDelta result = driver.swap(key, _params(true, int256(CAP)));
        assertEq(_token(result), int256(CAP));
    }

    function testBuyCapExactInputRevertsWithoutTakingFunds() public {
        uint256 pairBefore = imd.balanceOf(address(this));
        uint256 tokenBefore = token.balanceOf(address(this));
        (uint160 priceBefore,,,) = manager.getSlot0(key.toId());
        // Quote the same 21m core input without launch protection, then restore ALL state.
        uint256 snapshot = vm.snapshotState();
        vm.roll(openedAtBlock + 10);
        vm.warp(openedAtTime + 3600);
        uint256 purchased = uint256(_token(driver.swap(key, _params(true, -21_000_000 ether))));
        assertGt(purchased, CAP);
        vm.revertToState(snapshot);
        _expectHookError(
            IHooks.afterSwap.selector, abi.encodeWithSelector(SIMDTESTHook.MaxBuyExceeded.selector, purchased, CAP)
        );
        driver.swap(key, _params(true, -30_000_000 ether));
        assertEq(imd.balanceOf(address(this)), pairBefore);
        assertEq(token.balanceOf(address(this)), tokenBefore);
        (uint160 priceAfter,,,) = manager.getSlot0(key.toId());
        assertEq(priceAfter, priceBefore);
        _assertSettled();
    }

    function testBuyCapTimeBoundaryAndNoSellOrTransferLimit() public {
        vm.roll(openedAtBlock + 10);
        vm.warp(openedAtTime + 3599);
        _expectHookError(
            IHooks.afterSwap.selector, abi.encodeWithSelector(SIMDTESTHook.MaxBuyExceeded.selector, CAP + 1, CAP)
        );
        driver.swap(key, _params(true, int256(CAP + 1)));
        BalanceDelta sell = driver.swap(key, _params(false, -int256(CAP * 2)));
        assertEq(_token(sell), -int256(CAP * 2));
        address recipient = makeAddr("recipient");
        token.transfer(recipient, CAP * 2);
        assertEq(token.balanceOf(recipient), CAP * 2);
        vm.warp(openedAtTime + 3600);
        _checkAccounting(true, false, CAP + 1, 0);
        _checkAccounting(true, true, CAP * 2, 0);
    }

    function testBuyCapIsPerSwapNotCumulative() public {
        driver.swap(key, _params(true, int256(CAP)));
        driver.swap(key, _params(true, int256(CAP)));
        _assertSettled();
    }

    function testLargeSellsDuringAntiSnipeHaveNoBuyCap() public {
        _checkAccounting(false, true, CAP * 2, 300_000);
        _checkAccounting(false, false, CAP * 2, 300_000);
    }

    function testTimeAndBlockWindowsIndependent() public {
        vm.warp(openedAtTime + 3600);
        assertEq(hook.antiSnipeFee(), 300_000);
        _checkAccounting(true, false, CAP + 1, 300_000);
    }

    function testNormalSwapsAfterBothPeriods() public {
        vm.roll(openedAtBlock + 100);
        vm.warp(openedAtTime + 7200);
        _checkAccounting(true, true, CAP * 2, 0);
        _checkAccounting(true, false, CAP * 2, 0);
        _checkAccounting(false, true, CAP * 2, 0);
        _checkAccounting(false, false, CAP * 2, 0);
    }

    function testDonationCanBeCollectedByInRangeLP() public {
        vm.recordLogs();
        BalanceDelta sold = driver.swap(key, _params(false, -1000 ether));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 donated;
        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].emitter == address(hook)
                    && logs[i].topics[0] == keccak256("AntiSnipeDonation(bytes32,uint256,uint256)")
            ) {
                (, donated) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
        assertGt(donated, 0);
        assertGt(_pair(sold), 0);
        uint256 before = imd.balanceOf(address(this));
        (, BalanceDelta fees) = driver.liquidity(key, _liquidity(0));
        assertApproxEqAbs(uint256(_pair(fees)), donated, 1);
        assertEq(imd.balanceOf(address(this)) - before, uint256(_pair(fees)));
        _assertSettled();
    }

    function testPartialSpecifiedFeeRevertsAtomically() public {
        for (uint256 i; i < 2; i++) {
            bool buy = i == 0;
            IPoolManager.SwapParams memory params = _params(buy, buy ? -1000 ether : int256(1000 ether));
            params.sqrtPriceLimitX96 = params.zeroForOne ? Q96 - 1 : Q96 + 1;
            _expectHookError(
                IHooks.afterSwap.selector, abi.encodeWithSelector(SIMDTESTHook.PartialFillWithSpecifiedFee.selector)
            );
            driver.swap(key, params);
            (uint160 price,,,) = manager.getSlot0(key.toId());
            assertEq(price, Q96);
        }
        _assertSettled();
    }

    function testPartialFillsAllowedAfterAntiSnipe() public {
        vm.roll(openedAtBlock + 10);
        IPoolManager.SwapParams memory params = _params(true, -1000 ether);
        params.sqrtPriceLimitX96 = params.zeroForOne ? Q96 - 100000 : Q96 + 100000;
        BalanceDelta result = driver.swap(key, params);
        assertLt(uint256(-_pair(result)), 1000 ether);
        _assertSettled();
    }

    function testUnspecifiedPairPartialFillsChargeOnlyExecutedAmount() public {
        for (uint256 i; i < 2; i++) {
            bool buy = i == 0;
            (uint160 price,,,) = manager.getSlot0(key.toId());
            IPoolManager.SwapParams memory params = _params(buy, buy ? int256(1000 ether) : -1000 ether);
            params.sqrtPriceLimitX96 = params.zeroForOne ? price - Q96 / 1_000_000 : price + Q96 / 1_000_000;
            Accounting memory a;
            vm.recordLogs();
            BalanceDelta result = driver.swap(key, params);
            _readSwapEvents(a);
            uint256 expected = buy ? uint256(-a.corePair) * 3 / 7 : uint256(a.corePair) * 3 / 10;
            assertEq(a.donated, expected);
            assertEq(_pair(result), a.corePair - int256(expected));
            assertLt(buy ? _token(result) : -_token(result), 1000 ether);
            assertGt(expected, 0);
        }
        _assertSettled();
    }

    function testOutOfRangeLiquidityReceivesNoDonation() public {
        IPoolManager.ModifyLiquidityParams memory inactive =
            IPoolManager.ModifyLiquidityParams(60, 120, 1_000_000 ether, bytes32(uint256(1)));
        driver.liquidity(key, inactive);
        assertEq(manager.getLiquidity(key.toId()), initialLiquidity);
        driver.swap(key, _params(false, -1000 ether));
        inactive.liquidityDelta = 0;
        (, BalanceDelta inactiveFees) = driver.liquidity(key, inactive);
        assertEq(BalanceDelta.unwrap(inactiveFees), 0);
        (, BalanceDelta activeFees) = driver.liquidity(key, _liquidity(0));
        assertGt(_pair(activeFees), 0);
        _assertSettled();
    }

    function testEmptyPoolUnspecifiedSwapHasNoFee() public {
        driver.liquidity(key, _liquidity(-int256(uint256(initialLiquidity))));
        assertEq(manager.getLiquidity(key.toId()), 0);
        // With no active liquidity, no actual unspecified-side fee can be levied.
        BalanceDelta empty = driver.swap(key, _params(false, -1000 ether));
        assertEq(BalanceDelta.unwrap(empty), 0);
        _assertSettled();
    }

    function testCannotDonateWithoutActiveLiquidityRollsBackSwap() public {
        driver.liquidity(key, _liquidity(-int256(uint256(initialLiquidity))));
        driver.liquidity(key, IPoolManager.ModifyLiquidityParams(-60, 60, 1_000_000 ether, bytes32(uint256(2))));
        uint256 pairBefore = imd.balanceOf(address(this));
        uint256 tokenBefore = token.balanceOf(address(this));
        _expectHookError(IHooks.afterSwap.selector, abi.encodeWithSelector(Pool.NoLiquidityToReceiveFees.selector));
        driver.swap(key, _params(true, 100_000 ether));
        assertEq(imd.balanceOf(address(this)), pairBefore);
        assertEq(token.balanceOf(address(this)), tokenBefore);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, Q96);
        _assertSettled();
    }

    function testSwapBeforeOpenAndWrongAddressMask() public {
        SIMDTEST otherToken = new SIMDTEST();
        SIMDTESTHook otherHook = _deployHook(address(otherToken));
        PoolKey memory otherKey = PoolKey({
            currency0: Currency.wrap(IMD < address(otherToken) ? IMD : address(otherToken)),
            currency1: Currency.wrap(IMD < address(otherToken) ? address(otherToken) : IMD),
            fee: 12500,
            tickSpacing: 60,
            hooks: IHooks(address(otherHook))
        });
        assertFalse(otherHook.opened());
        assertEq(otherHook.antiSnipeFee(), 0);
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.NotOpened.selector);
        otherHook.beforeSwap(address(this), otherKey, _params(true, -1 ether), "");
        bytes32 codeHash =
            keccak256(abi.encodePacked(type(SIMDTESTHook).creationCode, abi.encode(manager, address(token))));
        for (uint256 salt;; salt++) {
            address predicted = _address(bytes32(salt), codeHash);
            if (uint160(predicted) & ((1 << 14) - 1) != FLAGS) {
                vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
                this.deployWithSalt(bytes32(salt));
                break;
            }
        }
    }

    function testPoolCannotInitializeBeforeHookDeployment() public {
        SIMDTEST freshToken = new SIMDTEST();
        bytes32 codeHash =
            keccak256(abi.encodePacked(type(SIMDTESTHook).creationCode, abi.encode(manager, address(freshToken))));
        uint256 salt;
        address predicted;
        for (;; salt++) {
            predicted = _address(bytes32(salt), codeHash);
            if (uint160(predicted) & ((1 << 14) - 1) == FLAGS) break;
        }
        PoolKey memory predictedKey = PoolKey({
            currency0: Currency.wrap(IMD < address(freshToken) ? IMD : address(freshToken)),
            currency1: Currency.wrap(IMD < address(freshToken) ? address(freshToken) : IMD),
            fee: 12500,
            tickSpacing: 60,
            hooks: IHooks(predicted)
        });
        vm.expectRevert(Hooks.InvalidHookResponse.selector);
        manager.initialize(predictedKey, Q96);
        SIMDTESTHook freshHook = new SIMDTESTHook{salt: bytes32(salt)}(manager, address(freshToken));
        manager.initialize(predictedKey, Q96);
        assertTrue(freshHook.opened());
    }

    function testInvalidConstructorInputs() public {
        address noManager = makeAddr("no manager code");
        address noToken = makeAddr("no token code");
        vm.expectRevert(SIMDTESTHook.InvalidDeployment.selector);
        this.deployUnchecked(IPoolManager(noManager), address(token));
        vm.expectRevert(SIMDTESTHook.InvalidDeployment.selector);
        this.deployUnchecked(manager, noToken);
        vm.expectRevert(SIMDTESTHook.InvalidDeployment.selector);
        this.deployUnchecked(manager, IMD);
        MockIMD wrongSupply = new MockIMD();
        vm.expectRevert(SIMDTESTHook.InvalidDeployment.selector);
        this.deployUnchecked(manager, address(wrongSupply));
        // This line is reached even when Foundry uses dynamic test linking.
        assertEq(wrongSupply.totalSupply(), 0);
    }

    function deployUnchecked(IPoolManager manager_, address token_) external returns (SIMDTESTHook) {
        return new SIMDTESTHook(manager_, token_);
    }

    function deployWithSalt(bytes32 salt) external returns (SIMDTESTHook) {
        return new SIMDTESTHook{salt: salt}(manager, address(token));
    }

    function testOversizedSpecifiedAmountsRejectBeforeArithmetic() public {
        _expectHookError(IHooks.beforeSwap.selector, abi.encodeWithSelector(SIMDTESTHook.SwapAmountTooLarge.selector));
        driver.swap(key, _params(true, type(int256).min));
        _expectHookError(IHooks.beforeSwap.selector, abi.encodeWithSelector(SIMDTESTHook.SwapAmountTooLarge.selector));
        driver.swap(key, _params(false, type(int128).max));
    }

    function testTinyAmountsRoundDownWithoutUnsettledFees() public {
        for (uint256 amount = 1; amount <= 12; amount++) {
            _checkAccounting(true, true, amount, 300_000);
            _checkAccounting(true, false, amount, 300_000);
            _checkAccounting(false, true, amount, 300_000);
            _checkAccounting(false, false, amount, 300_000);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzFeeAccounting(bool buy, bool exactInput, uint88 raw, uint8 elapsed) public {
        uint256 amount = bound(uint256(raw), 1 ether, 100_000 ether);
        uint256 blocksElapsed = bound(uint256(elapsed), 0, 15);
        vm.roll(openedAtBlock + blocksElapsed);
        uint256 rate = blocksElapsed < 10 ? 300_000 - blocksElapsed * 30_000 : 0;
        _checkAccounting(buy, exactInput, amount, rate);
    }

    function testCreationAndRuntimeSize() public view {
        assertLt(type(SIMDTESTHook).creationCode.length + 64, 49152);
        assertLt(address(hook).code.length, 24576);
    }
}

/// forge-config: default.fuzz.runs = 1000
contract SIMDTESTHookPair0Test is HookTestBase {
    function _pair0() internal pure override returns (bool) {
        return true;
    }
}

/// forge-config: default.fuzz.runs = 1000
contract SIMDTESTHookPair1Test is HookTestBase {
    function _pair0() internal pure override returns (bool) {
        return false;
    }
}
