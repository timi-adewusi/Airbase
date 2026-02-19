## airbase_core.nim
## Core runtime types, legitimacy engine, and state machine primitives.
## "Nothing is allowed unless it is proven legitimate."

import std/[tables, sets, hashes, strformat, strutils, sequtils, options, times, macros]

# ============================================================
# LEGITIMACY SYSTEM
# ============================================================

type
  LegitimacyStatus* = enum
    lsUnknown    = "unknown"
    lsLegitimate = "legitimate"
    lsViolation  = "violation"
    lsGrounded   = "grounded"

  AirbaseErrorKind* = enum
    LegitimacyViolation = "legitimacy violation"
    IllegalState = "illegal state"
    UnprovenClaim = "unproven claim"
    ImplicitEffect = "implicit effect"
    UnboundedPower = "unbounded power"
    TimeViolation = "time violation"
    ObservationViolation = "observation violation"
    ContractBreach = "contract breach"

  LegitimacyError* = object of CatchableError
    rule*: string
    context*: string

  AirbaseError* = object of CatchableError
    kind*: AirbaseErrorKind
    message*: string

  Invariant* = object
    name*: string
    description*: string
    check*: proc(): bool {.closure.}

  Precondition* = object
    name*: string
    description*: string
    check*: proc(): bool {.closure.}

  Postcondition* = object
    name*: string
    description*: string
    check*: proc(): bool {.closure.}

  LegitimacyProof* = object
    status*: LegitimacyStatus
    checkedInvariants*: seq[string]
    failedInvariants*: seq[string]
    timestamp*: float

proc newLegitimacyError*(rule, ctx: string): ref LegitimacyError =
  result = newException(LegitimacyError, "Legitimacy violation: [" & rule & "] " & ctx)
  result.rule = rule
  result.context = ctx

proc raiseAirbaseError*(kind: AirbaseErrorKind, message: string) =
  let err = newException(AirbaseError, $kind & ": " & message)
  err.kind = kind
  err.message = message
  raise err

proc proveAll*(invariants: openArray[Invariant]): LegitimacyProof =
  result.timestamp = epochTime()
  result.status = lsLegitimate
  for inv in invariants:
    result.checkedInvariants.add(inv.name)
    if not inv.check():
      result.failedInvariants.add(inv.name)
      result.status = lsViolation

proc groundIfNeeded*(proof: LegitimacyProof) =
  if proof.status == lsViolation:
    let failed = proof.failedInvariants.join(", ")
    raise newLegitimacyError("invariant-failure", "Grounded. Failed: " & failed)

# ============================================================
# AIRBASE VALUE SYSTEM
# ============================================================

type
  AirbaseKind* = enum
    akVoid, akBool, akInt, akFloat, akStr, akEnum, akRecord, akList, akSet, akOption, akRef

  AirbaseProvenance* = object
    origin*: string
    transitions*: seq[string]
    observedAt*: seq[float]
    legitimacyProven*: bool

  AirbaseValue* = ref AirbaseValueObj
  AirbaseValueObj* = object
    kind*: AirbaseKind
    provenance*: AirbaseProvenance
    case kindVal*: AirbaseKind
    of akVoid:   discard
    of akBool:   boolVal*: bool
    of akInt:    intVal*: int64
    of akFloat:  floatVal*: float64
    of akStr:    strVal*: string
    of akEnum:   enumVal*: string
    of akRecord: fields*: OrderedTable[string, AirbaseValue]
    of akList:   items*: seq[AirbaseValue]
    of akSet:    members*: HashSet[string]
    of akOption: inner*: Option[AirbaseValue]
    of akRef:
      refName*: string
      target*:  ref AirbaseValueObj

proc airVoid*(): AirbaseValue =
  AirbaseValue(kind: akVoid, kindVal: akVoid,
    provenance: AirbaseProvenance(origin: "void", legitimacyProven: true))

proc airBool*(v: bool, origin = "literal"): AirbaseValue =
  AirbaseValue(kind: akBool, kindVal: akBool, boolVal: v,
    provenance: AirbaseProvenance(origin: origin, legitimacyProven: true))

proc airInt*(v: int64, origin = "literal"): AirbaseValue =
  AirbaseValue(kind: akInt, kindVal: akInt, intVal: v,
    provenance: AirbaseProvenance(origin: origin, legitimacyProven: true))

proc airFloat*(v: float64, origin = "literal"): AirbaseValue =
  AirbaseValue(kind: akFloat, kindVal: akFloat, floatVal: v,
    provenance: AirbaseProvenance(origin: origin, legitimacyProven: true))

proc airStr*(v: string, origin = "literal"): AirbaseValue =
  AirbaseValue(kind: akStr, kindVal: akStr, strVal: v,
    provenance: AirbaseProvenance(origin: origin, legitimacyProven: true))

proc airEnum*(v: string, origin = "literal"): AirbaseValue =
  AirbaseValue(kind: akEnum, kindVal: akEnum, enumVal: v,
    provenance: AirbaseProvenance(origin: origin, legitimacyProven: true))

proc airRecord*(fields: openArray[(string, AirbaseValue)], origin = "literal"): AirbaseValue =
  var tbl = initOrderedTable[string, AirbaseValue]()
  for (k, v) in fields: tbl[k] = v
  AirbaseValue(kind: akRecord, kindVal: akRecord, fields: tbl,
    provenance: AirbaseProvenance(origin: origin, legitimacyProven: true))

proc airList*(items: seq[AirbaseValue], origin = "literal"): AirbaseValue =
  AirbaseValue(kind: akList, kindVal: akList, items: items,
    provenance: AirbaseProvenance(origin: origin, legitimacyProven: true))

proc airSome*(v: AirbaseValue): AirbaseValue =
  AirbaseValue(kind: akOption, kindVal: akOption, inner: some(v),
    provenance: AirbaseProvenance(origin: "some", legitimacyProven: true))

proc airNone*(): AirbaseValue =
  AirbaseValue(kind: akOption, kindVal: akOption, inner: none(AirbaseValue),
    provenance: AirbaseProvenance(origin: "none", legitimacyProven: true))

proc markObserved*(v: AirbaseValue) =
  v.provenance.observedAt.add(epochTime())

proc markTransition*(v: AirbaseValue, name: string) =
  v.provenance.transitions.add(name)

proc `$`*(v: AirbaseValue): string =
  if v.isNil: return "nil"
  case v.kind
  of akVoid:   "void"
  of akBool:   $v.boolVal
  of akInt:    $v.intVal
  of akFloat:  $v.floatVal
  of akStr:    v.strVal
  of akEnum:   "#" & v.enumVal
  of akRecord:
    var parts: seq[string]
    for k, val in v.fields: parts.add(k & ": " & $val)
    "{" & parts.join(", ") & "}"
  of akList:
    "[" & v.items.mapIt($it).join(", ") & "]"
  of akSet:
    "{" & toSeq(v.members).join(", ") & "}"
  of akOption:
    if v.inner.isSome: "Some(" & $v.inner.get & ")"
    else: "None"
  of akRef:
    "&" & v.refName

# ============================================================
# STATE MACHINE CORE
# ============================================================

type
  StateId* = string
  EventId* = string

  TransitionGuard* = proc(ctx: AirbaseValue): bool {.closure.}
  TransitionEffect* = proc(ctx: AirbaseValue): AirbaseValue {.closure.}
  StateAction* = proc(ctx: AirbaseValue) {.closure.}

  Transition* = object
    name*: string
    fromState*: StateId
    toState*: StateId
    event*: EventId
    guard*: Option[TransitionGuard]
    effect*: Option[TransitionEffect]
    requires*: seq[string]
    ensures*: seq[string]

  StateDefinition* = object
    id*: StateId
    description*: string
    invariants*: seq[Invariant]
    entryActions*: seq[StateAction]
    exitActions*: seq[StateAction]
    isTerminal*: bool
    isInitial*: bool

  HistoryEntry* = object
    fromState*: StateId
    toState*: StateId
    event*: EventId
    at*: float

  ObservationEntry* = object
    state*: StateId
    at*: float
    snapshot*: string

  StateMachine* = ref object
    name*: string
    states*: Table[StateId, StateDefinition]
    transitions*: seq[Transition]
    current*: StateId
    context*: AirbaseValue
    history*: seq[HistoryEntry]
    namedInvariants*: Table[string, Invariant]
    namedPreconditions*: Table[string, Precondition]
    namedPostconditions*: Table[string, Postcondition]
    observationLog*: seq[ObservationEntry]

proc newStateMachine*(name: string, ctx: AirbaseValue = nil): StateMachine =
  StateMachine(
    name: name,
    states: initTable[StateId, StateDefinition](),
    namedInvariants: initTable[string, Invariant](),
    namedPreconditions: initTable[string, Precondition](),
    namedPostconditions: initTable[string, Postcondition](),
    context: if ctx.isNil: airVoid() else: ctx,
  )

proc addState*(sm: StateMachine, s: StateDefinition) =
  sm.states[s.id] = s
  if s.isInitial: sm.current = s.id

proc addTransition*(sm: StateMachine, t: Transition) =
  sm.transitions.add(t)

proc registerInvariant*(sm: StateMachine, inv: Invariant) =
  sm.namedInvariants[inv.name] = inv

proc registerPrecondition*(sm: StateMachine, pre: Precondition) =
  sm.namedPreconditions[pre.name] = pre

proc registerPostcondition*(sm: StateMachine, post: Postcondition) =
  sm.namedPostconditions[post.name] = post

proc validateState*(sm: StateMachine, stateId: StateId) =
  if stateId notin sm.states:
    raise newLegitimacyError("unknown-state",
      "State '" & stateId & "' not declared in '" & sm.name & "'")
  let state = sm.states[stateId]
  let proof = proveAll(state.invariants)
  groundIfNeeded(proof)

proc fire*(sm: StateMachine, event: EventId): bool {.discardable.} =
  for t in sm.transitions:
    if t.fromState == sm.current and t.event == event:
      if t.guard.isSome:
        if not t.guard.get()(sm.context): continue

      for reqName in t.requires:
        if reqName in sm.namedPreconditions:
          if not sm.namedPreconditions[reqName].check():
            raise newLegitimacyError("precondition-failed",
              "'" & reqName & "' failed for '" & t.name & "'")

      if t.toState notin sm.states:
        raise newLegitimacyError("invalid-transition",
          "Target state '" & t.toState & "' unknown")

      let fromState = sm.states[sm.current]
      for action in fromState.exitActions: action(sm.context)

      if t.effect.isSome:
        sm.context = t.effect.get()(sm.context)
        sm.context.markTransition(t.name)

      sm.history.add(HistoryEntry(fromState: sm.current, toState: t.toState,
                                   event: event, at: epochTime()))
      sm.current = t.toState

      let toState = sm.states[sm.current]
      for action in toState.entryActions: action(sm.context)

      sm.validateState(sm.current)

      for ensName in t.ensures:
        if ensName in sm.namedPostconditions:
          if not sm.namedPostconditions[ensName].check():
            raise newLegitimacyError("postcondition-failed",
              "'" & ensName & "' failed after '" & t.name & "'")

      return true

  raise newLegitimacyError("no-valid-transition",
    "Event '" & event & "' not permitted from '" & sm.current & "' in '" & sm.name & "'")

proc observe*(sm: StateMachine): AirbaseValue =
  sm.context.markObserved()
  sm.observationLog.add(ObservationEntry(state: sm.current, at: epochTime(), snapshot: $sm.context))
  result = sm.context

proc canFire*(sm: StateMachine, event: EventId): bool =
  for t in sm.transitions:
    if t.fromState == sm.current and t.event == event:
      if t.guard.isNone or t.guard.get()(sm.context): return true
  false

proc permittedEvents*(sm: StateMachine): seq[EventId] =
  var seen = initHashSet[EventId]()
  for t in sm.transitions:
    if t.fromState == sm.current and t.event notin seen:
      if t.guard.isNone or t.guard.get()(sm.context):
        result.add(t.event)
        seen.incl(t.event)

proc summary*(sm: StateMachine): string =
  let events = sm.permittedEvents()
  result = "[" & sm.name & "] state=" & sm.current &
           " | permitted=" & $events &
           " | transitions=" & $sm.history.len

# ============================================================
# AIRSPACE — The Container for All Legitimate Programs
# ============================================================

type
  EffectKind* = enum EffBranch, EffLoop, EffAllocate, EffIO

  EffectDecl* = object
    kind*: EffectKind
    scope*: string
    reason*: string
    bound*: Option[int]

  Airspace* = ref object
    name*: string
    clock*: int64
    emissions*: seq[string]
    machines*: Table[string, StateMachine]
    rules*: seq[string]
    certIssued*: bool
    certName*: string
    certAxioms*: seq[string]
    certPowers*: seq[string]
    certWarnings*: seq[string]
    effectDecls*: seq[EffectDecl]

proc newAirspace*(name: string = "GlobalAirspace"): Airspace =
  Airspace(
    name: name,
    clock: 0'i64,
    emissions: @[],
    machines: initTable[string, StateMachine](),
    rules: @[],
    certIssued: false,
    certAxioms: @[],
    certPowers: @[],
    certWarnings: @[],
    effectDecls: @[]
  )

proc emit*(space: Airspace, label: string, val: AirbaseValue): string {.discardable.} =
  let entry = fmt"[{space.name}@tick={space.clock}] {label}: {val}"
  space.emissions.add(entry)
  echo entry
  result = entry

proc emit*(space: Airspace, label, val: string): string {.discardable.} =
  let entry = fmt"[{space.name}@tick={space.clock}] {label}: {val}"
  space.emissions.add(entry)
  echo entry
  result = entry

proc emissionLog*(space: Airspace): seq[string] = space.emissions

proc issueCert*(space: Airspace, programId: string,
                axioms: seq[string] = @[],
                powers: seq[string] = @[],
                warnings: seq[string] = @[]) =
  space.certIssued = true
  space.certName = programId
  space.certAxioms = axioms
  space.certPowers = powers
  space.certWarnings = warnings

proc certReport*(space: Airspace): string =
  var lines: seq[string]
  lines.add("═══════════════════════════════════════════════════════")
  lines.add("AIRBASE LEGITIMACY CERTIFICATE")
  lines.add("═══════════════════════════════════════════════════════")
  lines.add("Program: " & space.certName)
  if space.certIssued:
    lines.add("Status: ✓ LEGITIMATE")
  else:
    lines.add("Status: ⚠ UNVERIFIED")
  lines.add("")
  
  if space.certAxioms.len > 0:
    lines.add("Axioms satisfied:")
    for axiom in space.certAxioms:
      lines.add("  ✓ " & axiom)
  
  if space.certPowers.len > 0:
    lines.add("Power declarations:")
    for power in space.certPowers:
      lines.add("  ⚡ " & power)
  
  if space.certWarnings.len > 0:
    lines.add("Notices:")
    for warn in space.certWarnings:
      lines.add("  ⚠ " & warn)
  
  lines.add("═══════════════════════════════════════════════════════")
  result = lines.join("\n")

proc registerMachine*(space: Airspace, machine: StateMachine) =
  space.machines[machine.name] = machine

proc currentTick*(space: Airspace): int64 = space.clock

proc advanceClock*(space: Airspace, reason: string, steps: int = 1) =
  space.clock += int64(steps)
  discard space.emit("time.advanced", fmt"{reason} (now at tick {space.clock})")

var globalAirspace* = newAirspace("GlobalAirspace")

