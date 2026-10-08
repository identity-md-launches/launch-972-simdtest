// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SIMDTEST} from "../src/SIMDTEST.sol";

contract SIMDTESTTest is Test {
    SIMDTEST token;

    function setUp() public {
        token = new SIMDTEST();
    }

    function testMetadataSupplyAndTransfers() public {
        assertEq(token.name(), "SIMDTEST");
        assertEq(token.symbol(), "SIMDTEST");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
        address recipient = makeAddr("recipient");
        token.transfer(recipient, 20_000_000 ether);
        assertEq(token.balanceOf(recipient), 20_000_000 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function testAllowanceAndInsufficientBalanceFailures() public {
        address spender = makeAddr("spender");
        address recipient = makeAddr("recipient");
        token.approve(spender, 100 ether);
        vm.prank(spender);
        token.transferFrom(address(this), recipient, 100 ether);
        assertEq(token.allowance(address(this), spender), 0);
        vm.prank(spender);
        vm.expectRevert();
        token.transferFrom(address(this), recipient, 1);
        vm.prank(recipient);
        vm.expectRevert();
        token.transfer(spender, 101 ether);
    }

    function testNoAdministrativeOrMintEntryPoints() public {
        (bool minted,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        (bool paused,) = address(token).call(abi.encodeWithSignature("pause()"));
        (bool owner,) = address(token).call(abi.encodeWithSignature("owner()"));
        assertFalse(minted);
        assertFalse(paused);
        assertFalse(owner);
    }
}
