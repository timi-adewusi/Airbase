## airbase_runtime.nim
## Airbase runtime — simulation loop, event queue, telemetry.
## Deterministic, tick-driven execution.

import std/[tables, deques, strformat, sequtils, options, times, strutils]
import airbase_core
import airbase_types

# ============================================================
# EVENT QUEUE — typed, ordered, legitimate
# ============================================================

type
  QueuedEvent* = object
    machineId*: string
    event*: EventId
    scheduledAt*: Tick
    payload*: AirbaseValue

  EventQueue* = ref object
    name*: string
    queue*: Deque[QueuedEvent]
    rejected*: seq[QueuedEvent]
    processed*: int

proc newEventQueue*(name: string): EventQueue =
  EventQueue(name: name, queue: initDeque[QueuedEvent]())

proc schedule*(eq: EventQueue, machineId, event: string,
               at: Tick = Tick(0), payload: AirbaseValue = nil) =
  eq.queue.addLast(QueuedEvent(
    machineId: machineId,
    event: event,
    scheduledAt: at,
    payload: if payload.isNil: airVoid() else: payload
  ))

proc next*(eq: EventQueue): Option[QueuedEvent] =
  if eq.queue.len > 0:
    result = some(eq.queue.popFirst())
    eq.processed.inc
  else:
    result = none(QueuedEvent)


# ============================================================
# SIMULATION — tick-driven, deterministic
# ============================================================

type
  SimulationStatus* = enum
    ssIdle, ssRunning, ssHalted, ssGrounded

  SimStep* = object
    tick*: Tick
    events*: seq[QueuedEvent]
    machineStates*: Table[string, StateId]
    observations*: seq[string]

  Simulation* = ref object
    name*: string
    timeline*: Timeline
    machines*: Table[string, StateMachine]
    eventQueue*: EventQueue
    status*: SimulationStatus
    steps*: seq[SimStep]
    tickHandlers*: seq[proc(tick: Tick) {.closure.}]
    haltCondition*: Option[proc(): bool {.closure.}]
    maxTicks*: int
    telemetry*: seq[string]

proc newSimulation*(name: string, tickRateHz = 1.0, maxTicks = 1000): Simulation =
  Simulation(
    name: name,
    timeline: newTimeline(name & "-timeline", tickRateHz, maxTicks),
    eventQueue: newEventQueue(name & "-events"),
    machines: initTable[string, StateMachine](),
    status: ssIdle,
    maxTicks: maxTicks,
  )

proc addMachine*(sim: Simulation, sm: StateMachine) =
  sim.machines[sm.name] = sm

proc addTickHandler*(sim: Simulation, handler: proc(tick: Tick) {.closure.}) =
  sim.tickHandlers.add(handler)

proc setHaltCondition*(sim: Simulation, cond: proc(): bool {.closure.}) =
  sim.haltCondition = some(cond)

proc scheduleEvent*(sim: Simulation, machineId, event: string,
                    atTick: int64 = 0, payload: AirbaseValue = nil) =
  sim.eventQueue.schedule(machineId, event, Tick(atTick), payload)

proc log*(sim: Simulation, msg: string) =
  let entry = fmt"[{sim.name}@tick={int64(sim.timeline.current)}] {msg}"
  sim.telemetry.add(entry)
  echo entry

proc snapshotStates(sim: Simulation): Table[string, StateId] =
  for name, sm in sim.machines:
    result[name] = sm.current

proc runOnce*(sim: Simulation) =
  ## Process all events at the current tick
  let currentTick = sim.timeline.current
  var step = SimStep(tick: currentTick, machineStates: snapshotStates(sim))
  var pending: seq[QueuedEvent]

  # Collect all events for this tick
  while sim.eventQueue.queue.len > 0:
    let front = sim.eventQueue.queue[0]
    if front.scheduledAt <= currentTick:
      discard sim.eventQueue.queue.popFirst()
      pending.add(front)
    else:
      break

  # Fire all pending events
  for ev in pending:
    step.events.add(ev)
    if ev.machineId in sim.machines:
      let sm = sim.machines[ev.machineId]
      try:
        sim.log(fmt"fire {ev.machineId}.{ev.event}")
        sm.fire(ev.event)
        step.observations.add(sm.summary())
      except LegitimacyError as e:
        sim.log(fmt"GROUNDED: {e.msg}")
        sim.status = ssGrounded
        sim.steps.add(step)
        return

  # Run tick handlers
  for handler in sim.tickHandlers:
    handler(currentTick)

  sim.steps.add(step)

proc run*(sim: Simulation) =
  ## Run the simulation until halted, grounded, or max ticks reached.
  sim.status = ssRunning
  sim.log(fmt"Simulation '{sim.name}' starting")

  while sim.status == ssRunning:
    # Check halt condition
    if sim.haltCondition.isSome and sim.haltCondition.get()():
      sim.status = ssHalted
      sim.log("Halt condition met")
      break

    if int64(sim.timeline.current) >= int64(sim.maxTicks):
      sim.status = ssHalted
      sim.log(fmt"Max ticks ({sim.maxTicks}) reached")
      break

    sim.runOnce()
    
    if sim.status == ssGrounded: break
    
    sim.timeline.advance()

  sim.log(fmt"Simulation complete. Status={sim.status}. Ticks={int64(sim.timeline.current)}")

proc report*(sim: Simulation): string =
  var lines: seq[string]
  lines.add("═══════════════════════════════════════")
  lines.add(fmt"SIMULATION REPORT: {sim.name}")
  lines.add("═══════════════════════════════════════")
  lines.add(fmt"Status: {sim.status}")
  lines.add(fmt"Total ticks: {int64(sim.timeline.current)}")
  lines.add(fmt"Events processed: {sim.eventQueue.processed}")
  lines.add("")
  lines.add("Machine final states:")
  for name, sm in sim.machines:
    lines.add(fmt"  {name}: {sm.current} ({sm.history.len} transitions)")
  lines.add("")
  lines.add("Telemetry (" & $sim.telemetry.len & " entries):")
  for t in sim.telemetry:
    lines.add("  " & t)
  result = lines.join("\n")


# ============================================================
# TELEMETRY — structured, observable output
# ============================================================

type
  TelemetryLevel* = enum
    tlDebug, tlInfo, tlWarn, tlViolation

  TelemetryEntry* = object
    level*: TelemetryLevel
    machine*: string
    state*: string
    message*: string
    at*: float

  TelemetryLog* = ref object
    entries*: seq[TelemetryEntry]
    filter*: TelemetryLevel

proc newTelemetryLog*(filter = tlInfo): TelemetryLog =
  TelemetryLog(filter: filter)

proc record*(log: TelemetryLog, level: TelemetryLevel, machine, state, msg: string) =
  if level >= log.filter:
    let e = TelemetryEntry(level: level, machine: machine,
                           state: state, message: msg, at: epochTime())
    log.entries.add(e)
    echo fmt"[{level}|{machine}:{state}] {msg}"

proc violations*(log: TelemetryLog): seq[TelemetryEntry] =
  log.entries.filterIt(it.level == tlViolation)

proc hasViolations*(log: TelemetryLog): bool =
  log.violations().len > 0

