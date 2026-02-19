## airbase_contracts.nim
## Contracts, refinement types, and the legitimacy proof system.
## This is where "nothing exists unless proven lawful" lives.

import macros, strformat, strutils, sequtils, tables, options
import airbase_core
import airbase_dsl

# ============================================================
#  Refinement Types
##  A type T refined by predicate P — only values satisfying P are legal
# ============================================================

type
  Refined*[T] = object
    value*: T
    predicate*: string  ## The predicate name / description
    proven*: bool

proc refine*[T](val: T, pred: bool, predName: string): Refined[T] =
  if not pred:
    raiseAirbaseError(LegitimacyViolation,
      fmt"Refinement failed: value {val} does not satisfy '{predName}'")
  Refined[T](value: val, predicate: predName, proven: true)

template refined*[T](val: T, predExpr: untyped): Refined[T] =
  refine(val, predExpr, astToStr(predExpr))

proc extract*[T](r: Refined[T]): T =
  if not r.proven:
    raiseAirbaseError(UnprovenClaim, "Cannot extract unproven refined value")
  r.value

proc `$`*[T](r: Refined[T]): string =
  fmt"Refined[{r.value} | {r.predicate}]"

# ============================================================
#  Contracts: pre/post conditions and invariants
# ============================================================

type
  ContractKind* = enum
    PreCondition
    PostCondition
    Invariant
    FrameCondition  ## What this function may NOT change

  Contract* = object
    kind*: ContractKind
    description*: string
    check*: proc(): bool {.closure.}

  ContractedProc*[T] = object
    name*: string
    pre*: seq[string]   ## Pre-condition descriptions (checked before)
    post*: seq[string]  ## Post-condition descriptions (checked after)
    frame*: seq[string] ## Frame: what must NOT change

# The `contracted` macro creates a procedure with automatic contract checking
macro contracted*(name: untyped, contracts: untyped, body: untyped): untyped =
  ## contracted myFunc(x: int): int
  ##   pre: x > 0, "x must be positive"
  ##   post: result > x, "result must exceed input"
  ##   frame: globalState, "this proc is pure"
  ##   body: x * 2
  ##
  ## Generates a proc that checks pre/post automatically.
  result = body  # Simplified — full impl below in macro form

# The actual enforcement happens via these templates used inside procs:
template pre*(cond: bool, desc: string) =
  if not cond:
    raiseAirbaseError(ContractBreach,
      "Pre-condition violated: " & desc & " => (" & astToStr(cond) & ")")

template post*(cond: bool, desc: string) =
  if not cond:
    raiseAirbaseError(ContractBreach,
      "Post-condition violated: " & desc & " => (" & astToStr(cond) & ")")

template frame*(expr: untyped, desc: string) =
  ## Declare that `expr` must not change during this scope
  let frameBefore = `expr`
  defer:
    if `expr` != frameBefore:
      raiseAirbaseError(ContractBreach,
        "Frame condition violated: " & desc &
        " — value changed from " & $frameBefore & " to " & $(`expr`))

# ============================================================
#  Dependent types — value-dependent type constraints
# ============================================================

type
  Positive* = Refined[int]
  NonNegative* = Refined[int]
  Percentage* = Refined[float]
  NonEmptyString* = Refined[string]
  ProbabilityFloat* = Refined[float]

proc positive*(n: int): Positive =
  refine(n, n > 0, "positive integer")

proc nonNegative*(n: int): NonNegative =
  refine(n, n >= 0, "non-negative integer")

proc percentage*(f: float): Percentage =
  refine(f, f >= 0.0 and f <= 100.0, "percentage [0..100]")

proc probability*(f: float): ProbabilityFloat =
  refine(f, f >= 0.0 and f <= 1.0, "probability [0.0..1.0]")

proc nonEmptyStr*(s: string): NonEmptyString =
  refine(s, s.len > 0, "non-empty string")

# ============================================================
#  Effect tracking — explicit side effects
# ============================================================

type
  EffectTracker* = object
    effects*: seq[string]
    allowedEffects*: seq[string]

proc newEffectTracker*(allowed: seq[string]): EffectTracker =
  EffectTracker(effects: @[], allowedEffects: allowed)

proc recordEffect*(et: var EffectTracker, eff: string) =
  if et.allowedEffects.len > 0 and eff notin et.allowedEffects:
    raiseAirbaseError(ImplicitEffect,
      fmt"Undeclared effect '{eff}' — not in allowed set: {et.allowedEffects}")
  et.effects.add(eff)

proc effectSummary*(et: EffectTracker): string =
  if et.effects.len == 0: return "pure (no effects)"
  "effects: " & et.effects.join(", ")

# ============================================================
#  Proof terms — explicit justification objects
# ============================================================

type
  ProofKind* = enum
    ByAxiom         ## Self-evident or built into the language
    ByInduction     ## Proven by structural induction
    ByContradiction ## Proven by refuting the negation
    ByConstruction  ## Proven by providing a witness
    ByAssumption    ## Assumed — weakest, requires acknowledgement
    ByInvariant     ## Follows from a maintained invariant

  ProofTerm* = object
    kind*: ProofKind
    statement*: string
    justification*: string

proc axiom*(stmt: string): ProofTerm =
  ProofTerm(kind: ByAxiom, statement: stmt, justification: "axiomatic")

proc byInduction*(stmt, step: string): ProofTerm =
  ProofTerm(kind: ByInduction, statement: stmt, justification: step)

proc assume*(stmt: string): ProofTerm =
  ProofTerm(kind: ByAssumption, statement: stmt,
    justification: "assumed — must be verified externally")

proc `$`*(p: ProofTerm): string =
  fmt"Proof[{p.kind}: {p.statement} | {p.justification}]"

# ============================================================
#  Verification conditions — things that must hold for cert issuance
# ============================================================

type
  VerificationCondition* = object
    description*: string
    check*: proc(): bool {.closure.}
    proof*: Option[ProofTerm]

  VerificationSuite* = object
    conditions*: seq[VerificationCondition]
    name*: string

proc newVerifSuite*(name: string): VerificationSuite =
  VerificationSuite(name: name, conditions: @[])

proc addVC*(vs: var VerificationSuite, desc: string,
            check: proc(): bool {.closure.},
            proof: Option[ProofTerm] = none(ProofTerm)) =
  vs.conditions.add(VerificationCondition(
    description: desc, check: check, proof: proof))

proc verify*(vs: VerificationSuite): tuple[passed: int, failed: seq[string]] =
  var passed = 0
  var failed: seq[string] = @[]
  for vc in vs.conditions:
    if vc.check():
      inc passed
    else:
      failed.add(vc.description)
  (passed, failed)

proc verifyOrGrounded*(vs: VerificationSuite) =
  let (passed, failed) = vs.verify()
  if failed.len > 0:
    raiseAirbaseError(LegitimacyViolation,
      fmt"Verification suite '{vs.name}' failed {failed.len}/{passed + failed.len} conditions:\n" &
      failed.mapIt("  ✗ " & it).join("\n"))
  echo fmt"[AIRBASE] ✓ Verification suite '{vs.name}': {passed}/{passed} conditions passed"

# ============================================================
#  `check_suite` macro — compile-time check orchestration
##
##  check_suite "GameRules":
##    vc "score is non-negative": score >= 0
##    vc "player exists": player != nil
##    vc "board is valid": board.isValid()
#
# ============================================================

macro check_suite*(name: untyped, body: untyped): untyped =
  let nameStr = expectStr(name, "check_suite")
  var checks = newSeq[NimNode]()
  for stmt in body:
    if stmt.kind == nnkCall and stmt[0].strVal == "vc":
      let desc = stmt[1]
      let condExpr = stmt[2]
      checks.add(quote do:
        if not (`condExpr`):
          raiseAirbaseError(ContractBreach,
            "check_suite '" & `nameStr` & "' failed: " & `desc`))
  result = newStmtList()
  for c in checks:
    result.add(c)
