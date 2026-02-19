## airbase_types.nim
## Airbase type system — constrained, named, legitimate types.
## "Illegal states should be syntactically impossible."

import std/[macros, strutils, options, tables]
import airbase_core

# ============================================================
# BOUNDED INTEGER — integer with compile-declared range
# ============================================================

type
  Bounded*[Low, High: static int] = object
    ## An integer that is ALWAYS within [Low, High].
    ## Cannot be constructed outside the range.
    raw: int

proc bounded*[L, H: static int](v: int): Bounded[L, H] =
  if v < L or v > H:
    raise newLegitimacyError("out-of-bounds",
      "Value " & $v & " outside legal range [" & $L & ", " & $H & "]")
  Bounded[L, H](raw: v)

proc value*[L, H: static int](b: Bounded[L, H]): int = b.raw

proc `$`*[L, H: static int](b: Bounded[L, H]): string =
  $b.raw & " ∈ [" & $L & ", " & $H & "]"


# ============================================================
# NAMED ENUM TYPE — enum where every value must be declared
# ============================================================

macro defEnum*(name: untyped, values: untyped): untyped =
  ## Declare an Airbase enum. Only declared values are legitimate.
  let enumName = name.strVal
  let typeName = ident(enumName)

  var enumFields: seq[NimNode]
  if values.kind == nnkBracket:
    for v in values:
      enumFields.add(ident(v.strVal))
  
  var enumDef = newTree(nnkEnumTy, newEmptyNode())
  for f in enumFields: enumDef.add(f)
  
  result = newStmtList(
    newTree(nnkTypeSection,
      newTree(nnkTypeDef, typeName, newEmptyNode(), enumDef)
    )
  )


# ============================================================
# SCHEMA — a record type with field-level invariants
# ============================================================

type
  FieldSchema* = object
    name*: string
    required*: bool
    validator*: Option[proc(v: AirbaseValue): bool {.closure.}]

  Schema* = object
    name*: string
    fields*: seq[FieldSchema]

proc newSchema*(name: string): Schema =
  Schema(name: name)

proc addField*(s: var Schema, name: string, required = true,
               validator: proc(v: AirbaseValue): bool {.closure.} = nil) =
  s.fields.add(FieldSchema(
    name: name,
    required: required,
    validator: if validator.isNil: none(proc(v: AirbaseValue): bool {.closure.})
               else: some(validator)
  ))

proc validate*(schema: Schema, record: AirbaseValue): LegitimacyProof =
  var proof = LegitimacyProof(status: lsLegitimate, timestamp: 0.0)
  if record.kind != akRecord:
    proof.status = lsViolation
    proof.failedInvariants.add("not-a-record")
    return proof

  for field in schema.fields:
    proof.checkedInvariants.add(field.name)
    if field.required and field.name notin record.fields:
      proof.failedInvariants.add("missing-required-field:" & field.name)
      proof.status = lsViolation
      continue
    if field.name in record.fields and field.validator.isSome:
      if not field.validator.get()(record.fields[field.name]):
        proof.failedInvariants.add("field-invariant-failed:" & field.name)
        proof.status = lsViolation

  result = proof


# ============================================================
# CHANNEL — typed, one-directional message channel with legitimacy
# ============================================================

type
  Channel*[T] = ref object
    name*: string
    queue*: seq[T]
    capacity*: int
    closed*: bool
    sentCount*: int
    receivedCount*: int

proc newChannel*[T](name: string, capacity = 64): Channel[T] =
  Channel[T](name: name, capacity: capacity)

proc send*[T](ch: Channel[T], msg: T) =
  if ch.closed:
    raise newLegitimacyError("channel-closed",
      "Cannot send to closed channel '" & ch.name & "'")
  if ch.queue.len >= ch.capacity:
    raise newLegitimacyError("channel-full",
      "Channel '" & ch.name & "' is at capacity " & $ch.capacity)
  ch.queue.add(msg)
  ch.sentCount.inc

proc recv*[T](ch: Channel[T]): T =
  if ch.closed and ch.queue.len == 0:
    raise newLegitimacyError("channel-empty",
      "Cannot receive from closed empty channel '" & ch.name & "'")
  if ch.queue.len == 0:
    raise newLegitimacyError("channel-empty",
      "Channel '" & ch.name & "' is empty")
  result = ch.queue[0]
  ch.queue.delete(0)
  ch.receivedCount.inc

proc close*[T](ch: Channel[T]) =
  ch.closed = true

proc hasMessages*[T](ch: Channel[T]): bool = ch.queue.len > 0


# ============================================================
# TIMELINE — explicit time with declared tick rate
# ============================================================

type
  Tick* = distinct int64

  Timeline* = ref object
    name*: string
    current*: Tick
    tickRateHz*: float   ## ticks per second
    maxTick*: Option[Tick]
    history*: seq[Tick]
    frozen*: bool

proc `+`*(a, b: Tick): Tick {.borrow.}
proc `-`*(a, b: Tick): Tick {.borrow.}
proc `<`*(a, b: Tick): bool {.borrow.}
proc `<=`*(a, b: Tick): bool {.borrow.}
proc `==`*(a, b: Tick): bool {.borrow.}
proc `$`*(t: Tick): string = "Tick(" & $int64(t) & ")"

proc newTimeline*(name: string, tickRateHz = 1.0, maxTick = -1): Timeline =
  Timeline(
    name: name,
    tickRateHz: tickRateHz,
    current: Tick(0),
    maxTick: if maxTick < 0: none(Tick) else: some(Tick(maxTick)),
    frozen: false
  )

proc advance*(tl: Timeline, by: int64 = 1) =
  ## Time does not advance unless explicitly declared.
  if tl.frozen:
    raise newLegitimacyError("timeline-frozen",
      "Timeline '" & tl.name & "' is frozen — time may not advance")
  if tl.maxTick.isSome and tl.current + Tick(by) > tl.maxTick.get:
    raise newLegitimacyError("timeline-exceeded",
      "Timeline '" & tl.name & "' exceeded max tick " & $tl.maxTick.get)
  tl.history.add(tl.current)
  tl.current = tl.current + Tick(by)

proc freeze*(tl: Timeline) = tl.frozen = true
proc thaw*(tl: Timeline)   = tl.frozen = false

proc secondsElapsed*(tl: Timeline): float =
  float64(int64(tl.current)) / tl.tickRateHz


# ============================================================
# EFFECT — explicit, named side effects (power must pay rent)
# ============================================================

type
  EffectKind* = enum
    ekLog, ekEmit, ekAllocate, ekIO, ekNetwork, ekCustom

  Effect* = object
    kind*: EffectKind
    name*: string
    reason*: string
    scope*: string

  EffectLedger* = ref object
    ## Tracks all declared effects in the system.
    effects*: seq[Effect]
    denied*: seq[string]  ## effect names that are forbidden in this scope

var globalEffectLedger* = EffectLedger()

proc declareEffect*(ledger: EffectLedger, kind: EffectKind, name, reason, scope: string): Effect =
  if name in ledger.denied:
    raise newLegitimacyError("effect-denied",
      "Effect '" & name & "' is not permitted in scope '" & scope & "'")
  let e = Effect(kind: kind, name: name, reason: reason, scope: scope)
  ledger.effects.add(e)
  result = e

proc denyEffect*(ledger: EffectLedger, name: string) =
  ledger.denied.add(name)


# ============================================================
# OBSERVATION — explicit, marked observations
# ============================================================

type
  Observation*[T] = object
    ## A value that can only be used after being explicitly observed.
    raw: T
    observed: bool
    label: string

proc unobserved*[T](v: T, label: string): Observation[T] =
  Observation[T](raw: v, label: label, observed: false)

proc observe*[T](o: var Observation[T]): T =
  o.observed = true
  echo "[OBSERVE:" & o.label & "] observed"
  o.raw

proc isObserved*[T](o: Observation[T]): bool = o.observed


# ============================================================
# GUARD SCOPE — a block that checks invariants on entry/exit
# ============================================================

template guardScope*(label: string, enterCheck: untyped, exitCheck: untyped, body: untyped) =
  block:
    if not (enterCheck):
      raise newLegitimacyError("guard-scope-enter",
        "Guard scope '" & label & "' failed entry check")
    `body`
    if not (exitCheck):
      raise newLegitimacyError("guard-scope-exit",
        "Guard scope '" & label & "' failed exit check")

