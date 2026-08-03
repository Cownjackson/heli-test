# Weapons

Early, and less settled than the flight model. This document describes what is
actually implemented and the combat decisions that remain open. Flight and
projectile replication are now in place; damage is not.

Files: `heli_weapons.gd`, `heli_projectile.gd`, `heli_explosion.gd`,
`heli_input.gd`, `scenes/projectile.tscn`, `scenes/explosion.tscn`.

---

## What it does today

### Aiming

Aiming is **decoupled from where the helicopter is pointing**. `HeliWeapons`
maintains its own screen-space cursor, `aim_position`, moved by raw mouse motion
and clamped to the viewport with a margin. The HUD draws it as a crosshair.

Note that the same mouse motion also drives the cyclic. Moving the mouse aims
*and* flies simultaneously — every correction to the crosshair is also a cyclic
input, which is what makes lining up a guided shot while manoeuvring so awkward.

**Aim lock** (hold `Alt`, or right mouse button) is the escape hatch. While it
is held the mouse belongs to the weapon cursor alone and the cyclic stops
answering it. Deliberately *only* the mouse is taken away: pedals, collective
and the arrow-key cyclic keep working, so the pilot is never unable to fly. The
crosshair turns blue and gains an outer ring, because a held mode with no tell
is indistinguishable from a broken mouse.

The lock freezes the stick where it was rather than centring it, which matches
the virtual cyclic everywhere else — but it means locking mid-bank leaves the
aircraft turning and the camera still swinging. `aim_lock_stick_return` on
`LocalInputSource` (default 0, i.e. pure freeze) makes the stick drift back to
centre while the lock is held, which levels the aircraft and settles the camera
at the cost of losing the manoeuvre you were in. Which of those is right is a
feel question, not a correctness one.

The locally-owned helicopter projects that cursor through its active camera to
a point `aim_distance` (2000 m) away, then stores the world point in
`HeliInput`. It is re-projected every physics frame, not sampled once at launch,
and remote weapon simulation consumes the transmitted point without a camera.

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

## Design decisions and remaining questions

Unresolved forks are indexed in [open-questions.md](open-questions.md), which is
where ownership is tracked. Settled networking decisions remain here as the
rationale for the implementation.

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

### 2. Hits and projectile motion are server-authoritative

A client click is a reliable request addressed to its own `HeliWeapons` node.
The server verifies that the RPC sender owns that helicopter, then checks ammo
and cooldown. Only the server may accept a volley.

The accepted volley is created at matching paths under `World/Projectiles` on
every peer. Server projectiles run the ignition delay, guidance, lifetime,
raycast collision, and impact impulse. Client projectiles run none of those;
they interpolate streamed server transforms and render trails, sparks, and the
server-triggered explosion. A client therefore cannot create an authoritative
hit by spawning or steering a local projectile.

This deliberately chooses ordinary server authority over lag compensation for
the first LAN build. Guidance already reaches the server through `HeliInput`,
LAN latency does not justify rewind complexity, and placing hit authority on
the firing client would be expensive to undo later.

### 3. Aim travels as a resolved 3D world point

The owning player resolves its 2D cursor through its active camera and writes
the resulting world-space point into `HeliInput`. That point travels in the same
unreliable ordered packet as pitch, roll, yaw, and throttle. The next packet
self-heals a dropped guidance update just as it does a dropped flight input.

`HeliWeapons.current_aim_point()` now reads `control.aim_point`, so a remote
helicopter's weapon never consults the local player's camera. This deliberately
chooses the 3D point over transmitting the 2D cursor: it costs three floats but
is self-contained, is meaningful without the sender's camera, and is exactly
the value projectile guidance needs.

`HeliProjectile._refresh_guidance_target()` still holds a reference to its
`_guidance_source` and re-queries it every frame, so a projectile's behaviour
remains coupled to its launcher's lifetime on the server. If that launcher is
despawned, the missile deliberately continues toward its last known point.
Client replicas hold no guidance-source reference at all.

### 4. Projectiles use one stable runtime parent

Every peer has `World/Projectiles`. The server's reliable volley RPC creates the
same named children under that node on each machine, which gives subsequent
projectile state and explosion RPCs identical node paths. Already-in-flight
projectiles are intentionally not sent to a client that joins late; with a
15-second maximum lifetime, that snapshot complexity is deferred.

---

## Networking boundaries

The following boundaries are now implemented and should remain explicit as the
weapon system grows:

**Keep firing decisions in one function.** `try_fire()` is the server-side path
that checks ammo and cooldown and creates projectiles. Client input reaches it
only through an ownership-checked RPC. Do not add a second spawn path for burst
modes, tests, or special weapons.

**Do not read the viewport, the camera, or `Input` from anything a remote
aircraft also runs.** This is the same rule that keeps `compute_flight()` pure,
applied to weapons. Anything a remote helicopter's weapon needs must arrive as
data, not be looked up from local globals. See question 3 above.

**Clients render projectile replicas; they do not simulate them.** Guidance,
lifetime, collision queries, impact impulses, and explosion timing run only on
the server. Replica cleanup has a timeout only as protection against a lost or
invalid node path; it has no gameplay effect.

**Distinguish cosmetic from authoritative.** Muzzle flash, trails, sparks,
explosions and sound are cosmetic: they can and should fire immediately on the
shooting client, and they never need to agree between machines. Position, hits,
damage and ammo are authoritative. Effects that are wired into the same object
as the collision logic are the hard part of retrofitting lag compensation, so
`heli_explosion.gd` staying a pure effect with no gameplay side effects is worth
preserving.

**Ammo and cooldown are server-owned.** `ammo`, `cooldown_remaining`, and
`reload_progress` advance only offline or on the server. Clients receive a
display snapshot every 0.1 seconds and may request a shot, but the server's
copy is the only value used to accept it.

This mirrors the flight boundary: clients provide explicit intent, the server
owns gameplay state, and remote machines interpolate presentation.

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
