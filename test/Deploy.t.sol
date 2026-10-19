// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "../script/Deploy.s.sol";
import {Migraine} from "../src/Migraine.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Tests call `deploy` with arguments; only one test sets environment variables, because
///      the environment is shared by tests that run in parallel.
contract DeployScriptTest is Test {
    MockERC20 internal six;
    MockERC20 internal eighteen;
    address internal vault;

    function setUp() public {
        six = new MockERC20("Six", "SIX", 6);
        eighteen = new MockERC20("Eighteen", "EIGHTEEN", 18);
        vault = makeAddr("vault");
    }

    function test_DeploysWhenTheRateMatches() public {
        // 2.5 tokenB per tokenA, with the 1e12 decimals factor in the numerator.
        Migraine redeemer = new Deploy().deploy(address(six), address(eighteen), vault, 2_500_000_000_000, 1, 2.5e18);
        assertEq(redeemer.previewRedeem(1e6), 2.5e18);
    }

    function test_RefusesARateWithoutTheDecimalsFactor() public {
        // 25 / 10 is 2.5 per smallest unit: the decimals factor is missing.
        Deploy script = new Deploy();
        vm.expectRevert(bytes("Deploy: rate does not match EXPECTED_B_PER_A"));
        script.deploy(address(six), address(eighteen), vault, 25, 10, 2.5e18);
    }

    function test_RunReadsTheEnvironment() public {
        vm.setEnv("TOKEN_A", vm.toString(address(six)));
        vm.setEnv("TOKEN_B", vm.toString(address(eighteen)));
        vm.setEnv("VAULT_WALLET", vm.toString(vault));
        vm.setEnv("RATE_NUMERATOR", "2500000000000");
        vm.setEnv("RATE_DENOMINATOR", "1");
        vm.setEnv("EXPECTED_B_PER_A", "2500000000000000000");
        Migraine redeemer = new Deploy().run();
        assertEq(redeemer.previewRedeem(1e6), 2.5e18);
        assertEq(redeemer.wallet(), vault);
    }
}
