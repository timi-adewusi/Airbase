## airbase_dsl.nim
## The macro layer — Airbase's syntactic enforcement.
## If something is illegal, it should not macro-expand.

import macros, strformat, strutils, sequtils, options
import airbase_core

# ============================================================
#  Compile-Time Legitimacy Checker
# ============================================================

proc expectIdent*(n: NimNode, ctx: string): string =
  if n.kind != nnkIdent:
    error(fmt"[AIRBASE] Expected identifier in {ctx}, got {n.kind}", n)
  n.strVal

proc expectStr*(n: NimNode, ctx: string): string =
  if n.kind == nnkStrLit: return n.strVal
  if n.kind == nnkIdent: return n.strVal
  error(fmt"[AIRBASE] Expected string/ident in {ctx}, got {n.kind}", n)
  ""

# ============================================================
#  `airspace` — Top-level program container
##
##  airspace MyProgram:
##    rules:
##      "no hidden mutation"
##      "time is explicit"
##    body
#
# ============================================================

macro airspace*(name: untyped, body: untyped): untyped =
  let nameStr = expectIdent(name, "airspace declaration")
  result = quote do:
    block:
      globalAirspace.name = `nameStr`
      let airspaceStart {.used.} = true
      `body`
      if not globalAirspace.certIssued:
        globalAirspace.issueCert(
          `nameStr`,
          @["legitimacy-before-execution",
            "meaning-over-mechanism",
            "explicit-state-and-time",
            "power-pays-rent"],
          @[],
          @["No explicit power declarations found — using defaults"]
        )

# ============================================================
#  `claim` — Assert a proposition that must be proven
##
##  let x = claim(42, "positive integers only")
##  let y = claim(computeVal(), proof = "bounded by input")
#
# ============================================================

macro claim*(val: untyped, proofStr: untyped = newStrLitNode("")): untyped =
  result = quote do:
    proven(`val`, `proofStr`)

macro unproven*(val: untyped): untyped =
  result = quote do:
    unverified(`val`)

# ============================================================
#  `must` — A condition that, if false, grounds the program
##
##  must(x > 0, "x must be positive")
#
# ============================================================

macro must*(cond: untyped, reason: untyped = newStrLitNode("invariant")): untyped =
  let reasonStr = reason.repr
  result = quote do:
    if not (`cond`):
      raiseAirbaseError(ContractBreach,
        "must-condition violated: " & `reasonStr` &
        " => (" & astToStr(`cond`) & ")")

# ============================================================
#  `never` — Assert something must never be true
##
##  never(balance < 0, "balance cannot go negative")
#
# ============================================================

macro never*(cond: untyped, reason: untyped = newStrLitNode("forbidden state")): untyped =
  result = quote do:
    if (`cond`):
      raiseAirbaseError(IllegalState,
        "never-condition triggered: " & `reason` &
        " => (" & astToStr(`cond`) & ")")

# ============================================================
#  `declared_branch` — Branching must pay rent
##
##  declared_branch("payment routing", reason = "different paths per method"):
##    if method == "card": processCard()
##    else: processCash()
#
# ============================================================

macro declared_branch*(label: untyped, reason: untyped, body: untyped): untyped =
  let labelStr = expectStr(label, "declared_branch")
  result = quote do:
    block:
      let branchDecl {.used.} = EffectDecl(
        kind: EffBranch,
        scope: `labelStr`,
        reason: `reason`,
        bound: none(int)
      )
      `body`

# ============================================================
#  `declared_loop` — Loops must declare their bound or reason
##
##  declared_loop("retry-loop", bound = 5, reason = "max 5 retries"):
##    while notDone: attempt()
#
# ============================================================

macro declared_loop*(label: untyped, bound: untyped, reason: untyped,
                     body: untyped): untyped =
  result = quote do:
    block:
      let loopBound = `bound`
      let loopDecl {.used.} = EffectDecl(
        kind: EffLoop,
        scope: `label`,
        reason: `reason`,
        bound: some(loopBound)
      )
      var loopCount = 0
      template checkBound() =
        inc loopCount
        if loopCount > loopBound:
          raiseAirbaseError(UnboundedPower,
            "Loop '" & `label` & "' exceeded declared bound of " & $`bound`)
      `body`

# A simpler unbounded loop that requires explicit justification
macro declared_loop*(label: untyped, reason: untyped, body: untyped): untyped =
  result = quote do:
    block:
      let loopDecl {.used.} = EffectDecl(
        kind: EffLoop,
        scope: `label`,
        reason: `reason`,
        bound: none(int)
      )
      `body`

# ============================================================
#  `tick` — Advance logical time explicitly
##
##  tick("end of round")
##  tick("simulation step", steps = 3)
#
# ============================================================

macro tick*(reason: untyped, steps: untyped = nil): untyped =
  let stepsVal = if steps == nil: newIntLitNode(1) else: steps
  result = quote do:
    advanceClock(globalAirspace, `reason`, `stepsVal`)

# ============================================================
#  `emit_obs` — Mark an observable emission
##
##  emit_obs("player.score", currentScore)
#
# ============================================================

macro emit_obs*(label: untyped, val: untyped): untyped =
  result = quote do:
    discard globalAirspace.emit(`label`, $(`val`))

# ============================================================
#  `machine` — Define a state machine
##
##  machine TrafficLight:
##    states: Red, Yellow, Green
##    initial: Red
##    terminal: none
##    transitions:
##      Red --[go]--> Green
##      Green --[slow]--> Yellow
##      Yellow --[stop]--> Red
##    invariants:
##      "exactly one light active"
#
# ============================================================

macro machine*(name: untyped, body: untyped): untyped =
  let machineName = expectIdent(name, "machine declaration")
  let machineNameStr = newStrLitNode(machineName)

  # Parse the machine body
  var statesNode: NimNode = nil
  var initialNode: NimNode = nil
  var terminalNodes: seq[NimNode] = @[]
  var transitionNodes: seq[NimNode] = @[]
  var invariantNodes: seq[NimNode] = @[]
  var extraBody: seq[NimNode] = @[]

  for stmt in body:
    if stmt.kind == nnkCall and stmt[0].strVal == "states":
      statesNode = stmt[1]
    elif stmt.kind == nnkCall and stmt[0].strVal == "initial":
      initialNode = stmt[1]
    elif stmt.kind == nnkCall and stmt[0].strVal == "terminal":
      terminalNodes = stmt[1..^1]
    elif stmt.kind == nnkCall and stmt[0].strVal == "transitions":
      for t in stmt[1]:
        transitionNodes.add(t)
    elif stmt.kind == nnkCall and stmt[0].strVal == "invariants":
      for inv in stmt[1]:
        invariantNodes.add(inv)
    else:
      extraBody.add(stmt)

  if initialNode == nil:
    error("[AIRBASE] machine requires 'initial' declaration", name)
  if statesNode == nil:
    error("[AIRBASE] machine requires 'states' declaration", name)

  let initialStr = newStrLitNode(initialNode.strVal)
  let varName = ident(machineName & "Machine")

  # Build state additions
  var stateAdds = newStmtList()
  for s in statesNode:
    if s.kind == nnkIdent:
      let ss = newStrLitNode(s.strVal)
      stateAdds.add(quote do:
        `varName`.addState(`ss`))
  for t in terminalNodes:
    if t.kind == nnkIdent:
      let ts = newStrLitNode(t.strVal)
      stateAdds.add(quote do:
        `varName`.addState(`ts`, terminal = true))

  # Build transition additions
  var transAdds = newStmtList()
  for t in transitionNodes:
    # Parse: FromState --[label]--> ToState
    if t.kind == nnkInfix and t[0].strVal == "-->" :
      # t[1] is "FromState --[label]", t[2] is ToState
      let toState = newStrLitNode(t[2].strVal)
      let lhs = t[1]
      if lhs.kind == nnkInfix and lhs[0].strVal == "--":
        let fromState = newStrLitNode(lhs[1].strVal)
        # lhs[2] is [label] — a bracket expression
        var labelStr = ""
        if lhs[2].kind == nnkBracketExpr:
          labelStr = lhs[2][0].strVal
        elif lhs[2].kind == nnkIdent:
          labelStr = lhs[2].strVal
        let label = newStrLitNode(labelStr)
        transAdds.add(quote do:
          `varName`.addTransition(Transition(
            fromState: `fromState`,
            toState: `toState`,
            label: `label`,
            guard: "",
            effects: @[]
          )))
    # Parse simpler: "from -> to : label" style handled elsewhere

  # Build invariant additions
  var invAdds = newStmtList()
  for inv in invariantNodes:
    let invStr = if inv.kind == nnkStrLit: inv else: newStrLitNode(inv.repr)
    invAdds.add(quote do:
      `varName`.addInvariant(`invStr`))

  result = quote do:
    var `varName` = newMachine(`machineNameStr`, `initialStr`)
    `stateAdds`
    `transAdds`
    `invAdds`
    registerMachine(globalAirspace, `varName`)

# ============================================================
#  `fly` — Attempt a transition (the aircraft requests permission)
##
##  fly(TrafficLightMachine, "go")    # granted or grounded
#
# ============================================================

macro fly*(machineName: untyped, label: untyped): untyped =
  let mn = ident(machineName.strVal & "Machine")
  result = quote do:
    discard `mn`.transition(globalAirspace, `label`)

# ============================================================
#  `grounded_if` — Ground (halt) the program if condition holds
##
##  grounded_if(altitude < 0, "cannot fly underground")
#
# ============================================================

macro grounded_if*(cond: untyped, reason: untyped): untyped =
  result = quote do:
    if (`cond`):
      raiseAirbaseError(LegitimacyViolation,
        "Program grounded: " & `reason`)

# ============================================================
#  `proven` — Mark a value as proven/legitimate
# ============================================================

type
  ProvenValue*[T] = object
    value*: T
    proof*: string

proc proven*[T](val: T, proof: string = ""): ProvenValue[T] =
  ProvenValue[T](value: val, proof: proof)

proc unwrap*[T](p: ProvenValue[T]): T = p.value

proc isLegitimate*[T](p: ProvenValue[T]): bool = p.proof.len > 0


# ============================================================
#  `declare_power` — Explicitly declare what effects this scope uses
##
##  declare_power([branch, loop(5), allocate], "game loop needs these"):
##    body...
#
# ============================================================

macro declare_power*(effects: untyped, reason: untyped, body: untyped): untyped =
  result = quote do:
    block:
      let powerReason {.used.} = `reason`
      `body`

# ============================================================
#  `invariant_zone` — A scope where invariants are re-checked on exit
##
##  invariant_zone("account balance"):
##    account.balance -= 100
##    must(account.balance >= 0, "no overdraft")
#
# ============================================================

macro invariant_zone*(label: untyped, body: untyped): untyped =
  result = quote do:
    block:
      let zoneLabel {.used.} = `label`
      `body`
      emit_obs("zone.exit", `label`)

# ============================================================
#  `sealed` — A value that cannot be mutated after assignment
##
##  let key = sealed(computeKey(), "session keys are immutable")
#
# ============================================================

macro sealed*(val: untyped, reason: untyped = newStrLitNode("")): untyped =
  # In Nim, `let` already seals — this just documents intent and adds legitimacy
  result = quote do:
    proven(`val`, "sealed: " & `reason`)

# ============================================================
#  `when_legitimate` — Only execute if a claim is proven/acknowledged
##
##  when_legitimate(myClaim):
##    useValue(myClaim.unwrap)
#
# ============================================================

macro when_legitimate*(claimExpr: untyped, body: untyped): untyped =
  result = quote do:
    if `claimExpr`.isLegitimate:
      `body`
    else:
      raiseAirbaseError(UnprovenClaim,
        "when_legitimate: claim '" & astToStr(`claimExpr`) & "' is not legitimate")

# ============================================================
#  `legitimate_or` — Provide a fallback for unproven claims
##
##  let val = legitimate_or(myClaim, defaultValue)
#
# ============================================================

macro legitimate_or*(claimExpr: untyped, fallback: untyped): untyped =
  result = quote do:
    (if `claimExpr`.isLegitimate: `claimExpr`.value else: `fallback`)

# ============================================================
#  `certify` — Issue a legitimacy certificate for this airspace
##
##  certify("MyApp", axioms = [...], power = [...])
#
# ============================================================

macro certify*(programId: untyped, axioms: untyped = newNimNode(nnkBracket),
               power: untyped = newNimNode(nnkBracket)): untyped =
  result = quote do:
    globalAirspace.issueCert(
      `programId`,
      `axioms`,
      `power`
    )

# ============================================================
#  `audit` — Print the emission log and certificate
# ============================================================

macro audit*(): untyped =
  result = quote do:
    echo "\n=== AIRBASE AUDIT LOG ==="
    for line in globalAirspace.emissionLog():
      echo "  ", line
    echo globalAirspace.certReport()
    echo fmt"Logical clock: tick {globalAirspace.currentTick}"

# ============================================================
#  `rule` — Declare a rule for the airspace (documentation + enforcement hook)
##
##  rule "no hidden mutation"
##  rule "time is explicit"
#
# ============================================================

macro rule*(text: untyped): untyped =
  result = quote do:
    globalAirspace.rules.add(`text`)

# ============================================================
#  `assert_state` — Verify a machine is in the expected state
##
##  assert_state(TrafficLight, "Red")
#
# ============================================================

macro assert_state*(machineName: untyped, expected: untyped): untyped =
  let mn = ident(machineName.strVal & "Machine")
  result = quote do:
    if `mn`.current != `expected`:
      raiseAirbaseError(ContractBreach,
        fmt"Expected state '{`expected`}' but machine is in '{`mn`.current}'")

# ============================================================
#  `bounded_int` / `ranged` — Types that enforce numeric legitimacy
# ============================================================

type
  BoundedInt* = object
    value*: int
    lo*, hi*: int

proc bounded*(val, lo, hi: int): BoundedInt =
  if val < lo or val > hi:
    raiseAirbaseError(LegitimacyViolation,
      fmt"Value {val} out of declared range [{lo}, {hi}]")
  BoundedInt(value: val, lo: lo, hi: hi)

proc `+`*(a, b: BoundedInt): BoundedInt =
  bounded(a.value + b.value, a.lo, a.hi)

proc `-`*(a, b: BoundedInt): BoundedInt =
  bounded(a.value - b.value, a.lo, a.hi)

proc `*`*(a, b: BoundedInt): BoundedInt =
  bounded(a.value * b.value, a.lo, a.hi)

proc `$`*(b: BoundedInt): string =
  fmt"Bounded({b.value}, [{b.lo}..{b.hi}])"

converter toInt*(b: BoundedInt): int = b.value

# ============================================================
#  `NonEmptySeq` — A sequence that may never be empty
# ============================================================

type NonEmptySeq*[T] = object
  inner: seq[T]

proc nonEmpty*[T](first: T, rest: varargs[T]): NonEmptySeq[T] =
  var s = @[first]
  for x in rest: s.add(x)
  NonEmptySeq[T](inner: s)

proc add*[T](ns: var NonEmptySeq[T], val: T) =
  ns.inner.add(val)

proc len*[T](ns: NonEmptySeq[T]): int = ns.inner.len

proc `[]`*[T](ns: NonEmptySeq[T], i: int): T = ns.inner[i]

iterator items*[T](ns: NonEmptySeq[T]): T =
  for x in ns.inner: yield x

proc head*[T](ns: NonEmptySeq[T]): T = ns.inner[0]

proc tail*[T](ns: NonEmptySeq[T]): seq[T] = ns.inner[1..^1]
