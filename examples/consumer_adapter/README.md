# BeamFX consumer adapter template

This is ordinary OpenMW Lua that you can copy into a mod. It has no Cod3x,
LuaLS-stub, or annotation dependency and requires no BeamFX private module.
BeamFX is optional: if it is missing, resetting, or incompatible, your
gameplay continues and only the beam visual is skipped.

## Copy and rename

Copy `scripts/example_beam_consumer` into your data root, then change:

1. `example.author.easy_beams` to your stable, namespaced producer ID.
2. `Example Author - Easy Beams` to your display name.
3. `ExampleAuthor_EasyBeams_ShowFrost` to a globally unique event name.
4. `ExampleAuthorBeamVisuals` to a player-interface name unique to your mod.
5. Every `scripts.example_beam_consumer...` require path to your directory.
6. The placeholder authoritative registry and reconstruction callback in
   `global.lua` to use your real gameplay state.

The adapter reserves local beam IDs beginning with
`__beamfx_adapter_emit_` for its API 1.2 fallback. Do not use that prefix for
your own persistent IDs.

Add the scripts to your `.omwscripts` manifest:

```text
GLOBAL: scripts/your_mod/global.lua
PLAYER: scripts/your_mod/player.lua
```

The supplied `beamfx_consumer_template.omwscripts` is directly usable while
trying the example, but its names must be changed before release.

The constructor accepts these ordinary configuration fields:

| Field | Purpose |
|---|---|
| `producerId` | Required stable, namespaced owner ID |
| `displayName` | Human-readable diagnostics name |
| `reconstruct` | Callback that republishes authoritative persistent visuals |
| `retryMinimumSeconds` | Initial registration retry delay; default `0.25` |
| `retryMaximumSeconds` | Maximum registration retry delay; default `5` |
| `warningIntervalSeconds` | Per-category warning interval; default `30` |
| `reconstructionRetrySeconds` | Failed reconstruction retry; default `1` |
| `logger` | Optional `function(message)`; otherwise the adapter uses `print` |

## The small effect call

From another player script in the same mod:

```lua
local I = require("openmw.interfaces")

I.ExampleAuthorBeamVisuals.showFrost(startPos, endPos)
```

The player adapter copies the numeric positions and sends a namespaced global
event. It sends an object reference identifying the player, but never sends a
raw Cell. The global handler verifies the sender, reads the authoritative Cell
there, and makes the API 1.3 convenience call:

```lua
visuals:emit({
    cell = cell,
    from = startPos,
    to = endPos,
    preset = "frost",
    radius = 6,
    duration = 0.25,
})
```

`emit` returns an opaque local beam ID on success. Most one-shot effects do
not need to retain it. When BeamFX API 1.3 is unavailable but compatible API
1.0-1.2 is installed, the adapter produces a transient beam through `upsert`
using the same alpha.4 preset values and color derivation.

## What the adapter handles

- lazy producer registration rather than load-order assumptions;
- API-major rejection and API-minor feature awareness;
- provider-epoch changes, `stale_producer`, and `provider_reset`;
- one safe immediate retry after a stale/reset operation;
- exponential registration retry from 0.25 to 5 seconds;
- warnings limited to once per category every 30 seconds;
- reconstruction after a new producer generation;
- a plain API 1.2 fallback for the API 1.3 `emit` convenience;
- explicit `reset`, `release`, and `resume` paths.

Call `visuals:update()` from the global script's `onUpdate`. Call
`visuals:reset(reason)` after loading or replacing authoritative state.
Call `visuals:release(reason)` when the feature is disabled permanently; call
`visuals:resume(reason)` if it is enabled again.

For complete control, use the existing public producer methods through:

```lua
local result, err, detail = visuals:invoke("upsert", "persistent_id", beamSpec)
```

The optional third return is structured validation detail on providers that
support it. The adapter never imports BeamFX validation, protocol, renderer,
or shader modules.

## Reconstruction rule

The callback passed as `reconstruct` is invoked after first registration and
after a provider reset or epoch change. Rebuild persistent visuals from your
mod's authoritative registry; never treat BeamFX as gameplay state.

Return `false, reason` to retry reconstruction later. Returning `true`, or
simply returning nothing after successful calls, marks reconstruction
complete. Do not replay an expired transient effect merely because it existed
before a load.

The callback is also why gameplay remains independent: BeamFX can disappear
or reset without changing hits, damage, resources, targeting, timers, or
objects owned by your mod.
