# heli-test

A multiplayer helicopter game, currently at proof-of-concept stage. Arcade-lite
flight that still obeys helicopter rules, built in Godot 4.6 with Jolt Physics.

**Status:** single-player prototype. The flight model is close to settled, the
weapons are early, and there is no networking yet — but the architecture is
built around a specific netcode plan that constrains how the code may be
written. Read [docs/architecture.md](docs/architecture.md) before changing
anything in the flight path; some of what looks like stylistic choice is
load-bearing.

## Running it

Open the project in Godot 4.6 and press F5. The main scene is
`scenes/world.tscn`.

To check that scripts and scenes still compile without opening the editor:

```
godot --headless --path <project-dir> --import
```

## Controls

| Input | Action |
|---|---|
| `W` / `S` (or `Space` / `Shift`) | Collective lever up / down |
| Mouse, or arrow keys | Cyclic (tilt) |
| `A` / `D` (or `Q` / `E`) | Tail rotor pedals (yaw) |
| Left mouse button | Fire |
| `R` | Reset / respawn |
| `Esc` | Release mouse capture |

Two things surprise new pilots, both deliberate:

- **The collective is an absolute lever, not a rate.** Releasing `W` does not
  return you to level flight — it leaves the lever where you parked it. Hover is
  at 59%, marked by a yellow tick on the HUD lever bar. Altitude is something
  you fly, not the default state.
- **The cyclic holds its position.** The mouse drives a virtual stick that stays
  where you left it, like a real cyclic. If the aircraft is drifting, check the
  stick box on the HUD before assuming the physics is wrong.

## Repository layout

```
scenes/
  world.tscn        Test level: ground, scattered obstacles, two helicopters
  helicopter.tscn   The aircraft — body, model, input, weapons, camera rig
  projectile.tscn   Guided projectile fired by the guns
  explosion.tscn    Impact effect
scripts/
  helicopter.gd         Flight model and the physics-engine boundary
  heli_input.gd         One frame of pilot intent; the network wire format
  local_input_source.gd Keyboard + mouse -> HeliInput
  chase_camera.gd       Third-person rig
  heli_weapons.gd       Aiming, firing, ammo
  heli_projectile.gd    Projectile flight and collision
  heli_explosion.gd     Effect lifetime
  debug_hud.gd          Tuning readout — throwaway, delete when feel is settled
  world.gd              Test level setup
docs/
  architecture.md   Design decisions, the multiplayer plan, and the invariants
  flight-model.md   How the aircraft flies, and how to tune it
  weapons.md        The weapon system and its unresolved networking questions
```

## Documentation

- **[Architecture](docs/architecture.md)** — why the code is shaped the way it
  is, what must not be broken, and what is deliberately unfinished.
- **[Flight model](docs/flight-model.md)** — the helicopter rules we model, the
  measured flight envelope, and a symptom-to-knob tuning guide.
- **[Weapons](docs/weapons.md)** — the current implementation and the open
  design questions.
