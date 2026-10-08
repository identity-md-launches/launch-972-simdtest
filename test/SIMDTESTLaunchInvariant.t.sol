// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {HookTestFixture} from "./SIMDTESTHook.t.sol";
import {LaunchHandler} from "./helpers/LaunchHandler.sol";

abstract contract LaunchInvariantBase is HookTestFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    LaunchHandler handler;

    function setUp() public override {
        super.setUp();
        handler = new LaunchHandler(manager, hook, driver, key, initialLiquidity);
        token.transfer(address(handler), token.balanceOf(address(this)));
        imd.transfer(address(handler), imd.balanceOf(address(this)));

        // Exercise each value-moving action before fuzzing so empty sequences are not a pass.
        handler.swap(1000 ether, true, true);
        handler.swap(1000 ether, true, false);
        handler.swap(1000 ether, false, true);
        handler.swap(1000 ether, false, false);
        handler.changeLiquidity(1000 ether, true);
        handler.rejectOverCap(1);
        handler.transferTokens(uint96(CAP * 2), 0, 1, false);
        handler.transferTokens(uint96(CAP * 2), 1, 0, true);
        handler.collectFees();

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = LaunchHandler.swap.selector;
        selectors[1] = LaunchHandler.transferTokens.selector;
        selectors[2] = LaunchHandler.advance.selector;
        selectors[3] = LaunchHandler.changeLiquidity.selector;
        selectors[4] = LaunchHandler.collectFees.selector;
        selectors[5] = LaunchHandler.rejectOverCap.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_ConservationSettlementAndImmutableLaunchRules() public view {
        _assertConservation();
        _assertSettled();
        assertEq(manager.currencyDelta(address(driver), key.currency0), 0);
        assertEq(manager.currencyDelta(address(driver), key.currency1), 0);
        assertEq(manager.currencyDelta(address(handler), key.currency0), 0);
        assertEq(manager.currencyDelta(address(handler), key.currency1), 0);
        assertEq(token.balanceOf(address(driver)), 0);
        assertEq(imd.balanceOf(address(driver)), 0);
        assertEq(manager.balanceOf(address(driver), uint160(address(token))), 0);
        assertEq(manager.balanceOf(address(driver), uint160(IMD)), 0);

        assertTrue(hook.opened());
        assertEq(hook.openingBlock(), openedAtBlock);
        assertEq(hook.openingTimestamp(), openedAtTime);
        uint256 elapsed = block.number - openedAtBlock;
        assertEq(hook.antiSnipeFee(), elapsed < 10 ? 300_000 - elapsed * 30_000 : 0);
        (,,, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(lpFee, 12500);
        assertEq(manager.getLiquidity(key.toId()), uint256(initialLiquidity) + handler.extraLiquidity());
        (uint128 basePosition,,) = manager.getPositionInfo(key.toId(), address(driver), LOWER, UPPER, bytes32(0));
        (uint128 extraPosition,,) =
            manager.getPositionInfo(key.toId(), address(driver), LOWER, UPPER, bytes32(uint256(1)));
        assertEq(basePosition, initialLiquidity);
        assertEq(extraPosition, handler.extraLiquidity());
        assertGe(handler.swaps(), 4);
        assertGt(handler.donations(), 0);
        assertGt(handler.rejectedBuys(), 0);
        assertGt(handler.collections(), 0);
    }

    function _assertConservation() internal view {
        uint256 tokenSum = token.balanceOf(address(manager)) + token.balanceOf(address(this));
        uint256 imdSum = imd.balanceOf(address(manager)) + imd.balanceOf(address(this));
        for (uint256 i; i < 3; i++) {
            tokenSum += token.balanceOf(handler.holders(i));
            imdSum += imd.balanceOf(handler.holders(i));
        }
        assertEq(token.totalSupply(), SUPPLY, "fixed supply changed");
        assertEq(imd.totalSupply(), SUPPLY * 3, "fixture must not mint during sequences");
        assertEq(tokenSum, SUPPLY, "tokens burned, taxed or sent outside tracked holders");
        assertEq(imdSum, SUPPLY * 3, "IMD removed from the system");
        assertEq(token.balanceOf(address(manager)), handler.expectedPoolToken());
        assertEq(imd.balanceOf(address(manager)), handler.expectedPoolIMD());
    }

    function afterInvariant() public {
        handler.exitAllLiquidity();
        assertEq(manager.getLiquidity(key.toId()), 0);
        // With both LP positions redeemed, only per-operation integer rounding dust may remain.
        // This bound covers two positions, principal rounding and fee-growth rounding in each currency.
        uint256 dustBound = 8 * handler.operations() + 16;
        assertLe(token.balanceOf(address(manager)), dustBound, "token principal or LP fees stranded");
        assertLe(imd.balanceOf(address(manager)), dustBound, "IMD principal or donations stranded");
        _assertConservation();
        _assertSettled();
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SIMDTESTLaunchPair0Invariant is LaunchInvariantBase {
    function _pair0() internal pure override returns (bool) {
        return true;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SIMDTESTLaunchPair1Invariant is LaunchInvariantBase {
    function _pair0() internal pure override returns (bool) {
        return false;
    }
}
