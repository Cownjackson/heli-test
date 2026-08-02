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
| 1 | Damage model: health pool, or impulse large enough to make the target crash itself? | [weapons.md](weapons.md#1-there-is-no-damage-model-at-all) | weapons chat |
| 2 | Hit authority for player-guided projectiles — server-authoritative, client-authoritative, or lag-compensated? | [weapons.md](weapons.md#2-hit-authority-is-undecided-and-this-blocks-networking) | weapons MP chat |
| 3 | Are these guns or missiles? Code, HUD and behaviour currently disagree. | [weapons.md](weapons.md#the-projectile) | gun features chat |
| 4 | How does a remote helicopter's weapon resolve an aim point with no camera of its own? | [weapons.md](weapons.md#3-aim-is-camera-dependent) | weapons MP chat |
| 5 | When do we actually swap `RigidBody3D` for the custom integrator? The flight model is ready; the swap is not scheduled. | [architecture.md](architecture.md#decision-custom-integrator-not-the-rigid-body-engine) | — |
| 6 | Fix `offline_local_control`, or delete it and drive everything from `peer_id`? | [architecture.md](architecture.md#3-is_local_authority-is-the-only-authority-gate) | — |
| 7 | Is `throttle_rate` (0.75/s, ~1.3 s lever travel) responsiveness-to-plan-around, or just sluggish? | [flight-model.md](flight-model.md#arresting-a-descent-catching-a-sink) | flight tuning |
| 8 | Promote the throwaway measurement harness into a committed regression test? | [flight-model.md](flight-model.md#how-to-re-measure) | — |

## Deferred on purpose

These are decided — the decision is "not yet". Do not treat them as gaps.

| Item | Why deferred |
|---|---|
| Networking implementation | Reconciliation is far easier to write against a flight model that has stopped changing |
| First-person / cockpit camera | Waiting until the third-person camera feels right |
| `CLAUDE.md` / `AGENTS.md` split | Two different agent tools in use; not ready to decide how to maintain both |
| Replacing the debug HUD | It is a tuning instrument; it goes when the flight model settles |
