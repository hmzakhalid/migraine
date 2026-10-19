// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Migraine} from "../src/Migraine.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Drives random redemptions and records ghost totals for the invariant test.
contract MigraineHandler is Test {
    Migraine public immutable redeemer;
    MockERC20 public immutable tokenA;
    MockERC20 public immutable tokenB;
    address public immutable vault;
    uint256 public immutable rateNum;
    uint256 public immutable rateDen;

    address[] public actors;

    uint256 public ghostTotalAIn;
    uint256 public ghostTotalBOut;
    uint256 public ghostInjectedB;
    uint256 public ghostRedemptions;

    constructor(Migraine redeemer_, MockERC20 tokenA_, MockERC20 tokenB_, address vault_, uint256 num, uint256 den) {
        redeemer = redeemer_;
        tokenA = tokenA_;
        tokenB = tokenB_;
        vault = vault_;
        rateNum = num;
        rateDen = den;
        actors.push(makeAddr("actor0"));
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
    }

    function redeem(uint256 actorSeed, uint256 amountA) external {
        _perform(actors[bound(actorSeed, 0, actors.length - 1)], amountA, address(0), false);
    }

    function redeemTo(uint256 actorSeed, uint256 amountA, uint256 recipientSeed) external {
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        address recipient = actors[bound(recipientSeed, 0, actors.length - 1)];
        _perform(actor, amountA, recipient, true);
    }

    function _perform(address actor, uint256 amountA, address recipient, bool useRedeemTo) internal {
        amountA = bound(amountA, 1, 1_000e18);

        uint256 balA = tokenA.balanceOf(actor);
        if (balA < amountA) {
            tokenA.mint(actor, amountA - balA);
        }
        vm.prank(actor);
        tokenA.approve(address(redeemer), type(uint256).max);

        uint256 needB = Math.mulDiv(amountA, rateNum, rateDen);
        if (needB == 0) {
            return;
        }

        uint256 balB = tokenB.balanceOf(vault);
        if (balB < needB) {
            tokenB.mint(vault, needB - balB);
            ghostInjectedB += needB - balB;
        }
        vm.prank(vault);
        tokenB.approve(address(redeemer), type(uint256).max);

        // Every call here is funded and approved, so it must succeed and pay exactly needB.
        address to = useRedeemTo ? recipient : actor;
        uint256 recipientBefore = tokenB.balanceOf(to);
        vm.prank(actor);
        uint256 amountB = useRedeemTo ? redeemer.redeemTo(amountA, recipient) : redeemer.redeem(amountA);
        assertEq(amountB, needB, "payout differs from the fixed rate");
        assertEq(tokenB.balanceOf(to) - recipientBefore, needB, "recipient did not receive the payout");

        ghostTotalAIn += amountA;
        ghostTotalBOut += amountB;
        ghostRedemptions += 1;
    }
}

contract MigraineInvariantTest is Test {
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    address internal vault;
    Migraine internal redeemer;
    MigraineHandler internal handler;

    uint256 internal constant RATE_NUM = 3;
    uint256 internal constant RATE_DEN = 2;

    function setUp() public {
        tokenA = new MockERC20("Token A", "AAA", 18);
        tokenB = new MockERC20("Token B", "BBB", 18);
        vault = makeAddr("vault");

        redeemer = new Migraine(IERC20(address(tokenA)), IERC20(address(tokenB)), vault, RATE_NUM, RATE_DEN);

        handler = new MigraineHandler(redeemer, tokenA, tokenB, vault, RATE_NUM, RATE_DEN);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = MigraineHandler.redeem.selector;
        selectors[1] = MigraineHandler.redeemTo.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice Every handler call is funded and approved, so each invariant fails on any
    ///         revert (see the inline config), and the run must actually redeem something.
    function afterInvariant() public view {
        assertGt(handler.ghostRedemptions(), 0, "no redemption succeeded");
    }

    /// @notice The redeemer never holds tokenA or tokenB.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_NoCustody() public view {
        assertEq(tokenA.balanceOf(address(redeemer)), 0);
        assertEq(tokenB.balanceOf(address(redeemer)), 0);
    }

    /// @notice The vault's tokenA only ever grows, by exactly the redeemed amounts.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_VaultTokenAConservation() public view {
        assertEq(tokenA.balanceOf(vault), handler.ghostTotalAIn());
    }

    /// @notice The vault's tokenB only ever shrinks by exactly the paid-out amounts.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_VaultTokenBConservation() public view {
        assertEq(tokenB.balanceOf(vault), handler.ghostInjectedB() - handler.ghostTotalBOut());
    }

    /// @notice Cumulative payouts never exceed the fixed rate (rounding only favours the vault).
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_RateNeverFavoursRedeemer() public view {
        assertLe(handler.ghostTotalBOut() * RATE_DEN, handler.ghostTotalAIn() * RATE_NUM);
    }
}
