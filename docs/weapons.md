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

### 3. Aim is camera-dependent

`current_aim_point()` calls `get_viewport().get_camera_3d()` — the *active*
camera. This is fine with one local player and will need revisiting for
split-screen, spectating, or any remote helicopter whose weapons need to
resolve an aim point without a camera of its own.

Note also that `HeliProjectile._refresh_guidance_target()` holds a reference to
its `_guidance_source` and re-queries it every frame, so a projectile's
behaviour is coupled to its launcher's lifetime. It uses `is_instance_valid()`,
so a destroyed launcher leaves the projectile flying at its last known target
rather than crashing — but that is the current behaviour by accident rather than
by design.

### 4. Projectiles parent themselves to the current scene

`try_fire()` adds projectiles to `get_tree().current_scene`, falling back to the
root. Once there is a `MultiplayerSpawner`, spawned objects will need a
designated parent node instead.

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
