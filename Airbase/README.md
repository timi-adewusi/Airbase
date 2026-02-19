# Airbase Language

> *"Nothing is allowed unless it is proven legitimate."*

Airbase is a programming language embedded in [Nim](https://nim-lang.org) via macros. It implements a legitimacy-first paradigm: programs do not *run* — they are *allowed to exist*. Every state, transition, and effect must be explicitly declared and proven lawful before execution.

---

## Philosophy

| Most Languages | Airbase |
|---|---|
| Anything is allowed unless it fails at runtime | Nothing is allowed unless it is proven legitimate |
| Programs run and may crash | Programs are claims; the compiler decides if the claim is lawful |
| Hidden mutation, invisible time | State transitions are named; time advances only when declared |
| Power is free | Power must pay rent: declare scope, declare reason |

### The Five Axioms

1. **Legitimacy before execution** — Code is a proposal, not an action.
2. **Meaning over mechanism** — Airbase cares about *what must be true*, not *how loops work*.
3. **Illegal states are syntactically impossible** — If something is illegal, it should not parse, expand, or type-check.
4. **Time, state, and observation are explicit** — Nothing just happens.
5. **Power must pay rent** — Every capability requires a declaration, a scope, and a reason.

---

## Quick Start

```nim
import airbase

# Declare the airspace — all states and events must be named upfront
defairspace TrafficLight:
  states: [Red, Yellow, Green]
  events: [next, emergency_stop]
  invariants: []

# Declare states with invariants and entry/exit hooks
defstate TrafficLight, Red:
  initial: true
  description: "Full stop"
  onEntry:
    echo "🔴 RED"

defstate TrafficLight, Green:
  description: "Flow permitted"
  onEntry:
    echo "🟢 GREEN"

defstate TrafficLight, Yellow:
  description: "Prepare to stop"

# Declare transitions — only these paths exist, all others are illegal
deftransition TrafficLight, RedToGreen:
  from: Red
  to:   Green
  on:   next

deftransition TrafficLight, GreenToYellow:
  from: Green
  to:   Yellow
  on:   next

deftransition TrafficLight, YellowToRed:
  from: Yellow
  to:   Red
  on:   next

# Wrap the program in a legitimacy proof
defprogram Demo:
  requires: [TrafficLightMachine.current == "Red"]
  body:
    TrafficLightMachine.fire("next")  # Red → Green
    TrafficLightMachine.fire("next")  # Green → Yellow

    # Attempt illegal transition — GROUNDED before execution
    try:
      TrafficLightMachine.fire("emergency_stop")  # not declared from Yellow
    except LegitimacyError as e:
      echo "Grounded: ", e.rule
```

---

## Project Structure

```
airbase/
├── src/
│   ├── airbase.nim          # Unified entry point — import this
│   ├── airbase_core.nim     # Legitimacy engine, state machine, value system
│   ├── airbase_macros.nim   # DSL macro layer (defairspace, defstate, etc.)
│   ├── airbase_types.nim    # Bounded types, schemas, channels, timelines
│   └── airbase_runtime.nim  # Simulation, event queue, telemetry
├── examples/
│   ├── traffic_light.nim    # Classic state machine example
│   ├── order_system.nim     # E-commerce order lifecycle
│   ├── simulation_demo.nim  # Rocket launch with tick-driven simulation
│   └── main.nim             # Combined runner
└── README.md
```

---

## Language Reference

### `defairspace` — Declare an Airspace

An airspace is a state machine declaration. All states and events must be declared before any state or transition can be defined.

```nim
defairspace MachineName:
  states:     [State1, State2, State3]
  events:     [event1, event2]
  invariants: [inv1, inv2]      # optional named invariants
```

**Compile-time checks:**
- States referenced in `defstate` must appear in `states`.
- Events referenced in `deftransition` must appear in `events`.
- Referencing an undeclared state or event is a **compile error**.

Creates a variable `<MachineName>Machine: StateMachine`.

---

### `defstate` — Declare a State

```nim
defstate MachineName, StateName:
  initial:     true              # optional — sets starting state
  terminal:    false             # optional — marks final state
  description: "Human label"    # optional
  invariant "invariant-name":   # optional — checked on entry
    boolExpression
  onEntry:                      # optional — runs when entering
    doSomething()
  onExit:                       # optional — runs when leaving
    doSomethingElse()
```

**Guarantees:**
- Invariants are checked every time the state is entered.
- If any invariant fails → `LegitimacyError` is raised before execution continues.
- `onEntry`/`onExit` receive `ctx: AirbaseValue` as an injected variable.

---

### `deftransition` — Declare a Flight Permission

```nim
deftransition MachineName, TransitionName:
  from:     SourceState
  to:       TargetState
  on:       eventName
  guard:    boolExpression       # optional — ctx is injected
  effect:   AirbaseValueExpr    # optional — returns new context; ctx injected
  requires: [preConditionName]  # optional
  ensures:  [postConditionName] # optional
```

**Compile-time checks:**
- `from` and `to` must be declared states.
- `on` must be a declared event.
- Referencing undeclared states or events is a **compile error**.

**Runtime checks:**
- `guard` is evaluated; if false, this transition is skipped.
- `requires` preconditions are evaluated; if any fail → `LegitimacyError`.
- After transition, `ensures` postconditions are evaluated.
- Target state invariants are validated after entry.

---

### `definvariant` / `defprecondition` / `defpostcondition`

```nim
definvariant MachineName, invariantName:
  description: "What this checks"
  check: boolExpression

defprecondition MachineName, condName:
  description: "Must be true before transition"
  check: boolExpression

defpostcondition MachineName, condName:
  description: "Must be true after transition"
  check: boolExpression
```

---

### `defprogram` — Program as Claim

```nim
defprogram ProgramName:
  requires: [condition1, condition2]
  body:
    # actual code
```

`requires` conditions are evaluated before the body runs. If any fail → `LegitimacyError`. The program is **grounded before it begins**.

---

### `emit` — Explicit Observable Output

```nim
emit "label", value
```

The **only sanctioned way** to produce observable output. Marks a value as intentionally emitted from the system, logging it to stdout with a label.

---

### `when_permitted` — Guarded Execution

```nim
when_permitted MachineName, eventName:
  body  # only runs if the event is currently permitted
```

If the event is not permitted in the current state, raises `LegitimacyError` immediately.

---

### `assert_legitimate` — Runtime Assertion

```nim
assert_legitimate condition, "rule-name", "context description"
```

If `condition` is false, raises `LegitimacyError` with the given rule and context.

---

### `scope_resource` — Declared Resource Use

```nim
scope_resource "resource-name", "reason this is needed":
  # code that uses the resource
  # resource is automatically released on exit
```

Power must pay rent. Every resource use must declare its name and reason.

---

## Type System

### `Bounded[Low, High]` — Range-Constrained Integer

```nim
let throttle = bounded[0, 100](75)    # ok
let bad      = bounded[0, 100](150)   # LegitimacyError at construction
```

An integer that **cannot exist** outside its declared range.

---

### `Schema` — Record Validator

```nim
var schema = newSchema("Order")
schema.addField("orderId", required = true)
schema.addField("amount", required = true,
  validator = proc(v: AirbaseValue): bool = v.kind == akFloat and v.floatVal > 0)

let proof = schema.validate(myRecord)
groundIfNeeded(proof)
```

---

### `Channel[T]` — Typed Message Channel

```nim
let ch = newChannel[string]("notifications", capacity = 10)
ch.send("hello")
let msg = ch.recv()
ch.close()
```

Sending to a closed or full channel → `LegitimacyError`.

---

### `Timeline` — Explicit Time

```nim
let tl = newTimeline("game-clock", tickRateHz = 60.0, maxTick = 3600)
tl.advance()        # time moves forward only when declared
tl.freeze()         # freeze — time may not advance
tl.advance()        # LegitimacyError: timeline-frozen
```

---

### `Observation[T]` — Explicit Observation

```nim
var obs = unobserved(42, "sensor-reading")
# obs.raw is inaccessible until observed
let v = obs.observe()   # marks as observed, returns value
```

---

## State Machine API

```nim
# Fire an event
sm.fire("eventName")          # raises LegitimacyError if not permitted

# Check permissions without firing
sm.canFire("eventName")       # bool
sm.permittedEvents()          # seq[EventId]

# Explicit observation (marks context as observed)
sm.observe()                  # returns current context, logs observation

# Status
sm.current                    # current state ID
sm.history                    # seq of HistoryEntry
sm.summary()                  # human-readable status line
```

---

## Simulation

```nim
let sim = newSimulation("MissionControl", tickRateHz = 1.0, maxTicks = 100)
sim.addMachine(myMachine)

sim.scheduleEvent("MyMachine", "launch", atTick = 5)
sim.scheduleEvent("MyMachine", "orbit",  atTick = 20)

sim.addTickHandler(proc(tick: Tick) =
  echo "tick: ", int64(tick)
)

sim.setHaltCondition(proc(): bool = myMachine.current == "Orbit")

sim.run()
echo sim.report()
```

---

## Error Model

All legitimacy failures raise `LegitimacyError` with:
- `rule`: the specific rule violated (e.g., `"no-valid-transition"`, `"invariant-failure"`)
- `context`: a human-readable description

The program does not crash — it is **grounded**. There is no undefined behavior, no silent corruption. The system refuses to exist in an illegitimate state.

---

## Build & Run

```bash
# Install Nim (https://nim-lang.org)
# Then compile any example:
nim c -r examples/traffic_light.nim
nim c -r examples/order_system.nim
nim c -r examples/simulation_demo.nim

# Or compile the full suite:
nim c -r examples/main.nim
```

---

## Design Notes

**Why Nim?** Nim's macro system allows Airbase to exist as a zero-runtime-overhead DSL. `defairspace`, `defstate`, `deftransition` are all compile-time constructs — the legitimacy checks happen at the Nim compilation phase. The generated code is clean, efficient Nim with no interpreter overhead.

**The metaphor holds.** Airbase is the air traffic authority. Your code is a flight plan. The controller decides if your flight is permitted. Violations ground the craft before takeoff — not after it crashes.

