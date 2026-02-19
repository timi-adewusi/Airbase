## example_bank.nim
## Example: Bank account system using Airbase.
## Demonstrates: claim, must, never, contracts, refinement types,
##               invariant_zone, sealed, grounded_if

import ../src/airbase

airspace BankSystem:

  rule "no overdraft is permitted"
  rule "account IDs are immutable after creation"
  rule "balance is always non-negative"
  rule "transfers are atomic — no partial state"

  # ─── Refined types enforce legitimacy structurally ───
  type Account = object
    id: NonEmptyString       ## id may never be empty
    balance: NonNegative     ## balance may never go negative
    owner: NonEmptyString
    frozen: bool

  proc newAccount(id, owner: string, initialDeposit: int): Account =
    pre(id.len > 0, "account id must be non-empty")
    pre(owner.len > 0, "owner name must be non-empty")
    pre(initialDeposit >= 0, "initial deposit cannot be negative")

    result = Account(
      id: nonEmptyStr(id),
      balance: nonNegative(initialDeposit),
      owner: nonEmptyStr(owner),
      frozen: false
    )
    post(result.balance.extract >= 0, "account balance is non-negative after creation")

  proc deposit(acc: var Account, amount: int) =
    pre(amount > 0, "deposit amount must be positive")
    pre(not acc.frozen, "cannot deposit to frozen account")

    invariant_zone("deposit-" & acc.id.extract):
      let newBal = acc.balance.extract + amount
      acc.balance = nonNegative(newBal)
      emit_obs("account.deposit", acc.id.extract & "+" & $amount)

    post(acc.balance.extract >= amount, "balance increased by deposit amount")

  proc withdraw(acc: var Account, amount: int) =
    pre(amount > 0, "withdrawal amount must be positive")
    pre(not acc.frozen, "cannot withdraw from frozen account")

    # This guard prevents the illegal state structurally
    grounded_if(amount > acc.balance.extract,
      "withdrawal exceeds balance — illegal state")

    invariant_zone("withdraw-" & acc.id.extract):
      let newBal = acc.balance.extract - amount
      acc.balance = nonNegative(newBal)  # Would error if negative
      emit_obs("account.withdraw", acc.id.extract & "-" & $amount)

    # Invariant always re-checked after mutation
    never(acc.balance.extract < 0, "balance went negative after withdrawal")

  proc transfer(src, dst: var Account, amount: int) =
    pre(amount > 0, "transfer amount must be positive")
    pre(src.id.extract != dst.id.extract, "cannot transfer to same account")
    pre(not src.frozen and not dst.frozen, "neither account may be frozen")

    grounded_if(amount > src.balance.extract, "insufficient funds for transfer")

    # Atomicity: record both sides in the same invariant zone
    invariant_zone("transfer"):
      let srcBefore = src.balance.extract
      let dstBefore = dst.balance.extract

      src.balance = nonNegative(srcBefore - amount)
      dst.balance = nonNegative(dstBefore + amount)

      # Total conservation invariant
      must(src.balance.extract + dst.balance.extract ==
           srcBefore + dstBefore,
           "money is conserved in transfer")

      emit_obs("account.transfer",
        src.id.extract & "->" & dst.id.extract & ":" & $amount)

  proc freeze(acc: var Account, reason: string) =
    let frozenId = sealed(acc.id.extract, "frozen account IDs are permanent")
    acc.frozen = true
    emit_obs("account.frozen", frozenId.unwrap & " reason=" & reason)

  # ─── Run a scenario ─────────────────────────────────
  declare_power([branch, allocate], "bank operations scenario"):

    var alice = newAccount("ACC-001", "Alice", 1000)
    var bob   = newAccount("ACC-002", "Bob",   500)

    tick("accounts created")

    # Claims about initial state
    let aliceBalanceClaim = claim(alice.balance.extract, "initial deposit was 1000")
    must(aliceBalanceClaim.unwrap == 1000, "Alice starts with 1000")

    deposit(alice, 200)
    tick("deposit processed")

    withdraw(bob, 100)
    tick("withdrawal processed")

    transfer(alice, bob, 300)
    tick("transfer processed")

    # Observations
    emit_obs("alice.final", alice.balance.extract)
    emit_obs("bob.final", bob.balance.extract)

    # Total preserved: alice 1000+200-300=900, bob 500-100+300=700 = 1600 total
    must(alice.balance.extract + bob.balance.extract == 1600,
         "total money is conserved across all operations")

    freeze(bob, "suspicious activity")

    # This would ground the program if uncommented:
    # withdraw(bob, 10)  # GROUNDED: frozen account

  certify("BankSystem",
    axioms = @[
      "balances are structurally non-negative (NonNegative type)",
      "transfers are atomic (invariant_zone)",
      "money is conserved (must-check after transfer)",
      "frozen accounts reject mutations (pre-condition)"
    ],
    power = @[
      "branch: bank operations scenario",
      "allocate: account creation"
    ]
  )

  audit()
