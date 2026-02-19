# Airbase Language Reference

> *"Nothing is allowed unless it is proven legitimate."*

Airbase is a programming language built on top of Nim using its macro system.
It flips the default assumption of most languages: **everything must earn the right to exist**.

---

## The Five Axioms

### 1. Legitimacy Before Execution
Code is a *proposal*, not an action. An Airbase program is a claim about behavior.
The compiler decides whether the claim is lawful. If it cannot decide, it rejects the program
or forces explicit acknowledgement. There is no silent uncertainty.

### 2. Meaning Over Mechanism
Airbase cares about *what must be true*, *what may never be true*, and *what is observable* —
not about how loops work or how memory is laid out. Mechanism is an implementation detail.
This is why Nim is the host language: Airbase expresses meaning, Nim compiles it to nothing.

### 3. Illegal States Are Syntactically Impossible
If something is illegal in Airbase, it either does not parse, does not macro-expand,
or does not type-check. You cannot accidentally write nonsense. The compiler is your
air traffic controller.

### 4. Time, State, and Observation Are Explicit
Airbase rejects hidden mutation, invisible time, and implicit effects.
State transitions are named. Time advances only when declared. Observation is marked.
Nothing "just happens."

### 5. Power Must Pay Rent
Airbase does not ban branching, looping, allocation, or I/O.
It prices them. Each requires a declaration, a scope, and a reason.
No free complexity.

---

## Setup

```nim
# Install:
# nim c -r yourprogram.nim

# Import everything:
import airbase
```

---

## Language Constructs

### `airspace` — The Program Container

Every Airbase program lives inside an `airspace`. Nothing is valid outside it.

```nim
airspace MyProgram:
  rule "no hidden mutation"
  rule "time is explicit"

  # ... all code goes here
```

### `rule` — Declare Program Rules

Rules are declarations of intent. They are enforced by the constructs that follow them.

```nim
rule "balance is always non-negative"
rule "state transitions are named"
```

---

### `claim` / `unproven` — Propositions About Values

A `claim` is a value paired with a proof of legitimacy. An `unproven` value
cannot be used until acknowledged or proven.

```nim
let x = claim(42, "positive integer constant")
let y = unproven(computeResult())

# Acknowledge uncertainty — pays rent
y.acknowledge("result is bounded by input contract")

# Use only when legitimate
when_legitimate(x):
  echo x.unwrap   # safe

# Or provide a fallback
let safe = legitimate_or(y, 0)
```

### `must` — Assert Invariants

If a `must` condition is false, the program is grounded immediately.

```nim
must(balance >= 0, "balance may not go negative")
must(conn.state == "ESTABLISHED", "must be connected to send")
```

### `never` — Forbidden States

`never` declares that a condition must never become true.

```nim
never(balance < 0, "no overdraft permitted")
never(password.len < 8, "passwords must be at least 8 characters")
```

### `grounded_if` — Halt on Condition

Halts the program immediately with a legitimacy violation if the condition holds.

```nim
grounded_if(amount > balance, "insufficient funds")
grounded_if(user == nil, "user must exist")
```

---

### `machine` — State Machine Declaration

Defines a named state machine. Illegal transitions cannot be made.

```nim
machine TrafficLight:
  states: Red, Yellow, Green
  initial: Red
  terminal: none

  transitions:
    Red    --[go]-->   Green
    Green  --[slow]--> Yellow
    Yellow --[stop]--> Red

  invariants:
    "exactly one signal active"
```

### `fly` — Request a Transition (Attempt a Flight)

Attempts a named transition. Rejected if no valid path exists from current state.

```nim
fly(TrafficLight, "go")     # Red → Green (permitted)
fly(TrafficLight, "stop")   # From Red? GROUNDED — no such transition
```

### `assert_state` — Verify Machine Position

```nim
assert_state(TrafficLight, "Red")
```

---

### `tick` — Advance Logical Time

Time never advances implicitly.

```nim
tick("end of round")
tick("simulation step", steps = 3)
```

### `emit_obs` — Mark an Observable

Observations are explicit. They are recorded in the audit log.

```nim
emit_obs("player.health", currentHP)
emit_obs("account.balance", account.balance)
```

---

### `declared_branch` — Pay for Branching

Every branch must be named and justified.

```nim
declared_branch("payment routing", reason = "different paths per method"):
  if method == "card": processCard()
  elif method == "cash": processCash()
  else: raiseError()
```

### `declared_loop` — Pay for Looping

Every loop must declare a bound or explicit reason.

```nim
# Bounded loop — enforces the limit at runtime
declared_loop("retry", bound = 5, reason = "max 5 retries"):
  while not success:
    attempt()
    checkBound()  # Call this inside the loop body

# Justified unbounded loop
declared_loop("event-processing", reason = "runs until queue is empty"):
  while queue.pendingCount > 0:
    processNext()
```

### `declare_power` — Declare Your Effect Budget

Explicitly declares what effects a scope will use.

```nim
declare_power([branch, loop(10), allocate], "game loop"):
  # code here
```

---

### Refinement Types

Values that structurally cannot violate their predicates.

```nim
let age   = positive(25)         # Refined[int]: must be > 0
let funds = nonNegative(1000)    # Refined[int]: must be >= 0
let pct   = percentage(87.5)     # Refined[float]: must be in [0, 100]
let prob  = probability(0.73)    # Refined[float]: must be in [0.0, 1.0]
let name  = nonEmptyStr("Alice") # Refined[string]: must not be empty

let raw = funds.extract          # Extract value (safe — it was proven)
```

### `BoundedInt` — Numeric Values With Hard Limits

```nim
let hp  = bounded(100, 0, 100)   # Value, min, max
let dmg = bounded(25, 0, 9999)

# Arithmetic preserves bounds — violation is caught immediately
let newHp = hp - dmg             # fine: 75 in [0, 100]
```

### `NonEmptySeq` — Sequences That May Never Be Empty

```nim
let items = nonEmpty("first", "second", "third")
let h = items.head    # always safe
```

---

### `invariant_zone` — Scope With Invariant Re-Check

A zone where invariants are verified when the block exits.

```nim
invariant_zone("account-mutation"):
  account.balance -= 100
  must(account.balance >= 0, "no overdraft")
```

### `sealed` — Declare Value Immutability

Documents and enforces that a value should not change.

```nim
let sessionKey = sealed(computeKey(), "session keys are immutable")
echo sessionKey.unwrap
```

---

### `contracted` Procedures

Use `pre`, `post`, and `frame` inside procedures for automatic contract checking.

```nim
proc transfer(src, dst: var Account, amount: int) =
  pre(amount > 0, "amount must be positive")
  pre(src.balance >= amount, "sufficient funds required")

  let total = src.balance + dst.balance
  frame(total, "total money is conserved")   # must not change on exit

  src.balance -= amount
  dst.balance += amount

  post(src.balance >= 0, "source not overdrawn")
  post(dst.balance >= src.balance, "destination increased")
```

---

### `check_suite` — Grouped Verification

```nim
check_suite "pre-flight checks":
  vc "fuel level ok": fuelLevel > 20
  vc "engine running": engineState == "running"
  vc "doors sealed": allDoorsClosed()
```

---

### `simulation` / `phase` — Structured Simulation

```nim
simulation "MyWorld":
  phase "setup":
    initWorld()
    tick("world ready")

  phase "main-loop":
    declared_loop("frames", bound = 60, reason = "1 second at 60fps"):
      updateEntities()
      tick("frame")
      checkBound()

  phase "teardown":
    cleanUp()
    tick("done")
```

---

### `certify` / `audit` — Issue and Print the Legitimacy Certificate

```nim
certify("MyProgram",
  axioms = @[
    "all state is explicit",
    "all loops are bounded",
    "all effects are declared"
  ],
  power = @[
    "branch: routing logic",
    "loop(10): main loop"
  ]
)

audit()   # prints emission log + certificate
```

---

### `EventQueue` — Explicit Event Passing

```nim
var queue = newEventQueue[MyEvent](maxSize = 100)
queue.enqueue("damage", evDamage, globalAirspace)

let evt = queue.dequeue()
if evt.isSome:
  handleEvent(evt.get.payload)
```

### `Reactive` — Values With Change Tracking

```nim
var score = reactive(0, "player.score")
score.update(100, globalAirspace)   # emits "player.score.changed"
echo score.current
```

### `Guarded` — Values Behind Access Conditions

```nim
var secret = guard("top-secret", "must be authenticated")
let val = secret.unlock(user.isAuthenticated, "user is logged in")
```

---

## Proof Terms

Explicit justification objects for formal reasoning.

```nim
let p1 = axiom("connection starts closed")
let p2 = byInduction("loop terminates", "each iteration decreases n")
let p3 = assume("input is validated upstream")  # weakest — requires acknowledgement

emit_obs("proof.loaded", $p1)
```

---

## The Legitimacy Certificate

Every valid Airbase program ends with a certificate:

```
=== AIRBASE LEGITIMACY CERTIFICATE ===
Program:  MyTrafficSystem
Verified: compile-time
Axioms satisfied:
  ✓ legitimacy-before-execution
  ✓ meaning-over-mechanism
  ✓ explicit-state-and-time
  ✓ power-pays-rent
Power declarations:
  ⚡ branch: signal routing
  ⚡ loop(6): signal-cycle
======================================
```

---

## Error Types

| Error | Meaning |
|-------|---------|
| `LegitimacyViolation` | Program cannot be proven lawful |
| `IllegalState` | A syntactically impossible state was reached |
| `UnprovenClaim` | An unverified value was used |
| `ImplicitEffect` | A hidden side effect was detected |
| `UnboundedPower` | Power was used without declaration |
| `TimeViolation` | Time advanced without a `tick` call |
| `ObservationViolation` | Observation occurred outside a marked scope |
| `ContractBreach` | A `must`, `never`, `pre`, or `post` was violated |

---

## Design Philosophy

Airbase is the air traffic authority. Your code is the aircraft.

- **Airbase defines the airspace** (rules, invariants)
- **States are aircraft positions** (current location in a state machine)
- **Transitions are flight permissions** (named, explicit moves)
- **Violations ground the craft before takeoff** (compile-time or load-time rejection)

A program that cannot be proven legitimate does not crash — **it simply never becomes a program.**
