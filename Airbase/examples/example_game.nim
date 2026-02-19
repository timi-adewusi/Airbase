## example_game.nim
## Example: A deterministic game simulation using Airbase.
## Demonstrates: simulation, phase, EventQueue, Reactive,
##               BoundedInt, check_suite, declared_loop

import ../src/airbase, tables

airspace GameEngine:

  rule "game state advances only on explicit tick"
  rule "score is non-negative and bounded"
  rule "player health is in [0, 100]"
  rule "events are consumed, not silently dropped"
  rule "all game outcomes are observable"

  # ─── Domain types ────────────────────────────────────
  type
    Player = object
      name: string
      health: BoundedInt   ## [0, 100]
      score: BoundedInt    ## [0, 99999]
      alive: bool

    GameEvent = enum
      evDamage, evHeal, evScore, evLevelUp, evDeath

  proc newPlayer(name: string): Player =
    Player(
      name: name,
      health: bounded(100, 0, 100),
      score: bounded(0, 0, 99999),
      alive: true
    )

  proc applyDamage(p: var Player, dmg: int) =
    pre(dmg >= 0, "damage must be non-negative")
    pre(p.alive, "cannot damage a dead player")

    declared_branch("damage resolution", reason = "death or survive"):
      if p.health.value <= dmg:
        p.health = bounded(0, 0, 100)
        p.alive = false
        emit_obs("player.death", p.name)
      else:
        p.health = bounded(p.health.value - dmg, 0, 100)
        emit_obs("player.damaged", p.name & "-" & $dmg)

  proc applyHeal(p: var Player, amount: int) =
    pre(amount > 0, "heal amount must be positive")

    declared_branch("heal cap", reason = "cannot exceed max health"):
      let newHp = min(p.health.value + amount, 100)
      p.health = bounded(newHp, 0, 100)
      emit_obs("player.healed", p.name & "+" & $amount)

  proc addScore(p: var Player, points: int) =
    pre(points > 0, "score must be positive")
    pre(p.alive, "dead players cannot score")

    let newScore = min(p.score.value + points, 99999)
    p.score = bounded(newScore, 0, 99999)
    emit_obs("player.score", p.name & "=" & $p.score.value)

  # ─── Reactive leaderboard ────────────────────────────
  var leaderboard = reactive(0, "leaderboard.top")

  # ─── Event queue ─────────────────────────────────────
  var gameEvents = newEventQueue[GameEvent](maxSize = 100)

  # ─── Simulation ──────────────────────────────────────
  simulation "DungeonRun":

    phase "initialization":
      var hero   = newPlayer("Hero")
      var goblin = newPlayer("Goblin")
      goblin.health = bounded(30, 0, 100)
      tick("world initialized")

    phase "combat-loop":
      var hero   = newPlayer("Hero")
      var goblin = newPlayer("Goblin")
      goblin.health = bounded(30, 0, 100)

      gameEvents.enqueue("start", evScore, globalAirspace)

      # Verify initial conditions
      check_suite "combat preconditions":
        vc "hero is alive": hero.alive
        vc "goblin is alive": goblin.alive
        vc "hero health is 100": hero.health.value == 100
        vc "goblin health is 30": goblin.health.value == 30

      # Combat rounds — bounded loop
      declared_loop("combat", bound = 10, reason = "max 10 combat rounds"):
        if not goblin.alive or not hero.alive:
          break

        # Hero attacks
        applyDamage(goblin, 12)
        tick("hero-attacks")

        if goblin.alive:
          # Goblin retaliates
          applyDamage(hero, 8)
          tick("goblin-attacks")
        else:
          addScore(hero, 100)
          emit_obs("combat.result", "hero-wins")
          break

        checkBound()

    phase "scoring":
      var hero = newPlayer("Hero")
      hero.score = bounded(100, 0, 99999)

      leaderboard.update(hero.score.value, globalAirspace)
      emit_obs("leaderboard.final", leaderboard.current)
      tick("scoring complete")

    phase "validation":
      # Verify the simulation produced legitimate outputs
      let emissions = globalAirspace.emissionLog()
      must(emissions.len > 0, "simulation must produce observations")
      must(globalAirspace.clock > 0, "time must have advanced")

      emit_obs("simulation.valid", "true")
      tick("validation")

  certify("GameEngine",
    axioms = @[
      "health is bounded [0,100] by BoundedInt",
      "score is bounded [0,99999] by BoundedInt",
      "combat loop is bounded by 10",
      "all outcomes are observable",
      "time advances only on tick"
    ],
    power = @[
      "loop(10): combat",
      "branch: damage resolution",
      "branch: heal cap",
      "branch: combat termination"
    ]
  )

  audit()
