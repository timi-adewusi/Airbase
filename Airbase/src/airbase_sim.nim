## airbase_sim.nim
## Deterministic simulation engine for Airbase.
## Time, state, and observation are always explicit.

import macros, strformat, tables, sequtils, options, strutils
import airbase_core, airbase_dsl, airbase_contracts

# ============================================================
#  Simulation Frame — a snapshot at one logical tick
# ============================================================

type
  SimFrame* = object
    tick*: int64
    stateName*: string
    observables*: Table[string, string]
    effects*: seq[string]

  SimulationLog* = object
    frames*: seq[SimFrame]
    name*: string

  SimulationResult* = object
    totalTicks*: int64
    finalState*: string
    log*: SimulationLog
    legitimate*: bool
    violations*: seq[string]

proc newSimLog*(name: string): SimulationLog =
  SimulationLog(name: name, frames: @[])

proc snapshot*(log: var SimulationLog, space: Airspace,
               state: string, observables: Table[string, string],
               effects: seq[string] = @[]) =
  log.frames.add(SimFrame(
    tick: space.clock,
    stateName: state,
    observables: observables,
    effects: effects
  ))

proc renderLog*(log: SimulationLog): string =
  result = fmt"=== Simulation: {log.name} ===\n"
  for f in log.frames:
    result &= fmt"  tick {f.tick:>4} | state: {f.stateName:<20}"
    if f.observables.len > 0:
      var obs: seq[string] = @[]
      for k, v in f.observables:
        obs.add(fmt"{k}={v}")
      result &= " | " & obs.join(", ")
    if f.effects.len > 0:
      result &= "\n           effects: " & f.effects.join("; ")
    result &= "\n"
  result &= "=== End ==="

# ============================================================
#  `simulation` macro — declarative simulation block
##
##  simulation "TrafficDemo":
##    machine: TrafficLight
##    steps: 6
##    on_tick:
##      fly(TrafficLight, "go")
##      tick("step")
##    observe: currentState, carCount
#
# ============================================================

macro simulation*(name: untyped, body: untyped): untyped =
  ## Wraps a simulation loop in a legitimacy-checked frame
  let nameStr = expectStr(name, "simulation")
  result = newStmtList(
    newVarStmt(ident("simLog"), newCall(ident("newSimLog"), newLit(nameStr))),
    newCall(ident("echo"), newLit(fmt"[AIRBASE SIM] Starting simulation: {nameStr}")),
    body,
    newCall(ident("echo"), newLit(fmt"[AIRBASE SIM] Simulation '{nameStr}' complete at tick " & "$(globalAirspace.clock)"))
  )

# ============================================================
#  Event system — explicit, named, typed events
# ============================================================

type
  Event*[T] = object
    name*: string
    payload*: T
    tick*: int64
    consumed*: bool

  EventQueue*[T] = object
    events*: seq[Event[T]]
    maxSize*: int

proc newEventQueue*[T](maxSize: int = 1000): EventQueue[T] =
  EventQueue[T](events: @[], maxSize: maxSize)

proc enqueue*[T](q: var EventQueue[T], name: string, payload: T,
                 space: Airspace) =
  if q.events.len >= q.maxSize:
    raiseAirbaseError(UnboundedPower,
      fmt"EventQueue exceeded declared max size of {q.maxSize}")
  q.events.add(Event[T](
    name: name, payload: payload,
    tick: space.clock, consumed: false))

proc dequeue*[T](q: var EventQueue[T]): Option[Event[T]] =
  for i in 0..<q.events.len:
    if not q.events[i].consumed:
      q.events[i].consumed = true
      return some(q.events[i])
  none(Event[T])

proc pendingCount*[T](q: EventQueue[T]): int =
  q.events.countIt(not it.consumed)

# ============================================================
#  Reactive bindings — values that re-compute when dependencies change
# ============================================================

type
  Reactive*[T] = object
    value*: T
    label*: string
    version*: int64

proc reactive*[T](initial: T, label: string): Reactive[T] =
  Reactive[T](value: initial, label: label, version: 0)

proc update*[T](r: var Reactive[T], newVal: T, space: var Airspace) =
  r.value = newVal
  inc r.version
  discard space.emit(r.label & ".changed", $newVal)

proc current*[T](r: Reactive[T]): T = r.value

# ============================================================
#  Guarded values — values behind explicit access conditions
# ============================================================

type
  Guarded*[T] = object
    inner*: T
    guardExpr*: string
    locked*: bool

proc guard*[T](val: T, reason: string): Guarded[T] =
  Guarded[T](inner: val, guardExpr: reason, locked: true)

proc unlock*[T](g: var Guarded[T], condition: bool, reason: string): T =
  if not condition:
    raiseAirbaseError(LegitimacyViolation,
      fmt"Guard '{g.guardExpr}' not satisfied to unlock: {reason}")
  g.locked = false
  g.inner

proc isLocked*[T](g: Guarded[T]): bool = g.locked

# ============================================================
#  Snapshot / restore — for deterministic replay
# ============================================================

type
  AirspaceSnapshot* = object
    clock*: int64
    name*: string
    emissionCount*: int

proc takeSnapshot*(space: Airspace): AirspaceSnapshot =
  AirspaceSnapshot(
    clock: space.clock,
    name: space.name,
    emissionCount: space.emissions.len
  )

proc `$`*(snap: AirspaceSnapshot): string =
  fmt"Snapshot[{snap.name} @ tick={snap.clock}, emissions={snap.emissionCount}]"

# ============================================================
#  Replay assertion — check that two runs produce the same observables
# ============================================================

proc assertDeterministic*(a, b: seq[string], label: string) =
  if a != b:
    var diffs: seq[string] = @[]
    for i in 0..<min(a.len, b.len):
      if a[i] != b[i]:
        diffs.add(fmt"  [tick {i}] A: {a[i]}")
        diffs.add(fmt"  [tick {i}] B: {b[i]}")
    raiseAirbaseError(ContractBreach,
      fmt"Determinism violation in '{label}': runs produced different observables\n" &
      diffs.join("\n"))

# ============================================================
#  `phase` macro — named simulation phases with tick tracking
##
##  phase "initialization":
##    setupWorld()
##    tick("init complete")
#
# ============================================================

macro phase*(name: untyped, body: untyped): untyped =
  result = quote do:
    block:
      let phaseStart = globalAirspace.clock
      emit_obs("phase.start", `name`)
      `body`
      emit_obs("phase.end", `name`)
      let phaseDuration = globalAirspace.clock - phaseStart
      discard globalAirspace.emit("phase.duration",
        `name` & "=" & $(phaseDuration) & "ticks")
