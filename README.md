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
| `F1` / `F2` / `F3` | Host / join / leave a LAN session |
| `F4` | Open the session panel (type an address, see your own) |

Two things surprise new pilots, both deliberate:

- **The collective is an absolute lever, not a rate.** Releasing `W` does not
  return you to level flight — it leaves the lever where you parked it. Hover is
  at 59%, marked by a yellow tick on the HUD lever bar. Altitude is something
  you fly, not the default state.
- **The cyclic holds its position.** The mouse drives a virtual stick that stays
  where you left it, like a real cyclic. If the aircraft is drifting, check the
  stick box on the HUD before assuming the physics is wrong.

## Multiplayer (LAN, in progress)

Two peers can connect and see each other's helicopters spawn and despawn.
**Remote aircraft do not move yet** — input and state replication are the next
step, so a remote helicopter currently sits at its spawn point.

Press `F4` for the session panel. The host presses **Host**; the panel then lists
that machine's own addresses and marks which is likely the right one, so there is
no need to run `ipconfig`. The other player types that address and presses
**Join**. The address is remembered between runs.

`F1` / `F2` / `F3` are shortcuts for host / join / leave without opening the
panel; `F2` uses the `join_address` export on the World node.

Two things that will stop a join working:

- **The wrong address.** `127.0.0.1` only ever reaches the same computer, and a
  machine usually has several addresses — `169.254.x.x` is link-local and never
  works, and on Windows `172.x` is usually WSL or Docker rather than your LAN.
  The panel annotates these.
- **The host's firewall.** Inbound UDP on port 27015 must be allowed. Windows
  asks once on first host and silently blocks it if the prompt is dismissed.

The HUD shows the address it is connecting to, so read that line first when a
join hangs.

From the command line, useful for testing two instances on one machine:

```
godot --path <project-dir> -- --host
godot --path <project-dir> -- --join=192.168.1.42
```

Note the bare `--`: everything after it is passed to the game rather than to the
engine. `--join` defaults to `127.0.0.1` if no address is given.

## Repository layout

```
scenes/
  world.tscn        Test level: ground, obstacles, and an empty Players node
                    that helicopters are spawned into at runtime
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
  network_session.gd    Autoload: owns the ENet peer and session lifecycle
  connect_panel.gd      In-game host/join UI (F4)
  debug_hud.gd          Tuning readout — throwaway, delete when feel is settled
  world.gd              Test level setup
docs/
  architecture.md   Design decisions, the multiplayer plan, and the invariants
  flight-model.md   How the aircraft flies, and how to tune it
  weapons.md        The weapon system and its unresolved networking questions
```

## Documentation

- **[Architecture](docs/architecture.md)** — why the code is shaped the way it
  is, and what must not be broken. Start here.
- **[Flight model](docs/flight-model.md)** — the helicopter rules we model, the
  measured flight envelope, and a symptom-to-knob tuning guide.
- **[Weapons](docs/weapons.md)** — the current implementation and its design
  questions.
- **[Open questions](docs/open-questions.md)** — the single registry of
  undecided forks. Check it before deciding one.
- **[Contributing](CONTRIBUTING.md)** — code and documentation conventions, and
  what to check before committing.
