# Architecture

This document covers the decisions that the code cannot explain about itself:
why things are shaped the way they are, which properties are load-bearing, and
what is deliberately left undone.

If you only read one section, read [The invariants](#the-invariants).

---

## The multiplayer plan

Nothing is networked yet. But the whole codebase is arranged around a specific
plan, and several things that look like ordinary code are actually constraints
imposed by it.

### Decision: custom integrator, not the rigid-body engine

Two realistic architectures were considered:

**A. Server-authoritative + interpolation.** The server simulates with the
physics engine; clients render interpolated state. This works with an ordinary
`RigidBody3D` and needs almost no rework.

**B. Take the helicopter out of the rigid-body simulation.** Integrate the
flight model's force and torque ourselves, and use the physics engine only for
collision *queries* against static scenery. We then own the complete state, can
snapshot it, and can re-simulate it.

**We chose B.** The deciding factor is that a helicopter is flown by continuous
attitude correction. Under option A your own aircraft does not respond until a
network round trip completes; 80–120 ms of that is tolerable on a character
controller and genuinely unpleasant on a helicopter. Option B allows local
prediction and reconciliation.

### But the first playable test should still be option A, over LAN

B remains the destination. It is not where the *first* networked build should
start, because the argument above is entirely an argument about latency.

The two contributors are on the same network, so the realistic first test is
LAN: sub-millisecond round trip, no NAT traversal, no relay. At that latency the
input delay under option A is smaller than one physics tick and below what is
perceptible even on a vehicle flown by continuous correction. The objection that
rules out option A over the internet simply does not apply on a switch.

That has a large consequence. It means the first networked build needs **no
prediction, no reconciliation, and no custom integrator** — server-authoritative
`RigidBody3D`, clients sending `HeliInput`, remote aircraft frozen and
interpolated. All of which the code already supports. It also means Jolt's
determinism stays irrelevant, because only one machine is simulating.

So the staging is: get two helicopters flying on one network under option A,
which is achievable now and validates the authority gate, the wire format and
the spawning story against a real peer. Option B becomes necessary at the point
the game leaves the LAN, and is much easier to write against a flight model and
a weapon system that have both stopped moving. Prediction is the thing that
forces the rewrite; deferring prediction defers the rewrite.

The risk to watch is building option A in a way that assumes low latency
*forever* — for instance resolving hits on the firing client because it happens
to look fine at 0 ms. Low latency is a reason to postpone prediction, not a
reason to put authority in the wrong place.

### Why this is not a Jolt question

It is worth being precise, because "should we switch physics engines?" comes up
naturally and the answer is that it would not help.

The real fork is *rigid-body-engine vs. custom integrator*, not *Jolt vs. Godot
Physics*. Rollback requires stepping the physics world manually, several times,
within a single frame. Godot exposes no supported way to do that for 3D. Both
engines are therefore equally unusable for it — which is why the established
Godot rollback libraries (netfox, godot-rollback-netcode) tell you up front not
to use `RigidBody3D` for rollback-synced entities. It is a Godot-level
constraint.

On its own merits Jolt is the right choice here — better continuous collision
detection and stacking, and we have a fast-moving body among obstacles — so it
stays.

### Where the engine boundary currently sits

`Helicopter` is still a `RigidBody3D`, and that is fine for now. What matters is
that the *flight model* has already been lifted clear of it. Engine contact is
confined to two places:

- `_integrate_forces()` — reads body state, applies the resulting force/torque
- `_check_impact()` — reads contact impulses for crash detection

Everything else in the flight path is engine-independent and would move to a
custom integrator unchanged.

---

## The invariants

These are the things most likely to be broken by a well-intentioned change.

### 1. `compute_flight()` must stay pure

```gdscript
func compute_flight(xform, velocity, angular, ctl, flip_completion_axis) -> Array
```

It takes plain state, returns `[force, torque]`, and reads **nothing** from the
physics engine, the scene tree, or global input. This is what allows it to be
called repeatedly during re-simulation with fabricated state.

Adding a single `global_position` read, an `Input.is_action_pressed()`, a
raycast, or a `get_node()` inside this function silently forecloses the netcode
plan. It will not fail visibly — it will just quietly stop being re-simulatable.

Two consequences that already follow from this rule:

- **Gravity is ours.** `gravity_scale` is set to `0.0` in `_ready()` and the
  model applies its own `gravity`. A side benefit: hover drift went from
  −0.05 m/s to exactly 0.00, because our lift and our gravity now cancel
  exactly rather than racing the engine's integration order.
- **Inertia is ours.** `_compute_inertia()` derives the principal moments from
  the collision box rather than asking the physics server for its tensor. The
  derived values came within 0.2% of what Jolt reported, so no retuning was
  needed when the switch was made.

### 2. Pilot intent travels as absolute positions, never deltas

`HeliInput` is four floats: `pitch`, `roll`, `yaw`, `throttle`. Note that
`throttle` is the **lever position** (0..1), not an up/down rate.

This is a networking decision, not an ergonomic one. Absolute positions are
self-healing: a dropped packet costs you one frame of staleness. If we sent
deltas, a single dropped packet would leave client and server permanently
disagreeing about how much power is in — an error that never washes out.

It happens to also be more helicopter-correct, since a real collective is a
lever you park rather than a rate you hold.

### 3. `is_local_authority()` is the only authority gate

One function decides who may fill `control`. Local input now, the network
later. Do not add a second path that writes to `control`.

> **Known bug.** `offline_local_control` does not work. Godot 4 installs an
> `OfflineMultiplayerPeer` by default, so `multiplayer.has_multiplayer_peer()`
> returns `true` even with no networking, and `is_local_authority()` always
> takes the `peer_id == get_unique_id()` branch. Offline, `get_unique_id()`
> returns 1.
>
> The result is that `offline_local_control` is dead code, and the target
> helicopter in `world.tscn` behaves correctly only because its `peer_id` is 2.
> Anything relying on the flag will silently get the wrong answer. Either fix
> the check to treat `OfflineMultiplayerPeer` as "no peer", or delete the flag
> and drive everything from `peer_id`.

### 4. Remote helicopters must not simulate locally

When networking goes in, remote aircraft need `freeze = true` and pure
interpolation. Writing a transform onto a live `RigidBody3D` every frame means
fighting the physics engine — you set the transform, the engine overwrites it.
This is cheap to arrange now and awkward to retrofit.

---

## Other decisions worth knowing

### Damping is set to REPLACE, deliberately

`_ready()` sets both `linear_damp_mode` and `angular_damp_mode` to
`DAMP_MODE_REPLACE`. This is not tidiness. The default is `DAMP_MODE_COMBINE`,
which *adds* the project's default damping (0.1) on top of the body's own — so
`linear_damp = 0` does not mean "no damping". When this was wrong, real drag was
0.25 instead of 0.15 and top speed was cut by about 40%, with nothing in the
inspector to indicate it.

### Crash detection depends on Jolt-specific behaviour

`_check_impact()` **sums** contact impulses rather than testing each one. Jolt
splits a single impact across several contact points and resolves them in one
step, so no individual contact carries the whole blow — an early version never
fired at all, even at −10 m/s. Jolt also reports 0.0 for resting contacts, which
is why parking on the helipad does not slowly accumulate into a crash.

Both behaviours are Jolt's. Godot Physics reports differently, so this function
would need revisiting if the engine ever changed.

The threshold is divided by mass so it reads as a speed in m/s, which stays
meaningful if the airframe gets heavier.

### The debug HUD is throwaway

`debug_hud.gd` exists to make tuning possible and should be deleted or replaced
once the flight model is settled. Do not build real UI on it.

### The test world is generated from a fixed seed

`world.gd` scatters obstacles from `world_seed`, so every peer builds an
identical world without syncing any of it. Keep it that way — it is free
determinism for the scenery.

---

## What is deliberately not done

Tracked in [open-questions.md](open-questions.md), which distinguishes forks
that are genuinely undecided from work that is deferred on purpose. Networking,
the custom-integrator swap, the damage model and the cockpit camera all live
there rather than being listed twice.
