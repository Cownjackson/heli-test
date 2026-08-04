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

#### The crosshair and the stick disagree

**Known defect, tracked as [open question 9](open-questions.md).** The crosshair
drifts off centre during ordinary flying, so a centred stick no longer looks
like a centred stick — which makes levelling out after a sharp turn read wrong.

The cause is that `LocalInputSource.stick` and `HeliWeapons.aim_position` are
**two independent integrators over the same `event.relative`**, with different
scales and different clamp *shapes*:

| | `stick` | `aim_position` |
|---|---|---|
| Scale | `mouse_sensitivity` 0.0022 | `aim_cursor_sensitivity` 1.15 |
| Clamp | unit **disc** (`limit_length`) | viewport **rectangle** |
| Full deflection, X | 455 px of mouse | 675 px |
| Full deflection, Y | 455 px | 370 px |

On the 1600×900 viewport they therefore saturate at different times and in
opposite senses. Horizontally the stick maxes out first and the cursor keeps
travelling, so dragging right and then back 455 px leaves the stick centred and
the crosshair ~250 px right of centre. Vertically it inverts — the cursor hits
the wall first. Diagonally they disagree without saturating at all, because one
clamps to a disc and the other to a rectangle. None of this is drift; it is
clipping, and it is fully reproducible.

The fix direction is to **stop integrating twice** and derive the cursor from
the stick. What is *not* decided is how the aim lock reconverges: while the lock
is held the two must diverge, since that is the entire feature. Candidates are a
lock offset that decays back to the stick over ~0.5 s on release, one that
persists until `R`, or a snap. See also open question 10 — if the screen edge
becomes a camera-yaw control rather than a wall, the clamp behind this defect
stops existing.

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

### 1. Damage: both models are implemented, so the fork can be flown

The question was health pool *or* blast big enough to make you crash yourself.
Rather than pick blind, a hit now does **both**, and each half has a multiplier
on the receiving airframe that can be turned down to zero:

- `Helicopter.damage_multiplier = 0` → pure blast. The health pool stops
  mattering and the only way to kill anyone is to throw them into the ground.
- `Helicopter.impulse_multiplier = 0` → pure health pool. Hits are bookkeeping
  and never disturb the target's flying.

So the fork is now a slider, not a rewrite. Whichever way it resolves, the
losing half gets deleted rather than left at zero.

**Baseline numbers** (all measured, commit `153b0af`+):

| Value | Default | Effect |
|---|---|---|
| `Helicopter.max_health` | 100 | — |
| `HeliProjectile.damage` | 20 | Five connecting missiles are a wreck |
| `HeliProjectile.blast_impulse` | 7200 N·s | 8.6 m/s of kick on the 900 kg airframe |
| `HeliProjectile.blast_lift` | 0.45 | Fraction of the blast redirected world-up |
| `HeliProjectile.blast_spin` | 0.35 | Fraction of the hit's real lever arm kept |
| `Helicopter.double_hit_bonus` | 1.5 | Second missile of the *same* volley |

Note the baseline is five *missiles*, not five volleys — which is what makes a
fully-connecting volley worth more than a split one without any special casing.
Both barrels landing is 20 + 20×1.5 = **50 damage and 21.5 m/s**, so two clean
volleys are a kill. If five *volleys* was the intent instead, that is one drag
of the damage slider to 10.

**The double-hit bonus** is why `HeliProjectile` carries `shooter_peer_id` and
`volley_id`. The target remembers the last volley that hit it and for
`double_hit_window` (1.5 s) treats a second missile with the same key as part of
the same shot. The window only has to cover the spread in flight times between
two barrels that left together, not the fire cooldown.

**`blast_spin` is the interesting dial.** The blast is applied at the hit
position rather than centrally, so leverage is free and physical: a tail-boom
hit tumbles you and a nose hit does not. At 1.0 the full torque of a 7200 N·s
impulse on a 3 m arm is a violent, probably unrecoverable spin, which is why the
default keeps only a third of it.

Blast, damage and the wreck decision all run **only on the server**, inside
`Helicopter.apply_damage()`. Clients receive `health` and `is_crashed` in the
ordinary state packet and the resulting motion as replicated transforms; there
is no client-side damage code at all.

`_check_impact()` is untouched and still writes the airframe off above
`crash_impact_speed` (6.5 m/s) of contact — so "blast them into the ground"
kills through the existing crash system rather than a second death path.

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

## Tuning combat live

`F5` toggles the developer panel (top right). Every combat value above is a
slider on it, and each one writes to **SceneTree metadata as well as to live
nodes** — helicopters and projectiles are spawned continuously, so pushing a
value only to what already exists would be undone by the next respawn or the
next volley. `DeveloperSettings.tuned()` is the read side, called from
`_ready()` on both classes.

Adding a knob is one entry in `DeveloperSettings.ROWS` plus a case in
`_apply_live()`. The rows are generated rather than authored in the scene
specifically so that stays true.

**These sliders only bite on the host.** Damage, blast and health are evaluated
exclusively on the server, so dragging them on a client changes nothing anyone
can see. Tune on the machine that pressed Host.

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
