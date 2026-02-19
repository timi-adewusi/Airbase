## example_traffic.nim
## Example: Traffic light simulation using the Airbase language.
## Demonstrates: simple simulation, tick, emit_obs, must, never, audit

import ../src/airbase

airspace TrafficDemo:

  rule "no hidden mutation"
  rule "all state transitions are named"
  rule "time only advances when declared"

  # ─── State machine variables ────────────────────
  type
    TrafficState = enum Red, Yellow, Green

  var currentState = Red

  proc advance() =
    case currentState
    of Red:
      currentState = Green
      emit_obs("transition", "Red->Green")
    of Green:
      currentState = Yellow
      emit_obs("transition", "Green->Yellow")
    of Yellow:
      currentState = Red
      emit_obs("transition", "Yellow->Red")

  # ─── Declare power budget ────────────────────
  declare_power([branch, loop(6)], "run 6-cycle traffic simulation"):

    # Run 6 transitions — one full double-cycle
    declared_loop("signal-cycle", bound = 6, reason = "fixed simulation length"):

      # Observe current state
      emit_obs("signal.state", $currentState)

      # Advance to next state
      advance()

      # Invariant: Yellow never goes directly to Green
      never(
        currentState == Green and (globalAirspace.clock mod 3) == 1,
        "Green must only follow Red"
      )

      tick("signal-step")
      checkBound()  # enforces the declared loop bound

  # ─── Issue legitimacy certificate ────────────
  certify("TrafficDemo",
    axioms = @[
      "state transitions are explicit",
      "loop is bounded by 6",
      "time is explicit (tick called once per step)",
      "observations are labeled (signal.state)"
    ],
    power = @[
      "branch: signal routing",
      "loop(6): signal-cycle"
    ]
  )

  audit()
