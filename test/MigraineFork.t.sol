// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {Migraine} from "../src/Migraine.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Redeems a real token (a plain ERC20) on a fork. Skipped unless FORK_RPC_URL,
///         FORK_TOKEN_A and FORK_HOLDER (an address holding at least one whole token) are set:
///         FORK_RPC_URL=... FORK_TOKEN_A=0x... FORK_HOLDER=0x... forge test --match-contract MigraineForkTest
contract MigraineForkTest is Test {
    Migraine internal redeemer;
    IERC20 internal tokenA;
    MockERC20 internal tokenB;
    address internal holder;
    address internal vault;
    uint256 internal oneA;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        tokenA = IERC20(vm.envAddress("FORK_TOKEN_A"));
        holder = vm.envAddress("FORK_HOLDER");
        oneA = 10 ** IERC20Metadata(address(tokenA)).decimals();
        vault = makeAddr("vault");
        tokenB = new MockERC20("Token B", "B", 18);
        // 2.5 tokenB per whole tokenA, whatever tokenA's decimals are.
        redeemer = new Migraine(tokenA, IERC20(address(tokenB)), vault, 2.5e18, oneA);
        tokenB.mint(vault, 1_000_000e18);
        vm.prank(vault);
        tokenB.approve(address(redeemer), type(uint256).max);
    }

    function test_RedeemsARealToken() public {
        assertGe(tokenA.balanceOf(holder), oneA, "holder has less than one token; pick another");

        vm.startPrank(holder);
        tokenA.approve(address(redeemer), oneA);
        uint256 paid = redeemer.redeem(oneA);
        vm.stopPrank();

        assertEq(paid, 2.5e18);
        assertEq(tokenB.balanceOf(holder), 2.5e18);
        assertEq(tokenA.balanceOf(vault), oneA);
        assertEq(tokenA.balanceOf(address(redeemer)), 0);
    }

    function test_SweepsARealTokenSentByMistake() public {
        vm.prank(holder);
        tokenA.transfer(address(redeemer), oneA);
        assertEq(redeemer.sweep(tokenA), oneA);
        assertEq(tokenA.balanceOf(vault), oneA);
    }
}
