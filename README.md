# BeamFX

BeamFX lets OpenMW Lua mods draw animated, depth-aware beams without each mod
shipping its own postprocessing shader or renderer.

A mod that asks BeamFX to draw something is called a **producer**. BeamFX
combines the beams from every producer into one shared compositor, keeps their
IDs and state separate, and divides limited render capacity fairly.

BeamFX is visual only. It does not perform collision, raycasting, damage,
target selection, spell cancellation, projectile cleanup, sounds, meshes, or
saved gameplay. If BeamFX is missing or temporarily unavailable, a well-made
producer should lose only its beam visuals.

> **Alpha status:** this is package `0.1.0-alpha.1`, public API `1.0`.
> Until a software license is selected, this package is for local development
> and testing only. Do not upload, redistribute, or bundle it with another mod.

## Start here

### I am installing a mod that requires BeamFX

Follow [Install](#install), enable `beamfx.omwscripts`, and restart OpenMW.
The mod using BeamFX should handle everything else.

### I am adding BeamFX support to my mod

Start with [the friendly usage guide](docs/USAGE.md). It includes:

- a copy-paste quick-start example;
- transient, continuous, persistent, and rolling-trail recipes;
- producer registration and provider-reset recovery;
- space changes, cleanup, errors, and troubleshooting.

Use [the API reference](docs/API.md) when you need every field, return value,
quota, and stable error code. Use [the architecture guide](docs/ARCHITECTURE.md)
when you need to understand ownership, routing, or the renderer pipeline.

## Requirements

- OpenMW `0.51` or newer.
- Lua postprocessing enabled.
- BeamFX installed as its own OpenMW data root.

## Install

1. Extract BeamFX so `beamfx.omwscripts` is directly inside the selected
   `BeamFX` directory, not inside an extra nested folder.
2. Add that directory as a data root in `openmw.cfg`.
3. Add `content=beamfx.omwscripts` to `openmw.cfg`.
4. Enable postprocessing.
5. Restart OpenMW completely.

Recommended ordering:

```text
data=<BeamFX directory>
data=<mod that uses BeamFX>

content=beamfx.omwscripts
content=<consumer mod manifest>
```

This order is recommended for clarity, not a substitute for lazy API
acquisition. The BeamFX data root must remain available so the renderer can
load `shaders/beamfx_core.omwfx`.

In OpenMW `0.51`, enable postprocessing through
**Launcher → Settings → Visuals → Post Processing** or
**Options → Video → Post Processing** in game. The equivalent `settings.cfg`
entry is:

```ini
[Post Processing]
enabled = true
```

Do not add `beamfx_core.omwfx` to the F2 postprocessing chain. BeamFX loads and
controls it dynamically.

Install only one copy of BeamFX. Compatible duplicates remain inert as a
safety measure, but duplicates are not a supported deployment model.

## What BeamFX provides

BeamFX exposes one public global-script interface:

```lua
local I = require("openmw.interfaces")
local BeamFX = I.BeamFX
```

The public API is available only to **global scripts**. Player, local, or
custom scripts should send a namespaced serializable event to their own global
adapter. That adapter checks current game state and calls BeamFX.

The two framework interfaces are:

```text
BeamFX          public global producer API
BeamFXRenderer  local player renderer diagnostics
```

Only BeamFX owns the shader and renderer. Producer mods submit neutral
geometry and appearance settings; they never receive shader handles or inject
GLSL.

## Built-in visual styles

| Style | Good starting use |
|---|---|
| `smooth` | lasers, energy links, clean magic rays |
| `electric` | lightning, unstable energy, blaster effects |
| `plasma` | bright noisy energy and origin glows |
| `trail` | fading movement trails and rolling histories |

Colors use RGB tables such as `{ 0.08, 0.45, 1.0 }`. The usage guide includes
safe starter values for radius, intensity, core size, and animation scale.

## Capacity and fairness

The compositor can display up to:

```text
64 segments
16 distinct palettes
```

Accepted logical state is bounded separately and may exceed those physical
limits. When many producers compete for the 64 visible slots, BeamFX uses a
deterministic fair scheduler. At the maximum supported producer count, every
eligible producer receives service within two rendered frames.

## Missing-provider behavior

Producer mods should:

- check that `I.BeamFX` exists and `apiMajor == 1`;
- acquire a producer lazily and retry at a low, bounded rate;
- cache `providerEpoch()` with the returned producer handle;
- reacquire and reconstruct visuals after an epoch change,
  `stale_producer`, or `provider_reset`;
- rate-limit warnings;
- continue gameplay while visuals are unavailable.

`producer_id_in_use` means two live scripts are claiming the same producer ID.
Treat that as a real configuration or ownership error; never adopt another
script's producer.

## Troubleshooting

### No beams are visible

1. Confirm OpenMW is `0.51` or newer.
2. Confirm the BeamFX directory is an active data root.
3. Confirm `beamfx.omwscripts` is enabled.
4. Confirm postprocessing is enabled:

   ```ini
   [Post Processing]
   enabled = true
   ```

5. Check the OpenMW log for `Beam shader loaded`.
6. Check the producer's registration or validation error.
7. Confirm the producer supplied a current, valid `spaceKey`.

The step-by-step diagnosis section in
[USAGE.md](docs/USAGE.md#16-troubleshooting) covers these cases in more
detail.

### Duplicate provider or renderer warning

Remove duplicate BeamFX installations. Only the first compatible copy becomes
the active provider and renderer.

### A beam appears in the wrong place or disappears after travel

BeamFX v1 renders only in the beam's current space. The producer must
derive `spaceKey` in global context and, on a space transition, remove the old
beam generation and publish a new generation in the new space. Do not send a
raw Cell through an event.

### Postprocessing or the shader becomes unavailable

Valid broker mutations and producer ownership remain intact. The renderer
retries recoverable initialization with backoff and resynchronizes retained
visual state after recovery. Gameplay must remain independent.

## Version tracks

| Track | Version |
|---|---|
| Package | `0.1.0-alpha.1` |
| Public API | `1.0` |
| Private render protocol | `1` |
| Shader ABI | `1` |

These tracks change independently. A public API-major change is the signal for
producer compatibility; private protocol and shader-ABI details are owned by
BeamFX.

## Documentation

- [Usage guide](docs/USAGE.md) — learn by building effects.
- [API reference](docs/API.md) — exact contracts and schemas.
- [Architecture](docs/ARCHITECTURE.md) — ownership and data flow.
- [Changelog](CHANGELOG.md) — public package history.
