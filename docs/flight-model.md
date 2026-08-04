# Flight model

Arcade-lite, but it obeys helicopter rules. The goal is a machine that feels
like a helicopter to fly rather than a simulator that is accurate on paper.

All of it lives in `Helicopter.compute_flight()`, which must stay a pure
function — see [architecture.md](architecture.md#1-compute_flight-must-stay-pure)
before editing it.

---

## The rules we model

**1. Collective sets thrust *magnitude*; the cyclic only redirects it.**

There is one rotor force and it always points along the mast. Tilting the
aircraft is the only way to go anywhere, and it costs vertical lift exactly as
`cos(tilt)` says it must. This single coupling is what separates a helicopter
from a submarine: bank hard and you sink unless you feed in collective.

`lift_compensation` is the arcade cheat on this rule. At `0.0` it is honest; at
`1.0` vertical lift is held at hover no matter how far you bank. It currently
sits at `0.15` — enough to take the edge off without removing the trade.

**2. The fuselage is streamlined nose-on and a barn door sideways.**

Drag magnitude depends on which way you are pointing, which is what stops
sideways flight from being free.

Implementation note, because it has bitten twice: drag is always **anti-parallel
to velocity**, and only its *magnitude* varies with direction. Resolving a
diagonal drag tensor onto the body axes instead tilts the force off the velocity
vector and fabricates several m/s² of vertical force whenever the nose is down.
One version of that dived the aircraft into the ground; the fix for that
produced spurious *lift* and flew it from 24 m to 126 m in cruise. Alignment is
computed from heading only, so drag does not change when you pitch or roll.

**3. Translational lift.**

Above roughly 12 m/s the disc bites cleaner air and makes more lift for the same
collective, so you balloon slightly as you accelerate out of a hover.

**4. Main rotor torque reaction.**

Available via `torque_coupling`, but **defaults to 0** so that neutral pedals
hold heading rather than producing input-free drift. It tracks thrust *relative
to hover*, since at a steady hover the tail rotor is already trimmed for it —
what you feel is the change.

## What we deliberately do not model

Retreating blade stall, vortex ring state, autorotation, ground effect, and
translational lift falling off again at high speed. Arcade first.

---

## Attitude, and why it is built the way it is

The cyclic does not torque the aircraft directly. It asks for a **target
attitude** — level at the current heading, then tilted in the stick direction —
and a PD controller flies the airframe there. Centre the stick and the target
becomes level, so auto-levelling falls out for free.

Three non-obvious implementation details:

**The target is axis-angle, not Euler.** Euler order `YXZ` goes singular at 90°
of pitch, and the stick can now command well past that. The target is built as a
single rotation about an axis perpendicular to the stick direction, which is
gimbal-free at any angle.

**Heading uses swing/twist decomposition.** Reading heading from the nose's
horizontal projection makes it jump by 180° during a forward flip — once the
nose passes vertical it points at the other horizon even though the pilot never
yawed. `_heading_of()` decomposes the orientation into swing (tilt) and twist
(rotation about world up) instead, which stays stable through roll, pitch and
diagonal inversions. One singular point remains, at an exact 180° tilt; physics
steps across it in practice and the code returns a finite value if it lands
exactly there.

**Flip completion is explicitly tracked.** Quaternions do not retain whole
turns, so a shortest-arc controller always takes the short way home and a full
flip is impossible. Once the aircraft is meaningfully inverted, holding the
cyclic *against* the current rotation for `flip_reversal_hold` seconds latches
`_flip_completion_axis`, and the error quaternion's sign is then chosen to
continue along that axis until the aircraft is upright and settled. The hold
requirement stops a quick corrective input from committing you to a flip.

---

## Tuning guide

Everything is exported and grouped on the `Helicopter` node, except the input
shaping, which is on its child `InputSource`.

### Start with these three

| Knob | What it really controls |
|---|---|
| `max_thrust_ratio` | Thrust-to-weight, and therefore *everything vertical*. Hover sits at `1/ratio` on the lever, full lever climbs at `(ratio − 1)` g, closed lever means zero thrust and a genuine fall. |
| `cyclic_expo` (InputSource) | How much of the tilt range sits near the centre of the stick. Curves the stick's *magnitude*, so response stays identical in every direction rather than bulging along the diagonals. |
| `attitude_p` / `attitude_d` | How fast the aircraft reaches a commanded attitude. `d ≈ 2·√p` is critically damped. |

### Symptom to knob

| It feels like… | Reach for | Direction |
|---|---|---|
| Too twitchy near centre, but I want the big angles | `cyclic_expo` | Up (0.8 is very soft) |
| Snaps to attitude too aggressively | `attitude_p` | Down, and track `attitude_d ≈ 2·√p` |
| Wallowy, overshoots and oscillates | `attitude_d` | Up |
| Too slow / too fast overall | `max_thrust_ratio` | Sets climb, fall and hover together |
| Sluggish everywhere, but the big angles are still right | `cyclic_expo` | Down — 0.75 gives ~26% tilt at half stick |
| Rotor feels underpowered, lever has no authority | `max_thrust_ratio` | Up — 2.2 puts hover at 45% and climb at 1.2 g |
| Lever itself responds too slowly | `throttle_rate` (InputSource) | Up — 0.75/s is ~1.3 s end to end |
| Can't catch a sink in time | `throttle_rate` (InputSource) | Up — see the sink table below |
| Top speed wrong | `drag_forward` | Top speed ≈ `tan(max_pitch)·g / drag_forward` |
| Sideways flight feels free | `drag_side` | Up |
| Banking costs too much/too little altitude | `lift_compensation` | Up = more forgiving |
| Climb/dive feels floaty | `vertical_drag` | Up to damp |
| Can't reach inverted / flips too easily | `max_bank_deg`, `max_pitch_deg` | Currently 110° both |
| Nose drifts with no pedal input | `torque_coupling`, `bank_turn_rate` | Both default 0; non-zero adds drift by design |

`vertical_drag` is applied in **world** space on purpose. In the body frame, a
nose-down attitude puts a large slice of cruise velocity onto the body's
vertical axis, which reads as speed-proportional anti-lift and makes climb rate
impossible to tune.

---

## The camera is part of the flight model

`chase_camera.gd` runs top-level so the airframe's roll and pitch never reach
the camera; it tracks position and `level_heading()` only. That is what keeps a
tilt-to-move aircraft readable, and it should not change.

What follows from it is a real limitation, tracked as
[open question 10](open-questions.md): **the camera heading is welded to the
airframe's heading, so a pilot can only look where the nose points.** Finding
another helicopter means flying a search pattern rather than looking around, and
at some attitudes the airframe sits between the camera and the target.

### The edge-yaw prototype

The idea in front is to let the aim cursor **yaw the camera when it pushes
toward the screen edge**, rather than clamping dead against it. That turns the
edge from a wall into a look-around control, and it removes the same clamp that
open question 9 is caused by, so one mechanism answers both.

**This is implemented, and it is off by default.** `ChaseCamera.edge_yaw_enabled`
gates it; `F6` toggles it on the aircraft you are flying, and the HUD's last line
shows which state you are in. The toggle is local and unreplicated, so in a
two-player session each pilot evaluates it independently.

| Knob | Default | What it does |
|---|---|---|
| `edge_yaw_deadzone` | 0.72 | Fraction of the half-width before the cursor starts pushing |
| `edge_yaw_rate` | 1.7 rad/s | Swing at full push — measured at 97° in one second, which is the first thing to turn down if it feels frantic |
| `edge_yaw_limit_deg` | 100° | How far off the nose the camera may be dragged |
| `edge_yaw_return` | 1.1 rad/s | Return to the nose once the cursor leaves the band. **0 makes the offset persist**, which is the other candidate feel |

`HeliWeapons.aim_edge_push()` normalises against the *reachable* edge rather
than the raw half-width, because `aim_cursor_margin` otherwise makes full
deflection unattainable and the camera silently tops out below `edge_yaw_rate`.

**What to judge while flying it is not whether looking around works** — it does.
It is what happens to the cyclic. The stick tilts relative to the *aircraft's*
heading, not the camera's, so once the camera is yawed off the nose, pushing the
stick forward no longer moves you up the screen. That is the standard
third-person-shooter versus vehicle-camera tension, and it is the whole reason
this sits behind a flag. If it turns out to be intolerable, the fallback is to
allow edge-yaw only while the aim lock is held, so the camera is only ever
detached from the nose during a deliberate aiming moment.

Still unbuilt: an over-the-shoulder offset on the spring arm while the aim lock
is held, for the airframe blocking the shot. The arm already excludes the
airframe's own collider, so that is a lateral offset rather than new machinery.

Do not wire the cursor fix (question 9) to this until the camera half is
decided. The cursor, the camera and the virtual cyclic are one control loop, and
changing one alone moves the problem rather than fixing it.

---

## Measured envelope

> Measured headlessly at commit `c73d220` on the `Test-Gun` branch.
> **These numbers go stale when anyone tunes the model.** Re-measure before
> trusting them; the method is below.

### Vertical

| Lever | Result |
|---|---|
| 59% (hover) | 0.000 m/s drift, exactly |
| 100% | +13.99 m/s climb |
| 0% | −19.94 m/s fall (terminal is −20) |

### Forward flight

| Input | Speed | Tilt | Vertical |
|---|---|---|---|
| Hover lever + 30% forward cyclic | 35.2 m/s | 33° | −1.71 m/s |
| Hover lever + 100% forward cyclic | 50.3 m/s | 65° | −28.60 m/s |

Full forward cyclic is not a cruise setting — it is a dive. With `max_pitch_deg`
at 110° the stick can command far past level flight, and the raw input above
bypasses `cyclic_expo`, which is what a pilot actually flies through.

### Arresting a descent ("catching a sink")

From a stabilised sink with the lever closed, slam it to full and measure until
vertical speed reaches zero. Includes the ~1.3 s the lever takes to travel.

| Sink rate | Time to stop | **Height lost** |
|---|---|---|
| 3 m/s | 1.67 s | 6.4 m |
| 5 m/s | 1.80 s | 8.8 m |
| 10 m/s | 2.07 s | 14.9 m |
| 15 m/s | 2.32 s | 21.6 m |
| 18 m/s | 2.45 s | 25.7 m |

The height column is the important one: **it is the altitude below which that
sink rate is already fatal.** Falling at 15 m/s with 20 m of air left, you hit
the ground no matter how well you fly.

This is the real height–velocity diagram, the "dead man's curve" — the region of
low altitude and low airspeed where a real helicopter cannot recover, and the
reason they climb out steeply rather than flying low and slow. We got it for
free from honest thrust modelling, and it is worth keeping: it is what makes
flying low near obstacles a genuine commitment.

Rates above 18 m/s are not measurable this way. Terminal fall is −20 m/s and is
approached asymptotically, so a trigger set at 19 never fires.

### Crash threshold

`crash_impact_speed` is 6.5 m/s. Free drops onto flat ground:

| Impact speed | Outcome |
|---|---|
| −3.57 m/s | survived |
| −5.23 m/s | survived |
| −6.40 m/s | WRECKED |
| −7.36 m/s and beyond | WRECKED |

The summed contact impulse over mass tracks true touchdown speed within about
2%, so the export reads directly as "you die above this many m/s".

---

## How to re-measure

There is no committed test harness yet — a deliberate deferral, not an
oversight. The method that produced the table above:

1. Add a temporary scene containing a `WorldBoundaryShape3D` ground plane and a
   `helicopter.tscn` instance.
2. In its script, set the helicopter's **`peer_id` to something other than 1**
   and disable `input_source`. This is what takes authority away so you can
   drive `heli.control` directly each physics tick. Do *not* use
   `offline_local_control` — it does not work
   ([why](architecture.md#3-is_local_authority-is-the-only-authority-gate)).
3. Step through phases in `_physics_process`, writing to `heli.control` and
   printing results, then `get_tree().quit()`.
4. Run it headlessly:
   ```
   godot --headless --path <project-dir> res://scenes/<your-scene>.tscn
   ```
5. Delete the temporary files.

Two traps worth knowing. Any phase that waits for a condition the model cannot
reach will hang forever — always add a timeout. And after a crash the aircraft
stops responding to `control` entirely, so a phase that waits on a velocity
change will never complete once the wreck is on the ground.

Promoting this into a committed harness is the obvious next step, and would mean
the numbers above could never silently go stale.
