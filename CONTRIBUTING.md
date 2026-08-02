# Contributing

Conventions for this project. Written to be read by both humans and agent
sessions — several of each work on this repo in parallel, sometimes on the same
files.

## Before you commit

1. **Check the invariants.** [architecture.md](docs/architecture.md#the-invariants)
   lists four. Breaking them does not produce an error — it quietly forecloses
   the netcode plan. If your change touches the flight path, re-read them.
2. **Verify it still compiles**, without opening the editor:
   ```
   godot --headless --path <project-dir> --import
   ```
   This catches script errors, broken scene references and missing resources.
3. **Update any doc your change invalidates, in the same commit.** See
   [Documentation](#documentation) below.

## Code conventions

Follow what's already there. Concretely:

- **Tabs** for indentation. Static typing everywhere — `var x := 0.0`, typed
  parameters, explicit `-> void`.
- **`##` doc comments** on every class and on any function whose purpose isn't
  obvious from its name. Exported variables get one too, including units
  (`rad/s`, `1/s`, `m/s`).
- **`@export_group`** to organise the inspector. The flight model has a lot of
  knobs and ungrouped ones get lost.
- **`&"..."` StringNames** for input actions and group names.
- **Leading underscore** for private members.

### Comment philosophy

This codebase comments *why*, not *what*, and it is unusually willing to record
things that went wrong. That is deliberate — please keep doing it. The most
valuable comments here are the ones documenting:

- **Engine quirks.** Jolt splitting one impact across several contacts;
  `DAMP_MODE_COMBINE` silently adding project damping; `OfflineMultiplayerPeer`
  making `has_multiplayer_peer()` true offline.
- **Approaches that were tried and failed.** The drag implementation carries a
  note about two earlier versions that fabricated vertical force. Without it,
  the "obvious" fix is to reintroduce one of them.
- **Sign conventions and singularities** you had to reason carefully about, and
  what you checked them against.

If you spent more than ten minutes working something out, a future reader will
too. Write it down at the point of use.

## Documentation

Docs live in `docs/` as plain markdown, deliberately vendor-neutral so any tool
or person can read them.

### Which file owns what

| Fact | Goes in |
|---|---|
| How to run it, controls, layout | `README.md` |
| Why a design is the way it is; what must not be broken | `docs/architecture.md` |
| How the aircraft flies; tuning; measured numbers | `docs/flight-model.md` |
| Weapon behaviour and its design questions | `docs/weapons.md` |
| A fork that is not yet decided | `docs/open-questions.md` |
| Code conventions and process | this file |

Put a fact in exactly one place and link to it from the others. When the same
thing is written down twice, the copies diverge and neither can be trusted.

### Rules that matter when several people are editing at once

- **Don't decide someone else's open question.** Check
  [open-questions.md](docs/open-questions.md) first. If you resolve one, move
  the reasoning into the topic doc and delete the row in the same commit.
- **Don't paste code into docs.** Reference `file.gd:function_name` instead.
  Pasted snippets go stale silently.
- **Measured numbers need a commit stamp** and an explicit staleness warning.
  They are only true for the tuning they were measured against — the flight
  envelope table has already gone stale once, when `attitude_p` and
  `max_pitch_deg` changed underneath it.
- **If you change an exported default that appears in a doc table, update the
  table in the same commit.** This is the single most common way these docs will
  rot.
- **Prefer adding to an existing doc** over creating a new one. Four focused
  files beat twelve overlapping ones.

## Branches

Work happens on feature branches and merges to `main`. Documentation is written
against whatever branch the code lives on and travels with it, so a doc
describing unmerged behaviour doesn't land on `main` ahead of the code it
describes.
