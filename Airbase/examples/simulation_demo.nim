## simulation_demo.nim
## Demonstration of Airbase's simulation, time, and explicit tick system.
## "Time advances only when declared."

import ../src/airbase

airspace RocketLaunch:

  rule "fuel must be sufficient for launch"
  rule "altitude increases monotonically during ascent"
  rule "time advances explicitly via tick()"
  rule "launch sequence cannot reverse"

  # ─── Rocket state ──────────────────────────────────────────
  type
    RocketPhase = enum Pad, Armed, Ignition, Ascending, Orbit, Aborted

  var phase = Pad
  var fuelLevel = 100
  var altitude = 0

  # ─── Launch operations ───────────────────────────────────
  proc armEngines() =
    pre(phase == Pad, "must be on pad")
    pre(fuelLevel >= 50, "insufficient fuel")
    phase = Armed
    tick("engines armed")
    emit_obs("launch.armed", $fuelLevel)

  proc igniteEngines() =
    pre(phase == Armed, "engines must be armed")
    phase = Ignition
    tick("ignition sequence")
    emit_obs("launch.ignition", "main engines")

  proc liftoff() =
    pre(phase == Ignition, "must be igniting")
    phase = Ascending
    altitude = 1000
    fuelLevel = fuelLevel - 20
    tick("liftoff")
    emit_obs("launch.liftoff", "vehicle ascending")

  proc reachOrbit() =
    pre(phase == Ascending, "must be ascending")
    pre(altitude >= 1000, "insufficient altitude")
    phase = Orbit
    tick("orbit achieved")
    must(phase == Orbit, "final phase must be Orbit")
    emit_obs("launch.orbit", "stable orbit")

  proc abort() =
    pre(phase != Orbit and phase != Aborted, "cannot abort from orbit")
    phase = Aborted
    fuelLevel = 0
    tick("abort sequence")
    emit_obs("launch.aborted", "emergency procedures")

  # ─── Run full launch simulation ─────────────────────────────
  declare_power([branch, allocate, loop(10)], "rocket launch simulation"):

    emit_obs("sim.start", "Launch sequence initiated")

    # Pre-flight
    tick("pre-flight checks")
    emit_obs("launch.preflight", "all systems nominal")

    # Arm engines
    armEngines()

    # Ignition
    igniteEngines()

    # Liftoff and ascent
    liftoff()
    emit_obs("launch.altitude", $altitude)

    # Continue ascending
    tick("coasting")
    altitude = altitude + 500
    emit_obs("launch.altitude", $altitude)

    tick("final burn")
    altitude = altitude + 500
    emit_obs("launch.altitude", $altitude)

    # Reach orbit
    reachOrbit()

    # Verify final state
    must(phase == Orbit, "reached orbit successfully")
    must(altitude >= 1000, "altitude above orbital minimum")

    emit_obs("sim.complete", "Mission successful")

  # ─── Abort scenario demonstration ──────────────────────────
  declare_power([branch, allocate], "abort scenario"):

    emit_obs("abort_test.start", "Testing abort sequence")

    # Reset state for abort test
    phase = Pad
    fuelLevel = 100
    altitude = 0

    # Arm for launch
    armEngines()
    igniteEngines()

    # Initiate abort before liftoff
    abort()

    must(phase == Aborted, "phase is aborted")
    must(fuelLevel == 0, "fuel dumped")

    emit_obs("abort_test.complete", "Abort test successful")

  certify("RocketLaunch",
    axioms = @[
      "fuel is bounded [0,100]",
      "altitude increases monotonically",
      "launch sequence is acyclic",
      "orbit is terminal state",
      "all events are observable"
    ],
    power = @[
      "loop(10): ascent phase",
      "branch: abort handling",
      "allocate: rocket context"
    ]
  )

  audit()

