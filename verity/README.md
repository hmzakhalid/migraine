# Verity formalization — `Migraine`

This directory holds a [Verity](https://veritylang.com/) formal specification,
reference model and machine-checked proofs for a **model** of the `Migraine`
contract's rate arithmetic. The model is not the deployed contract: it fixes an
example rate (`25 / 10`), keeps two storage counters, multiplies in 256 bits
(the Solidity contract uses 512-bit `Math.mulDiv`), and leaves out the token
transfers, the recipient and vault checks, and `sweep`. Those are covered by the
Foundry tests.
Verity is a Lean 4 EDSL that compiles smart contracts to EVM bytecode and ties
each implementation to a `Prop`-valued specification with a proof.

## Files

```
Contracts/Migraine/
  Migraine.lean     reference model (`verity_contract` block)
  Spec.lean                  formal specification (`redeem_spec`, `preview_spec`, ...)
  Invariants.lean            well-formedness invariant
  Proofs/Basic.lean          `redeem_meets_spec`, `preview_meets_spec`, ...
  Proofs/Correctness.lean    guard/revert behaviour, well-formedness
Contracts/Migraine.lean   module re-export
```

## What is proven

- `redeem_meets_spec` — every **successful** `redeem(amountA)`:
  - debits `remainingInventoryB` by exactly `payout amountA`
    (`= mulDivDown amountA rateNumerator rateDenominator`, i.e. the fixed rate,
    floored),
  - credits `totalRedeemedA` by exactly `amountA`,
  - leaves every other uint256 slot, all address storage, all mapping storage
    and the whole call context unchanged.
- `preview_meets_spec` — `preview(amountA)` returns exactly the fixed-rate
  payout.
- `redeem_debits_preview` — the amount debited from the inventory by `redeem` is
  exactly `preview(amountA)`; the two entrypoints cannot diverge.
- `redeem_reverts_zero_amount`, `redeem_reverts_zero_output`,
  `redeem_reverts_insufficient_inventory` — the guard conditions revert and do
  not mutate state in the model's checks-before-effects ordering.
- `redeem_preserves_wellformedness` — successful redemption preserves context
  well-formedness.

The rate is a pair of compile-time **constants**, mirroring the Solidity
`immutable` parameters: no proof obligation can change them, which is the Lean
statement of P6 (immutability).

## Correspondence to the Solidity contract and the trust boundary

The deployed Solidity contract is **stateless**: `redeem`/`redeemTo` perform two
external `transferFrom` calls (token A from caller to vault, token B from vault
to the recipient). Verity classifies external-call mechanics (`call`/`staticcall`,
returndata plumbing, ECMs) and bytecode immutables as an explicit **trust
boundary** rather than a fully proof-modelled fragment (see the Verity
*Capabilities & Limits* and *Trust Model* pages). To keep the verified surface
meaningful we therefore model the redeemer's *accounting core*:

| Solidity reality | Verity model |
| --- | --- |
| Vault's `tokenB` allowance to the redeemer | `remainingInventoryB` (slot 0) |
| Vault's accumulated `tokenA` balance | `totalRedeemedA` (slot 1) |
| Immutable `rateNumerator` / `rateDenominator` | constants |
| `redeem` / `redeemTo` (recipient selection) | out of scope (same accounting) |
| Two `safeTransferFrom` calls | out of scope (trust boundary) |

`redeemTo` shares the identical accounting as `redeem` and only changes the
`tokenB` recipient, so it needs no separate model. Because the contract holds no
mutable state, no reentrancy guard is used (or modelled); a reentrant token can
only produce additional independent redemptions.

The theorem therefore establishes the fixed-rate arithmetic and the
conservation/accounting semantics — properties P1 (rate correctness), P5
(conservation) and P6 (immutability) from `SPEC.md`. Properties P3 (atomicity),
P4 (no custody) and P7 (reentrancy-harmless) are guaranteed by the Solidity
construction and exercised by the Foundry test suite; P2 (one-way) follows from
the absence of any reverse entrypoint.

## Build it inside a Verity checkout

Clone Verity and copy these files in:

```bash
git clone https://github.com/lfglabs-dev/verity.git
cp -r verity/Contracts/Migraine      verity/Contracts/
cp    verity/Contracts/Migraine.lean verity/Contracts/
```

Then register the module (three one-line edits):

1. `lakefile.lean` — add to the `Contracts` library globs:
   ```lean
   .andSubmodules `Contracts.Migraine,
   ```
2. `Contracts.lean` — add:
   ```lean
   import Contracts.Migraine
   ```
3. `Contracts/Specs.lean` — add the import and the generated compiler model:
   ```lean
   import Contracts.Migraine
   -- ...
   def allSpecs : List CompilationModel := [
     -- ...
     Contracts.Migraine.spec,
     -- ...
   ]
   ```

Then verify the proofs and compile the artifact:

```bash
lake build Contracts.Migraine.Proofs.Correctness
lake exe verity-compiler --manifest migraine.manifest -o artifacts/yul
grep -r "sorry" Contracts/Migraine/   # should be empty
```

where `migraine.manifest` contains one line:

```
Contracts.Migraine.Migraine
```

This repository was verified against Verity `leanprover/lean4:v4.31.0`: the
whole `Contracts` library builds successfully and the compiler emits
[`artifacts/Migraine.yul`](./artifacts/Migraine.yul). The
generated runtime performs the guards and the fixed-rate math exactly as
specified, e.g. `amountB := div(mul(amountA, 25), 10)`.

> The first `lake build` downloads the pinned Lean toolchain and Mathlib and can
> take 20–45 minutes; subsequent builds are incremental.

## Trust report

Because the reference model emits no external calls, it stays inside the proved
fragment. The *deployed* contract's external calls should be tracked with
`verity-compiler --trust-report` when compiling the full Solidity-equivalent
model; the accounting semantics here carry no `sorry` and no project-level
axioms.
