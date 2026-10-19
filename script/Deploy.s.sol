// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Migraine} from "../src/Migraine.sol";

/// @notice Deploys `Migraine` from environment variables, after checking the rate.
/// @dev Required env: TOKEN_A, TOKEN_B, VAULT_WALLET, RATE_NUMERATOR, RATE_DENOMINATOR and
///      EXPECTED_B_PER_A, the smallest-unit amount of tokenB that one whole tokenA must buy.
///      The rate is in smallest units, so it carries any decimals difference. Example: a
///      6-decimal tokenA to an 18-decimal tokenB at 2.5 tokenB per tokenA:
///        RATE_NUMERATOR=2500000000000 RATE_DENOMINATOR=1 EXPECTED_B_PER_A=2500000000000000000
///      The script refuses to broadcast if the rate does not give EXPECTED_B_PER_A, because a
///      deployed rate can never be changed.
contract Deploy is Script {
    function run() external returns (Migraine redeemer) {
        return deploy(
            vm.envAddress("TOKEN_A"),
            vm.envAddress("TOKEN_B"),
            vm.envAddress("VAULT_WALLET"),
            vm.envUint("RATE_NUMERATOR"),
            vm.envUint("RATE_DENOMINATOR"),
            vm.envUint("EXPECTED_B_PER_A")
        );
    }

    /// @notice Checks the rate, deploys, and checks the deployed contract again.
    function deploy(address tokenA, address tokenB, address wallet, uint256 num, uint256 den, uint256 expectedBPerA)
        public
        returns (Migraine redeemer)
    {
        require(tokenA.code.length > 0 && tokenB.code.length > 0, "Deploy: token without code");
        uint8 decimalsA = IERC20Metadata(tokenA).decimals();
        uint8 decimalsB = IERC20Metadata(tokenB).decimals();
        uint256 oneA = 10 ** decimalsA;
        require(Math.mulDiv(oneA, num, den) == expectedBPerA, "Deploy: rate does not match EXPECTED_B_PER_A");

        console.log("tokenA decimals", decimalsA);
        console.log("tokenB decimals", decimalsB);
        console.log("one tokenA buys (tokenB smallest units)", expectedBPerA);

        vm.startBroadcast();
        redeemer = new Migraine(IERC20(tokenA), IERC20(tokenB), wallet, num, den);
        vm.stopBroadcast();

        require(redeemer.previewRedeem(oneA) == expectedBPerA, "Deploy: deployed rate mismatch");
    }
}
