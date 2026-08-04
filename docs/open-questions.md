# Open questions

The single registry of decisions that are **not yet made**. Several people and
agent sessions work on this project in parallel, so this file exists to stop two
of them answering the same question differently.

## How to use this file

- **Before deciding anything listed here**, check whether someone else owns it.
- **Keep the detail where it lives.** Entries here are one-liners plus a link.
  The reasoning belongs in the topic doc; duplicating it guarantees drift.
- **When a question is resolved**, move it out: the decision and its rationale
  go into [architecture.md](architecture.md) (or the relevant topic doc), and
  the row here is deleted in the same commit. A resolved question left sitting
  in this file is worse than no file at all.
- **Add new forks as you find them**, especially ones you deliberately worked
  around rather than solved.

---

## Open

| # | Question | Detail | Owner |
|---|---|---|---|
| 1 | Damage model: health pool, or blast large enough to make the target crash itself? Both are now implemented and each can be zeroed on the target, so this is a tuning session away from an answer — and the losing half then gets deleted, not left at zero. | [weapons.md](weapons.md#1-damage-both-models-are-implemented-so-the-fork-can-be-flown) | multiplayer chat |
| 3 | Are these guns or missiles? Code, HUD and behaviour currently disagree. | [weapons.md](weapons.md#the-projectile) | gun features chat |
| 5 | When do we actually swap `RigidBody3D` for the custom integrator? Now has a shape — when the game leaves LAN and needs prediction — but no schedule. | [architecture.md](architecture.md#but-the-first-playable-test-should-still-be-option-a-over-lan) | — |
| 7 | Is `throttle_rate` (0.75/s, ~1.3 s lever travel) responsiveness-to-plan-around, or just sluggish? Flying says sluggish; pairs with 10. | [flight-model.md](flight-model.md#arresting-a-descent-catching-a-sink) | flight tuning |
| 8 | Promote the throwaway measurement harness into a committed regression test? | [flight-model.md](flight-model.md#how-to-re-measure) | — |
| 9 | How do the crosshair and the virtual cyclic stay in agreement? They are two integrators over one mouse and provably desync at the clamps. The fix direction (derive the cursor from the stick) is clear; how aim lock reconverges afterwards is not. | [weapons.md](weapons.md#the-crosshair-and-the-stick-disagree) | flight tuning |
| 10 | How does a pilot look around to find a target? The camera heading is welded to the airframe's, so you can only look where the nose points — and the airframe itself blocks the shot at some attitudes. Cursor-at-screen-edge yawing the camera is the leading idea because it also removes the clamp behind 9. | [flight-model.md](flight-model.md#the-camera-is-part-of-the-flight-model) | flight tuning |
| 11 | How much power margin should the aircraft have? `max_thrust_ratio` 1.7 puts hover at 59% of the lever and caps climb at 0.7 g, which reads as an underpowered rotor. Raising it moves hover down the lever and changes every vertical number in the envelope. | [flight-model.md](flight-model.md#the-rules-we-model) | flight tuning |
| 12 | Is `cyclic_expo` 0.75 too much? Half stick asks for ~26% tilt, which is most of why the aircraft feels slow to respond without the tilt limits actually being wrong. | [flight-model.md](flight-model.md#attitude-and-why-it-is-built-the-way-it-is) | flight tuning |

## Deferred on purpose

These are decided — the decision is "not yet". Do not treat them as gaps.

| Item | Why deferred |
|---|---|
| Prediction / reconciliation | Only needed once the game leaves LAN; deferring it also defers the custom-integrator swap. Reconciliation is far easier to write against a flight model that has stopped changing |
| First-person / cockpit camera | Waiting until the third-person camera feels right |
| `CLAUDE.md` / `AGENTS.md` split | Two different agent tools in use; not ready to decide how to maintain both |
| Replacing the debug HUD | It is a tuning instrument; it goes when the flight model settles |
