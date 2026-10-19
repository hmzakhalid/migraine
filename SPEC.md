# Plain-Language Specification — `Migraine`

## 1. Purpose

`Migraine` is a small, immutable, trust-minimised smart contract that
lets **anyone** exchange one ERC-20 token (`tokenA`) for another (`tokenB`) at a
**fixed rate**, in exactly **one direction**. The token being received by users
(`tokenB`) does **not** live in the redeemer contract; it lives in a separate
**vault wallet** (e.g. a Gnosis Safe). The redeemer contract is a pure
orchestrator: it never custodies tokens, not even for a single block.

## 2. Actors

| Actor | Description |
| --- | --- |
| **Redeemer (user)** | Any address. Holds `tokenA`, wants `tokenB`. Must approve `Migraine` to pull `tokenA`. |
| **Vault wallet** | A separate contract account (e.g. Gnosis Safe) that holds the `tokenB` inventory and receives all `tokenA`. Must approve `Migraine` to pull `tokenB`. |
| **`Migraine`** | This contract. Holds no tokens at any point. Immutable parameters. No owner, no admin, no pause. |

## 3. Configuration (set once at deployment, immutable forever)

| Parameter | Meaning |
| --- | --- |
| `tokenA` | The ERC-20 users give. |
| `tokenB` | The ERC-20 users receive. |
| `wallet` | The vault wallet address that holds `tokenB` and receives `tokenA`. Must not be `tokenA`, `tokenB`, the zero address, or the redeemer itself. |
| `rateNumerator` | Numerator of the fixed exchange rate. Non-zero. |
| `rateDenominator` | Denominator of the fixed exchange rate. Non-zero. |

The exchange rate is `rateNumerator / rateDenominator`, interpreted in the
**smallest units** of each token:

```
amountB = floor(amountA * rateNumerator / rateDenominator)
```

For example, to exchange at 1 `tokenA` = 2.5 `tokenB` where both tokens have 18
decimals, use `rateNumerator = 25`, `rateDenominator = 10`.

## 4. Functional requirements

### FR-1 — Redeem (to self)
`redeem(uint256 amountA) external returns (uint256 amountB)`

Equivalent to `redeemTo(amountA, msg.sender)`: redeems `amountA` of `tokenA` and
sends the resulting `tokenB` to the caller.

### FR-2 — Redeem to a recipient
`redeemTo(uint256 amountA, address to) public returns (uint256 amountB)`

When called:

0. Revert if `msg.sender` is the vault wallet: the vault would pay itself in
   `tokenA`, so `tokenB` would leave without a payment.
1. Revert if `amountA == 0`.
2. Compute `amountB = floor(amountA * rateNumerator / rateDenominator)`.
3. Revert if `amountB == 0` (dust that would produce nothing).
4. Revert if `to` is `address(0)`, this contract, `tokenA`, `tokenB`, or `wallet`.
5. Emit `Redeemed(msg.sender, to, amountA, amountB)`.
6. Transfer exactly `amountA` of `tokenA` **from the caller to the vault wallet**.
7. Transfer exactly `amountB` of `tokenB` **from the vault wallet to `to`**.

The two transfers are atomic: either both succeed or the whole transaction
reverts, so a caller can never give `tokenA` without the recipient receiving
`tokenB`. `tokenA` is always pulled from `msg.sender`; only the `tokenB`
recipient is configurable.

### FR-3 — Preview
`previewRedeem(uint256 amountA) view returns (uint256 amountB)`

Return exactly the `amountB` that `redeem`/`redeemTo` would pay, using the same
full-precision, floor-rounded formula. This is a pure read used by the UI. It
returns `0` for inputs that `redeem`/`redeemTo` reject (`amountA == 0`, or a
payout that rounds to zero). Like `redeem`, it reverts only when the payout does
not fit in 256 bits.

### FR-4 — One-way only
There is **no** function anywhere in the contract that exchanges `tokenB` back
for `tokenA`, and no way to change the direction, the rate, the tokens, or the
wallet after deployment. The only state-changing methods are `redeem`,
`redeemTo` and `sweep`; `sweep` only moves this contract's own balance to the
vault wallet.

### FR-5 — No custody
A redemption never routes tokens through the contract: it moves `tokenA` directly
from the caller to the vault wallet and `tokenB` directly from the vault wallet to
the recipient. `to == address(this)` is rejected, so a redemption can never
strand `tokenB` here. A plain ERC-20 transfer to the contract's address cannot be
blocked; `sweep` (FR-6) moves such tokens on.

### FR-6 — Sweep
`sweep(IERC20 token) external returns (uint256 amount)`

Move this contract's whole balance of `token` to the vault wallet and emit
`Swept(token, amount)`. Anyone may call it; the destination is always the
immutable vault wallet, which can return the tokens to whoever sent them by
mistake. With a zero balance it returns `0` and emits nothing.

## 5. Preconditions and revert conditions

| Condition | Result |
| --- | --- |
| `msg.sender` is the vault wallet | Revert `VaultCannotRedeem()` |
| `amountA == 0` | Revert `ZeroAmount()` |
| `amountB == 0` after rounding | Revert `ZeroOutput()` |
| `to` is zero, this contract, a token, or the wallet | Revert `InvalidRecipient(to)` |
| Caller has not approved `tokenA` (or insufficient allowance/balance) | Revert (via `SafeERC20`, propagated) |
| Vault wallet has not approved `tokenB` (or insufficient allowance) | Revert (via `SafeERC20`, propagated) |
| Vault wallet holds less `tokenB` than `amountB` | Revert (via `SafeERC20`, propagated) |
| Payout does not fit in 256 bits | Revert (`Math.mulDiv`) |

Reentrancy: the contract holds no mutable state, so a reentrant token can only
trigger additional, independent redemptions — each bounded by the same
allowances and balances — and cannot corrupt state or extract value. There is
deliberately **no** reentrancy guard. The event is emitted before the external
calls (checks-effects-interactions); an event is never a false success signal
because a revert discards it.


## 6. Constructor validation

Deployment reverts if any of the following hold:

- `tokenA == address(0)` or `tokenB == address(0)` → `ZeroAddress()`
- `tokenA == tokenB` → `IdenticalTokens()`
- `wallet == address(0)` → `ZeroWallet()`
- `wallet == address(this)` → `WalletIsSelf()` (would break the no-custody rule)
- `wallet == tokenA` or `wallet == tokenB` → `InvalidWallet()`
- `rateNumerator == 0` or `rateDenominator == 0` → `InvalidRate()`

## 7. Safety properties (desired invariants)

These are the properties the tests target. The Verity model (see
`verity/README.md`) proves P1, P5 and P6 for a model of the rate arithmetic, not
for the deployed bytecode.

- **P1 (Rate correctness).** For every successful `redeem`/`redeemTo(amountA, …)`,
  the recipient receives exactly `floor(amountA * rateNumerator / rateDenominator)`
  of `tokenB`.
- **P2 (Direction / no reverse).** No reachable code path lets any caller obtain
  `tokenA` from the vault wallet, nor exchange `tokenB` for `tokenA`.
- **P3 (Atomicity / no free lunch).** A recipient cannot receive `tokenB` unless
  `msg.sender`, who is never the vault wallet, pays `amountA` of `tokenA`; the two
  transfers commit together or not at all.
- **P4 (No custody).** A redemption leaves `tokenA.balanceOf(redeemer)` and
  `tokenB.balanceOf(redeemer)` unchanged, for every valid `to`; tokens sent to the
  contract directly can only leave through `sweep`, to the vault wallet.
- **P5 (Conservation).** Summed across all successful redemptions, the `tokenA`
  credited to the vault wallet equals the `amountA` values supplied by callers,
  and the `tokenB` debited from the vault wallet equals the corresponding
  `amountB` values.
- **P6 (Immutability).** After construction, `tokenA`, `tokenB`, `wallet`,
  `rateNumerator`, `rateDenominator` cannot change.
- **P7 (Reentrancy-harmless).** The contract is stateless, so a reentrant token
  cannot corrupt state or extract value; any nested redemption is independent and
  bounded by the same allowances/balances. No guard is used.

## 8. Explicit non-goals / assumptions

- **Standard ERC-20s.** The contract assumes tokens that transfer exactly the
  requested amount (no fee-on-transfer, no rebasing). Fee-on-transfer tokens
  would break exact-amount accounting; they are out of scope.
- **Inventory funding is operational, not on-chain.** "Enough `tokenB` to cover
  the entire `tokenA` supply" is guaranteed by (a) funding the vault wallet and
  (b) the vault wallet's ERC-20 allowance to the redeemer. The allowance is the
  effective on-chain cap: the redeemer can never pay out more `tokenB` than the
  vault wallet has approved.
- **No owner, no pause, no upgrades.** Deliberately immutable and
  permissionless; there is no privileged role to compromise.
- **Rounding favours the vault.** `amountB` is rounded down, so dust accrues to
  the vault wallet, never to the redeemer.

## 9. Interface summary

```
constructor(address tokenA, address tokenB, address wallet,
            uint256 rateNumerator, uint256 rateDenominator)

function redeem(uint256 amountA) external returns (uint256 amountB)
function redeemTo(uint256 amountA, address to) public returns (uint256 amountB)
function previewRedeem(uint256 amountA) external view returns (uint256 amountB)

// immutable public getters
function tokenA() external view returns (address)
function tokenB() external view returns (address)
function wallet() external view returns (address)
function rateNumerator() external view returns (uint256)
function rateDenominator() external view returns (uint256)

event Redeemed(address indexed redeemer, address indexed recipient,
               uint256 amountA, uint256 amountB)
```
