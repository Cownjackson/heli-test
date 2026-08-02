# Weapons

Early, and less settled than the flight model. This document describes what is
actually implemented and — more importantly — the design questions that are
still open, several of which need answering before networking goes in.

Files: `heli_weapons.gd`, `heli_projectile.gd`, `heli_explosion.gd`,
`scenes/projectile.tscn`, `scenes/explosion.tscn`.

---

## What it does today

### Aiming

Aiming is **decoupled from where the helicopter is pointing**. `HeliWeapons`
maintains its own screen-space cursor, `aim_position`, moved by raw mouse motion
and clamped to the viewport with a margin. The HUD draws it as a crosshair.

Note that the same mouse motion also drives the cyclic. Moving the mouse aims
*and* flies simultaneously; they are not modal.

`current_aim_point()` projects that 2D cursor through the active camera to a
point `aim_distance` (2000 m) away in the world. It is re-projected every
physics frame, not sampled once at launch.

### Firing

Left mouse button. One ammo unit fires **both barrels at once** — the two
muzzles are a visual pair, not two independent guns.

| Property | Value | Meaning |
|---|---|---|
| `max_ammo` | 8 | Volleys, not individual rounds |
| `fire_cooldown` | 3.0 s | Between volleys |
| `reload_seconds_per_round` | 2.0 s | Ammo regenerates one unit at a time |

Ammo trickles back continuously rather than reloading a magazine, so there is no
reload state to be caught in — you are always at least partially armed.

### The projectile

Despite the name, this is **not a gun round — it is a guided missile.** It:

1. Drops for `ignition_delay` (0.6 s) under `drop_acceleration`, inheriting the
   launching helicopter's velocity.
2. Ignites, accelerates to `speed` (65 m/s), and starts trailing particles.
3. Steers toward the *live* cursor position at up to `guidance_turn_rate`
   (0.7 rad/s). Because the cursor is re-read every frame, the pilot keeps
   steering it after launch.
4. Expires after `lifetime` (15 s), or explodes on contact.

Collision uses a ray between successive physics positions rather than a physics
body, so the projectile cannot tunnel through thin scenery at 65 m/s. The
shooter's own collider is excluded at launch.

> **Naming inconsistency, worth fixing.** The class doc calls these "paired
> helicopter guns", the HUD says "LMB twin guns", and `heli_projectile.gd`
> describes a "tracer" — but the behaviour is a slow, steerable, player-guided
> missile with an ignition delay. Whichever way this is resolved, the code and
> the HUD should agree, because the naming currently sets the wrong expectation
> for anyone reading it cold.

---

## Open design questions

These are indexed in [open-questions.md](open-questions.md), which is where
ownership is tracked. The reasoning stays here; when one of them is settled, the
decision moves to [architecture.md](architecture.md) and its row in the registry
is removed.

### 1. There is no damage model at all

This is the largest gap. A projectile hit calls
`apply_central_impulse(direction * impact_impulse)` with `impact_impulse = 18`.
Against a 900 kg helicopter that is a nudge — roughly 0.02 m/s of velocity
change. Nothing tracks health, and nothing can be destroyed by being shot.

The only way anything dies is `Helicopter._check_impact()`, which needs a summed
contact impulse above `crash_impact_speed * mass` — 5850 for the current
airframe, against the 18 a projectile delivers. So the target helicopter in
`world.tscn` is presently invulnerable to gunfire.

Deciding between "projectiles do damage to a health pool" and "projectiles do
enough impulse to make you crash yourself" is a real gameplay fork, and the
second option is far more interesting given the flight model already has a
convincing crash system. It has not been decided.

### 2. Hit authority is undecided, and this blocks networking

Right now the firing client spawns projectiles locally and resolves their
collisions locally. That cannot survive networking as written. The options are
the usual three:

- **Server-authoritative hits.** Client fires a cosmetic tracer immediately; the
  server simulates the real projectile and decides. Safe, but a visible
  disagreement when they diverge — and these projectiles are *steerable*, so the
  client's guidance input has to be streamed too.
- **Client-authoritative hits.** Trivial to implement, trivially cheatable.
- **Lag-compensated / rewind hits.** The server rewinds to the shooter's view.
  Standard for hitscan, considerably harder for a 15-second guided projectile.

The guidance mechanic makes this materially harder than a normal shooter would
be, because a projectile's whole trajectory depends on continuous input from its
owner for up to 15 seconds after launch. **This should be decided before
networking work starts, not during it.**

Two things narrow the choice. First, if guidance travels through `HeliInput` as
proposed in question 3, the "client's guidance input has to be streamed too"
objection to server-authoritative hits mostly dissolves — the server is already
receiving that stream in order to fly the aircraft, and a guided projectile
becomes an ordinary server-simulated object driven by an input the server holds.

Second, the first networked build is planned as LAN-only and
server-authoritative — see
[architecture.md](architecture.md#but-the-first-playable-test-should-still-be-option-a-over-lan).
At LAN latency, server-authoritative hits need no lag compensation at all to
feel correct, which makes the third option something to defer rather than
design for now. The trap is treating that as licence to resolve hits on the
firing client because it looks identical at 0 ms; it will not look identical
later, and authority is the expensive thing to move.

### 3. Aim is camera-dependent, and this breaks the moment there are two players

`current_aim_point()` calls `get_viewport().get_camera_3d()` — the *active*
camera, meaning the local player's. That is a single global, but it is being
used to answer a per-helicopter question.

Nothing misbehaves today, for two reasons that both disappear under networking:
`helicopter.gd` sets `_camera.current` only on the locally-owned aircraft, and
`HeliWeapons._unhandled_input()` gates firing on `is_local_authority()`. So the
target helicopter never fires and there is only ever one active camera.

Once a second real player exists, a remote helicopter's projectiles must still
be steered on this machine — and `current_aim_point()` will hand them **the
local player's crosshair**. Every remote missile in the world would fly at
whatever you personally are looking at. This is not a rendering nicety; it is a
trajectory error, and it needs fixing before networking rather than after.

**Recommended shape of the fix: the aim point is pilot input.**

`HeliInput` already exists to carry pilot intent from whoever owns an aircraft,
already travels as absolute positions, and is already sized to send every
physics tick. The aim cursor is exactly that kind of value. Extending it means:

- `current_aim_point()` reads from `control` rather than from the viewport, so
  it resolves identically for local and remote aircraft, with or without a
  camera
- no separate channel, no separate reliability story, no extra RPC
- guidance updates arrive at the same rate and in the same order as the flight
  inputs they are correlated with

The open sub-question is *what* to put in `HeliInput`: the 2D screen cursor
(compact, but only meaningful alongside the sender's camera, which the receiver
does not have) or the resolved 3D world point (larger, self-contained, and what
the projectile actually wants). The world point is the stronger default —
resolve on the owner, transmit the answer. See registry row 4.

Note also that `HeliProjectile._refresh_guidance_target()` holds a reference to
its `_guidance_source` and re-queries it every frame, so a projectile's
behaviour is coupled to its launcher's lifetime. It uses `is_instance_valid()`,
so a destroyed launcher leaves the projectile flying at its last known target
rather than crashing — but that is the current behaviour by accident rather than
by design. Routing guidance through `HeliInput` removes this coupling as a side
effect, since the projectile would read a value rather than call an object.

### 4. Projectiles parent themselves to the current scene

`try_fire()` adds projectiles to `get_tree().current_scene`, falling back to the
root. Once there is a `MultiplayerSpawner`, spawned objects will need a
designated parent node instead.

---

## Working on weapons ahead of networking

Networking is not in yet, and weapons work should not wait for it. But a few
habits now decide whether the weapon system needs a rewrite later or just a
wiring pass. In rough order of how expensive they are to retrofit:

**Keep firing decisions in one function.** `try_fire()` is currently the single
place that checks ammo and cooldown and creates projectiles. That is exactly
right, and it is what lets the whole thing become server-authoritative by
changing one call site. Adding a second path that spawns a projectile — a
special weapon, a burst mode, a test button — is the change that would hurt.

**Do not read the viewport, the camera, or `Input` from anything a remote
aircraft also runs.** This is the same rule that keeps `compute_flight()` pure,
applied to weapons. Anything a remote helicopter's weapon needs must arrive as
data, not be looked up from local globals. See question 3 above.

**Assume projectiles will be spawned by something else.** `try_fire()` adds
children to `get_tree().current_scene`. Under a `MultiplayerSpawner` the parent
becomes a designated node and spawning becomes a server-side call. Keeping the
parent lookup in one place — rather than sprinkling `add_child` around — makes
that a one-line change.

**Distinguish cosmetic from authoritative.** Muzzle flash, trails, sparks,
explosions and sound are cosmetic: they can and should fire immediately on the
shooting client, and they never need to agree between machines. Position, hits,
damage and ammo are authoritative. Effects that are wired into the same object
as the collision logic are the hard part of retrofitting lag compensation, so
`heli_explosion.gd` staying a pure effect with no gameplay side effects is worth
preserving.

**Ammo and cooldown will move.** `ammo`, `cooldown_remaining` and
`reload_progress` currently advance in `_process()` on every peer independently.
They will eventually be owned by the server and replicated. Nothing needs to
change now, but avoid building anything that assumes they are locally writable.

None of this asks for networking code. It asks for the weapon to stay a function
of its own state plus explicit input — which is the same property that made the
flight model straightforward to plan around.

---

## Tuning notes

- `guidance_turn_rate` is the knob that decides whether these feel like missiles
  or like remote-controlled drones. At 0.7 rad/s you get a visible curved
  intercept rather than a snap onto the cursor; raising it makes them
  progressively harder to dodge.
- `ignition_delay` combined with `initial_drop_speed` gives the launch its
  drop-then-light character. Shortening it makes close-range shots much easier.
- `fire_cooldown` at 3 s is doing most of the balancing work. With eight volleys
  available it is the cooldown, not the ammo count, that limits output.
