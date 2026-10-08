// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SIMDTESTHook} from "src/SIMDTESTHook.sol";
import {PoolDriver} from "./PoolDriver.sol";

/// @dev Only this handler is targeted. No mint/deal/storage edits occur after funding.
/// Unexpected reverts fail the invariant campaign; expected failures check exact errors.
contract LaunchHandler is Test {
    using StateLibrary for IPoolManager;

    uint256 constant CAP = 10_000_000 ether;
    uint256 constant D = 1_000_000;
    int24 constant LOWER = -887220;
    int24 constant UPPER = 887220;

    IPoolManager public immutable manager;
    SIMDTESTHook public immutable hook;
    PoolDriver public immutable driver;
    IERC20 public immutable token;
    IERC20 public immutable imd;
    bool public immutable pair0;
    uint256 public immutable openingBlock;
    uint256 public immutable openingTime;
    uint128 public immutable baseLiquidity;
    PoolKey internal key;
    address[3] public holders;

    uint128 public extraLiquidity;
    uint256 public expectedPoolToken;
    uint256 public expectedPoolIMD;
    uint256 public donations;
    uint256 public operations;
    uint256 public swaps;
    uint256 public rejectedBuys;
    uint256 public collections;
    uint256 public positionChanges;
    uint256 public transfers;

    constructor(
        IPoolManager manager_,
        SIMDTESTHook hook_,
        PoolDriver driver_,
        PoolKey memory key_,
        uint128 liquidity_
    ) {
        manager = manager_;
        hook = hook_;
        driver = driver_;
        key = key_;
        token = IERC20(hook_.token());
        imd = IERC20(hook_.IMD());
        pair0 = hook_.pairedIsCurrency0();
        openingBlock = hook_.openingBlock();
        openingTime = hook_.openingTimestamp();
        baseLiquidity = liquidity_;
        expectedPoolToken = token.balanceOf(address(manager_));
        expectedPoolIMD = imd.balanceOf(address(manager_));
        holders[0] = address(this);
        holders[1] = makeAddr("launch holder one");
        holders[2] = makeAddr("launch holder two");
        token.approve(address(driver_), type(uint256).max);
        imd.approve(address(driver_), type(uint256).max);
    }

    function _pair(BalanceDelta delta) internal view returns (int256) {
        return pair0 ? delta.amount0() : delta.amount1();
    }

    function _token(BalanceDelta delta) internal view returns (int256) {
        return pair0 ? delta.amount1() : delta.amount0();
    }

    function _params(bool buy, int256 amount) internal view returns (IPoolManager.SwapParams memory) {
        bool zeroForOne = buy == pair0;
        return IPoolManager.SwapParams(
            zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    function _recordSettlement(BalanceDelta delta, uint256 tokenBefore, uint256 imdBefore) internal {
        int256 nextToken = int256(expectedPoolToken) - _token(delta);
        int256 nextIMD = int256(expectedPoolIMD) - _pair(delta);
        assertGe(nextToken, 0);
        assertGe(nextIMD, 0);
        expectedPoolToken = uint256(nextToken);
        expectedPoolIMD = uint256(nextIMD);
        assertEq(int256(token.balanceOf(address(this))) - int256(tokenBefore), _token(delta));
        assertEq(int256(imd.balanceOf(address(this))) - int256(imdBefore), _pair(delta));
        operations++;
    }

    function swap(uint96 rawAmount, bool buy, bool exactInput) public {
        // Full-range base liquidity stays in place. A factor of four also funds exact-output fees.
        uint256 available = (buy ? imd : token).balanceOf(address(this)) / 4;
        uint256 maximum = available < 100_000 ether ? available : 100_000 ether;
        if (maximum == 0) return;
        uint256 amount = bound(rawAmount, 1, maximum);
        uint256 tokenBefore = token.balanceOf(address(this));
        uint256 imdBefore = imd.balanceOf(address(this));
        vm.recordLogs();
        BalanceDelta result = driver.swap(key, _params(buy, exactInput ? -int256(amount) : int256(amount)));
        _checkSwap(vm.getRecordedLogs(), result, buy, exactInput, amount);
        _recordSettlement(result, tokenBefore, imdBefore);
        if (buy && block.timestamp < openingTime + 3600) assertLe(_token(result), int256(CAP));
        if (exactInput) assertEq(buy ? -_pair(result) : -_token(result), int256(amount));
        else assertEq(buy ? _token(result) : _pair(result), int256(amount));
        swaps++;
    }

    function _checkSwap(Vm.Log[] memory logs, BalanceDelta result, bool buy, bool exactInput, uint256 amount) internal {
        int256 corePair;
        int256 coreToken;
        uint256 donated;
        uint256 donationEvents;
        uint256 swapEvents;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(manager)) continue;
            if (logs[i].topics[0] == keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")) {
                (int128 delta0, int128 delta1,,,, uint24 fee) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                corePair = pair0 ? delta0 : delta1;
                coreToken = pair0 ? delta1 : delta0;
                assertEq(fee, 12500);
                assertEq(logs[i].topics[1], PoolId.unwrap(key.toId()));
                swapEvents++;
            }
            if (logs[i].topics[0] == keccak256("Donate(bytes32,address,uint256,uint256)")) {
                (uint256 amount0, uint256 amount1) = abi.decode(logs[i].data, (uint256, uint256));
                donated += pair0 ? amount0 : amount1;
                assertEq(pair0 ? amount1 : amount0, 0);
                assertEq(logs[i].topics[1], PoolId.unwrap(key.toId()));
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(hook));
                donationEvents++;
            }
        }
        uint256 elapsed = block.number - openingBlock;
        uint256 rate = elapsed < 10 ? 300_000 - 30_000 * elapsed : 0;
        uint256 expected;
        if (buy && exactInput) expected = amount * rate / D;
        if (buy && !exactInput) expected = uint256(-corePair) * rate / (D - rate);
        if (!buy && exactInput) expected = uint256(corePair) * rate / D;
        if (!buy && !exactInput) expected = amount * rate / (D - rate);
        assertEq(swapEvents, 1);
        assertEq(donationEvents, expected == 0 ? 0 : 1);
        assertEq(donated, expected);
        assertEq(_token(result), coreToken);
        assertEq(_pair(result), corePair - int256(expected));
        donations += donated;
    }

    function transferTokens(uint96 rawAmount, uint8 fromSeed, uint8 toSeed, bool delegated) public {
        address from = holders[fromSeed % 3];
        address to = holders[toSeed % 3];
        uint256 balance = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        uint256 amount = bound(rawAmount, 0, balance);
        if (delegated) {
            vm.prank(from);
            token.approve(address(this), amount);
            assertTrue(token.transferFrom(from, to, amount));
            assertEq(token.allowance(from, address(this)), 0);
        } else {
            vm.prank(from);
            assertTrue(token.transfer(to, amount));
        }
        assertEq(token.balanceOf(from), from == to ? balance : balance - amount);
        assertEq(token.balanceOf(to), from == to ? toBefore : toBefore + amount);
        transfers++;
    }

    function advance(uint8 blocksForward, uint16 secondsForward) public {
        // Independent clocks explore both protections and their expiry in either order.
        vm.roll(block.number + bound(blocksForward, 0, 3));
        vm.warp(block.timestamp + bound(secondsForward, 0, 900));
    }

    function changeLiquidity(uint96 rawAmount, bool adding) public {
        uint256 amount;
        if (adding) {
            uint256 maximum = 5_000_000 ether - extraLiquidity;
            uint256 available = token.balanceOf(address(this)) / 4;
            if (maximum > available) maximum = available;
            available = imd.balanceOf(address(this)) / 4;
            if (maximum > available) maximum = available;
            if (maximum > 1_000_000 ether) maximum = 1_000_000 ether;
            if (maximum == 0) return;
            amount = bound(rawAmount, 1, maximum);
            extraLiquidity += uint128(amount);
        } else {
            if (extraLiquidity == 0) return;
            amount = bound(rawAmount, 1, extraLiquidity);
            extraLiquidity -= uint128(amount);
        }
        _modify(adding ? int256(amount) : -int256(amount), bytes32(uint256(1)));
        positionChanges++;
    }

    function collectFees() public {
        _modify(0, bytes32(0));
        if (extraLiquidity != 0) _modify(0, bytes32(uint256(1)));
        collections++;
    }

    function _modify(int256 amount, bytes32 salt) internal {
        uint256 tokenBefore = token.balanceOf(address(this));
        uint256 imdBefore = imd.balanceOf(address(this));
        (BalanceDelta delta, BalanceDelta fees) =
            driver.liquidity(key, IPoolManager.ModifyLiquidityParams(LOWER, UPPER, amount, salt));
        assertGe(_pair(fees), 0);
        assertGe(_token(fees), 0);
        if (amount == 0) assertEq(BalanceDelta.unwrap(delta), BalanceDelta.unwrap(fees));
        _recordSettlement(delta, tokenBefore, imdBefore);
    }

    function rejectOverCap(uint96 rawExcess) public {
        if (block.timestamp >= openingTime + 3600) return;
        uint256 amount = CAP + bound(rawExcess, 1, CAP);
        (uint160 beforePrice, int24 beforeTick,,) = manager.getSlot0(key.toId());
        (uint256 beforeGrowth0, uint256 beforeGrowth1) = manager.getFeeGrowthGlobals(key.toId());
        vm.expectRevert(
            abi.encodeWithSignature(
                "WrappedError(address,bytes4,bytes,bytes)",
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(SIMDTESTHook.MaxBuyExceeded.selector, amount, CAP),
                abi.encodePacked(Hooks.HookCallFailed.selector)
            )
        );
        driver.swap(key, _params(true, int256(amount)));
        (uint160 afterPrice, int24 afterTick,,) = manager.getSlot0(key.toId());
        (uint256 afterGrowth0, uint256 afterGrowth1) = manager.getFeeGrowthGlobals(key.toId());
        assertEq(beforePrice, afterPrice);
        assertEq(beforeTick, afterTick);
        assertEq(beforeGrowth0, afterGrowth0);
        assertEq(beforeGrowth1, afterGrowth1);
        rejectedBuys++;
    }

    /// @dev Called only by afterInvariant, never targeted by the random sequence.
    function exitAllLiquidity() external {
        if (extraLiquidity != 0) {
            _modify(-int256(uint256(extraLiquidity)), bytes32(uint256(1)));
            extraLiquidity = 0;
        }
        _modify(-int256(uint256(baseLiquidity)), bytes32(0));
    }
}
