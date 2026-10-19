// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Migraine
/// @notice One-way, fixed-rate, permissionless redemption of `tokenA` for `tokenB`.
/// @dev A redemption never routes tokens through this contract: `tokenA` is pulled from
///      the caller straight into a separate vault wallet, and `tokenB` is pushed from
///      that wallet straight to a chosen recipient. The vault wallet must approve this
///      contract for `tokenB` (that allowance caps further payouts, and setting it to 0
///      stops redemptions), and callers must approve it for `tokenA`. All configuration
///      is immutable.
///
///      Tokens sent to this contract directly (by mistake) can be moved on to the vault
///      wallet by anyone with `sweep`.
///
///      The contract is stateless: `redeem`/`redeemTo` only read immutables and
///      perform two external transfers, so there is no partially-updated state for a
///      reentrant token to observe or corrupt, and no reentrancy guard is needed.
contract Migraine {
    using SafeERC20 for IERC20;

    /// @notice Token users give up. Pulled from the caller to the vault wallet.
    IERC20 public immutable tokenA;

    /// @notice Token users receive. Pulled from the vault wallet to the recipient.
    IERC20 public immutable tokenB;

    /// @notice Vault wallet (e.g. a Gnosis Safe) holding `tokenB` and receiving `tokenA`.
    address public immutable wallet;

    /// @notice Numerator of the fixed rate: `amountB = amountA * rateNumerator / rateDenominator`.
    uint256 public immutable rateNumerator;

    /// @notice Denominator of the fixed rate. Must be non-zero.
    uint256 public immutable rateDenominator;

    /// @notice Emitted on every successful redemption.
    /// @param redeemer Caller that supplied `tokenA`.
    /// @param recipient Address that received `tokenB`.
    /// @param amountA Amount of `tokenA` paid by the caller.
    /// @param amountB Amount of `tokenB` received by the recipient.
    event Redeemed(address indexed redeemer, address indexed recipient, uint256 amountA, uint256 amountB);

    /// @notice Emitted when tokens held by this contract are moved to the vault wallet.
    /// @param token Token that was swept.
    /// @param amount Amount moved to the vault wallet.
    event Swept(IERC20 indexed token, uint256 amount);

    /// @notice A required address was the zero address.
    error ZeroAddress();
    /// @notice `tokenA` and `tokenB` were the same address.
    error IdenticalTokens();
    /// @notice The vault wallet was the zero address.
    error ZeroWallet();
    /// @notice The vault wallet was this contract, which would violate the no-custody rule.
    error WalletIsSelf();
    /// @notice The vault wallet was one of the tokens.
    error InvalidWallet();
    /// @notice A rate component was zero.
    error InvalidRate();
    /// @notice Redemption amount was zero.
    error ZeroAmount();
    /// @notice The computed payout rounded down to zero.
    error ZeroOutput();
    /// @notice The recipient was the zero address, this contract, a token, or the vault wallet.
    error InvalidRecipient(address to);
    /// @notice The vault wallet tried to redeem against itself.
    error VaultCannotRedeem();

    /// @param tokenA_ Token given by users. Must be non-zero and distinct from `tokenB_`.
    /// @param tokenB_ Token received by users. Must be non-zero and distinct from `tokenA_`.
    /// @param wallet_ Vault wallet. Must be non-zero, not this contract, and not a token.
    /// @param rateNumerator_ Non-zero numerator of the fixed rate.
    /// @param rateDenominator_ Non-zero denominator of the fixed rate.
    constructor(IERC20 tokenA_, IERC20 tokenB_, address wallet_, uint256 rateNumerator_, uint256 rateDenominator_) {
        if (address(tokenA_) == address(0) || address(tokenB_) == address(0)) revert ZeroAddress();
        if (address(tokenA_) == address(tokenB_)) revert IdenticalTokens();
        if (wallet_ == address(0)) revert ZeroWallet();
        if (wallet_ == address(this)) revert WalletIsSelf();
        if (wallet_ == address(tokenA_) || wallet_ == address(tokenB_)) revert InvalidWallet();
        if (rateNumerator_ == 0 || rateDenominator_ == 0) revert InvalidRate();

        tokenA = tokenA_;
        tokenB = tokenB_;
        wallet = wallet_;
        rateNumerator = rateNumerator_;
        rateDenominator = rateDenominator_;
    }

    /// @notice Preview the `tokenB` payout for a given `tokenA` input.
    /// @dev Uses full 512-bit intermediate precision and rounds down. Returns 0 for
    ///      inputs that `redeem` would reject (`amountA == 0`, or a payout that rounds
    ///      to zero); `redeem` reverts in those cases while this view does not. Like
    ///      `redeem`, it reverts if the payout does not fit in 256 bits.
    /// @param amountA Amount of `tokenA` to redeem.
    /// @return amountB Amount of `tokenB` that `redeem(amountA)` would pay.
    function previewRedeem(uint256 amountA) public view returns (uint256 amountB) {
        amountB = Math.mulDiv(amountA, rateNumerator, rateDenominator);
    }

    /// @notice Redeem `amountA` of `tokenA` for `tokenB`, sending `tokenB` to the caller.
    /// @param amountA Amount of `tokenA` to redeem.
    /// @return amountB Amount of `tokenB` paid out.
    function redeem(uint256 amountA) external returns (uint256 amountB) {
        return redeemTo(amountA, msg.sender);
    }

    /// @notice Redeem `amountA` of `tokenA` for `tokenB`, sending `tokenB` to `to`.
    /// @dev Pulls `tokenA` from `msg.sender` into `wallet`, then pushes `tokenB` from
    ///      `wallet` to `to`. Atomic: both transfers succeed or the call reverts.
    /// @param amountA Amount of `tokenA` to redeem.
    /// @param to Recipient of `tokenB`. Must not be the zero address, this contract,
    ///        `tokenA`, `tokenB`, or `wallet`.
    /// @return amountB Amount of `tokenB` paid out.
    function redeemTo(uint256 amountA, address to) public returns (uint256 amountB) {
        // The vault would pay itself in tokenA, so tokenB would leave without a payment.
        if (msg.sender == wallet) revert VaultCannotRedeem();
        if (amountA == 0) revert ZeroAmount();

        amountB = Math.mulDiv(amountA, rateNumerator, rateDenominator);
        if (amountB == 0) revert ZeroOutput();

        if (to == address(0) || to == address(this) || to == address(tokenA) || to == address(tokenB) || to == wallet) {
            revert InvalidRecipient(to);
        }

        // Emitted before the external calls (checks-effects-interactions). The contract is
        // stateless, so a reentrant token can neither reorder a false success log nor
        // corrupt state; a revert discards the log regardless.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Redeemed(msg.sender, to, amountA, amountB);

        // 1. Move tokenA from the redeemer into the vault wallet.
        tokenA.safeTransferFrom(msg.sender, wallet, amountA);

        // 2. Move tokenB from the vault wallet to the recipient. The `from` address is
        // the immutable, deployment-fixed vault wallet, not an attacker-controlled
        // parameter; the spendable amount is bounded by the ERC-20 allowance the vault
        // wallet itself has granted this contract.
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        tokenB.safeTransferFrom(wallet, to, amountB);
    }

    /// @notice Move this contract's whole balance of `token` to the vault wallet.
    /// @dev Redemptions never leave tokens here, so any balance was sent by mistake.
    ///      Anyone may call this; the destination is always the immutable vault wallet,
    ///      which can return the tokens to their sender.
    /// @param token Token to sweep.
    /// @return amount Amount moved to the vault wallet.
    function sweep(IERC20 token) external returns (uint256 amount) {
        amount = token.balanceOf(address(this));
        if (amount == 0) return 0;
        emit Swept(token, amount);
        token.safeTransfer(wallet, amount);
    }
}
