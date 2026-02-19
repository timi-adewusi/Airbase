## airbase_macros.nim
## The Airbase DSL macro layer.
## This is where Nim becomes Airbase.
##
## Design principle: Code is a proposal. The macro system decides if it is lawful.
## If illegal → compile-time rejection, not runtime failure.

import std/[macros, tables, sets, strutils, options]
import airbase_core

# ============================================================
# COMPILE-TIME LEGITIMACY REGISTRY
# ============================================================
# We track declared states, events, invariants at compile-time
# to catch violations before the program ever runs.

var airspaceRegistry {.compileTime.} = initTable[string, seq[string]]()
  ## machine name → declared states

var eventRegistry {.compileTime.} = initTable[string, seq[string]]()
  ## machine name → declared events

var invariantRegistry {.compileTime.} = initTable[string, seq[string]]()
  ## machine name → declared invariants

# ============================================================
# defairspace — declare an airspace (state machine)
# ============================================================
# Usage:
#   defairspace TrafficLight:
#     states: [Red, Yellow, Green]
#     events: [next, emergency]
#     invariants: [alwaysOneActive]

macro defairspace*(name: untyped, body: untyped): untyped =
  ## Declares an airspace. Validates that all required sections are present.
  ## Emits a StateMachine variable.
  let machineName = name.strVal

  var stateList: seq[string]
  var eventList: seq[string]
  var invList: seq[string]

  # Parse the body to extract declarations
  for stmt in body:
    if stmt.kind == nnkCall and stmt[0].strVal in ["states", "events", "invariants"]:
      let section = stmt[0].strVal
      let arr = stmt[1]
      if arr.kind == nnkBracket:
        for item in arr:
          let itemName = item.strVal
          case section
          of "states":    stateList.add(itemName)
          of "events":    eventList.add(itemName)
          of "invariants": invList.add(itemName)

  if stateList.len == 0:
    error("Airspace '" & machineName & "' must declare at least one state.", name)

  # Register for compile-time checking
  airspaceRegistry[machineName] = stateList
  eventRegistry[machineName] = eventList
  invariantRegistry[machineName] = invList

  # Emit: var <name>Machine = newStateMachine("<name>")
  let varName = ident(machineName & "Machine")
  result = quote do:
    var `varName` = newStateMachine(`machineName`)


# ============================================================
# defstate — declare a state with invariants, entry/exit hooks
# ============================================================
# Usage:
#   defstate TrafficLight, Red:
#     initial: true
#     terminal: false
#     description: "Stop state"
#     invariant "one-active":
#       true
#     onEntry:
#       echo "entering Red"
#     onExit:
#       echo "leaving Red"

macro defstate*(machine: untyped, stateName: untyped, body: untyped): untyped =
  let machineName = machine.strVal
  let stateStr = stateName.strVal

  # Compile-time check: state must be declared in the airspace
  if machineName in airspaceRegistry:
    let declared = airspaceRegistry[machineName]
    if stateStr notin declared:
      error("State '" & stateStr & "' was not declared in airspace '" & machineName & "'. " &
            "Declared states: " & declared.join(", "), stateName)

  let machineVar = ident(machineName & "Machine")

  var isInitial = false
  var isTerminal = false
  var descStr = ""
  var invNames = newSeq[string]()
  var invExprs = newSeq[NimNode]()
  var entryBody = newStmtList()
  var exitBody  = newStmtList()

  for stmt in body:
    if stmt.kind == nnkCall:
      let sname = stmt[0].strVal
      case sname
      of "initial":
        isInitial = (stmt[1].kind == nnkIdent and stmt[1].strVal == "true")
      of "terminal":
        isTerminal = (stmt[1].kind == nnkIdent and stmt[1].strVal == "true")
      of "description":
        descStr = stmt[1].strVal
      of "invariant":
        # invariant "name": <bool expr>
        invNames.add(stmt[1].strVal)
        invExprs.add(stmt[2])
      of "onEntry":
        for s in stmt[1]: entryBody.add(s)
      of "onExit":
        for s in stmt[1]: exitBody.add(s)
    elif stmt.kind == nnkAsgn:
      let lhs = stmt[0].strVal
      case lhs
      of "initial":  isInitial  = (stmt[1].strVal == "true")
      of "terminal": isTerminal = (stmt[1].strVal == "true")

  # Build the invariant sequence
  var invSeqExpr = newTree(nnkBracket)
  for i in 0 ..< invNames.len:
    let nm   = newLit(invNames[i])
    let expr = invExprs[i]
    invSeqExpr.add(quote do:
      Invariant(name: `nm`, description: `nm`,
                check: proc(): bool = `expr`))

  let stateNameStr = stateStr
  let entryProc = quote do:
    proc(ctx {.inject.}: AirbaseValue) = `entryBody`
  let exitProc = quote do:
    proc(ctx {.inject.}: AirbaseValue) = `exitBody`

  result = quote do:
    block:
      var sd = StateDefinition(
        id: `stateNameStr`,
        description: `descStr`,
        isInitial: `isInitial`,
        isTerminal: `isTerminal`,
        invariants: @`invSeqExpr`,
      )
      sd.entryActions.add(`entryProc`)
      sd.exitActions.add(`exitProc`)
      `machineVar`.addState(sd)


# ============================================================
# deftransition — declare a flight permission
# ============================================================
# Usage:
#   deftransition TrafficLight, RedToGreen:
#     from: Red
#     to:   Green
#     on:   next
#     guard: ctx.intVal > 0
#     effect: ctx  # or transform context
#     requires: [safeToGo]
#     ensures:  [greenIsActive]

macro deftransition*(machine: untyped, tname: untyped, body: untyped): untyped =
  let machineName = machine.strVal
  let transStr    = tname.strVal
  let machineVar  = ident(machineName & "Machine")

  var fromStr    = ""
  var toStr      = ""
  var eventStr   = ""
  var guardExpr: NimNode = nil
  var effectExpr: NimNode = nil
  var requiresList: seq[string]
  var ensuresList: seq[string]

  for stmt in body:
    if stmt.kind == nnkCall:
      let sname = stmt[0].strVal
      case sname
      of "from":    fromStr  = stmt[1].strVal
      of "to":      toStr    = stmt[1].strVal
      of "on":      eventStr = stmt[1].strVal
      of "guard":   guardExpr  = stmt[1]
      of "effect":  effectExpr = stmt[1]
      of "requires":
        let arr = stmt[1]
        if arr.kind == nnkBracket:
          for item in arr: requiresList.add(item.strVal)
      of "ensures":
        let arr = stmt[1]
        if arr.kind == nnkBracket:
          for item in arr: ensuresList.add(item.strVal)

  # Compile-time validation
  if fromStr == "":
    error("Transition '" & transStr & "' missing 'from' state.", tname)
  if toStr == "":
    error("Transition '" & transStr & "' missing 'to' state.", tname)
  if eventStr == "":
    error("Transition '" & transStr & "' missing 'on' event.", tname)

  if machineName in airspaceRegistry:
    let states = airspaceRegistry[machineName]
    if fromStr notin states:
      error("Transition source '" & fromStr & "' not declared in '" & machineName & "'.", tname)
    if toStr notin states:
      error("Transition target '" & toStr & "' not declared in '" & machineName & "'.", tname)

  if machineName in eventRegistry:
    let events = eventRegistry[machineName]
    if eventStr notin events:
      error("Event '" & eventStr & "' not declared in airspace '" & machineName & "'.", tname)

  # Build guard and effect as Option[proc]
  let guardOpt = if guardExpr.isNil:
    quote do: none(TransitionGuard)
  else:
    quote do: some(proc(ctx {.inject.}: AirbaseValue): bool = `guardExpr`)

  let effectOpt = if effectExpr.isNil:
    quote do: none(TransitionEffect)
  else:
    quote do: some(proc(ctx {.inject.}: AirbaseValue): AirbaseValue = `effectExpr`)

  # Build requires/ensures seqs
  var reqLit = newTree(nnkBracket)
  for r in requiresList: reqLit.add(newLit(r))
  var ensLit = newTree(nnkBracket)
  for e in ensuresList: ensLit.add(newLit(e))

  result = quote do:
    block:
      let t = Transition(
        name:      `transStr`,
        fromState: `fromStr`,
        toState:   `toStr`,
        event:     `eventStr`,
        guard:     `guardOpt`,
        effect:    `effectOpt`,
        requires:  @`reqLit`,
        ensures:   @`ensLit`,
      )
      `machineVar`.addTransition(t)


# ============================================================
# definvariant — named invariant registration
# ============================================================
# Usage:
#   definvariant TrafficLight, alwaysOneActive:
#     description: "Exactly one light is on"
#     check: TrafficLightMachine.current in ["Red","Yellow","Green"]

macro definvariant*(machine: untyped, iname: untyped, body: untyped): untyped =
  let machineName = machine.strVal
  let invStr      = iname.strVal
  let machineVar  = ident(machineName & "Machine")

  var descStr  = invStr
  var checkExpr: NimNode = newLit(true)

  for stmt in body:
    if stmt.kind == nnkCall:
      case stmt[0].strVal
      of "description": descStr  = stmt[1].strVal
      of "check":       checkExpr = stmt[1]

  result = quote do:
    `machineVar`.registerInvariant(Invariant(
      name: `invStr`,
      description: `descStr`,
      check: proc(): bool = `checkExpr`
    ))


# ============================================================
# defprecondition / defpostcondition
# ============================================================

macro defprecondition*(machine: untyped, pname: untyped, body: untyped): untyped =
  let machineName = machine.strVal
  let pStr        = pname.strVal
  let machineVar  = ident(machineName & "Machine")

  var descStr  = pStr
  var checkExpr: NimNode = newLit(true)
  for stmt in body:
    if stmt.kind == nnkCall:
      case stmt[0].strVal
      of "description": descStr   = stmt[1].strVal
      of "check":       checkExpr = stmt[1]

  result = quote do:
    `machineVar`.registerPrecondition(Precondition(
      name: `pStr`,
      description: `descStr`,
      check: proc(): bool = `checkExpr`
    ))

macro defpostcondition*(machine: untyped, pname: untyped, body: untyped): untyped =
  let machineName = machine.strVal
  let pStr        = pname.strVal
  let machineVar  = ident(machineName & "Machine")

  var descStr  = pStr
  var checkExpr: NimNode = newLit(true)
  for stmt in body:
    if stmt.kind == nnkCall:
      case stmt[0].strVal
      of "description": descStr   = stmt[1].strVal
      of "check":       checkExpr = stmt[1]

  result = quote do:
    `machineVar`.registerPostcondition(Postcondition(
      name: `pStr`,
      description: `descStr`,
      check: proc(): bool = `checkExpr`
    ))


# ============================================================
# emit — explicit, named emission (observable output)
# ============================================================
# Usage:
#   emit "light-changed", TrafficLightMachine.current

macro emit*(label: static[string], value: untyped): untyped =
  ## Mark something as explicitly observed/emitted from the system.
  ## This is the ONLY sanctioned way to produce observable output.
  result = quote do:
    block:
      let v = `value`
      echo "[EMIT:" & `label` & "] " & $v
      v


# ============================================================
# when_permitted — guarded execution block
# ============================================================
# Usage:
#   when_permitted TrafficLightMachine, next:
#     TrafficLightMachine.fire("next")

macro when_permitted*(machine: untyped, event: untyped, body: untyped): untyped =
  let machineVar = machine
  let eventStr = event.strVal
  result = quote do:
    if `machineVar`.canFire(`eventStr`):
      `body`
    else:
      raise newLegitimacyError("not-permitted",
        "Event '" & `eventStr` & "' not permitted in current state")


# ============================================================
# assert_legitimate — runtime legitimacy assertion
# ============================================================

macro assert_legitimate*(condition: untyped, rule: static[string], context: static[string] = ""): untyped =
  result = quote do:
    if not (`condition`):
      raise newLegitimacyError(`rule`, `context`)


# ============================================================
# defprogram — top-level program declaration
# ============================================================
# A program is a claim. It must prove legitimacy before it "exists".
# Usage:
#   defprogram MyProgram:
#     requires: [invariant expressions...]
#     body:
#       <code>

macro defprogram*(name: untyped, body: untyped): untyped =
  let progName = name.strVal
  var requiresList: seq[NimNode]
  var programBody = newStmtList()

  for stmt in body:
    if stmt.kind == nnkCall:
      case stmt[0].strVal
      of "requires":
        let arr = stmt[1]
        if arr.kind == nnkBracket:
          for item in arr: requiresList.add(item)
      of "body":
        for s in stmt[1]: programBody.add(s)

  # Build legitimacy proof check
  var proofChecks = newStmtList()
  for i, req in requiresList:
    proofChecks.add(quote do:
      block:
        let passed = `req`
        if not passed:
          raise newLegitimacyError("program-legitimacy",
            "Program '" & `progName` & "' failed legitimacy check #" & $`i`)
    )

  result = quote do:
    block:
      `proofChecks`
      `programBody`


# ============================================================
# scope_resource — declare a scoped resource (power must pay rent)
# ============================================================
# Usage:
#   scope_resource "db-connection", "Database access required for query":
#     # body that uses the resource
#     discard

macro scope_resource*(resourceName: static[string], reason: static[string], body: untyped): untyped =
  result = quote do:
    block:
      echo "[RESOURCE-ENTER:" & `resourceName` & "] " & `reason`
      try:
        `body`
      finally:
        echo "[RESOURCE-EXIT:" & `resourceName` & "]"


# ============================================================
# Convenience: fire_event with automatic grounding on failure
# ============================================================

template fire_event*(machine: StateMachine, event: string) =
  ## Fire an event. If not permitted, the program is grounded.
  machine.fire(event)

template observe_state*(machine: StateMachine): AirbaseValue =
  ## Explicit observation — marks the context as observed.
  machine.observe()

