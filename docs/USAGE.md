# Using BeamFX

This guide is for OpenMW Lua mod authors who want to add beam visuals without
building a separate postprocessing renderer.

You do not need to understand BeamFX internals to get started. The shortest
path is:

1. install and enable BeamFX;
2. add one global script to your mod;
3. register a producer;
4. publish a beam.

The examples below target OpenMW `0.51` and BeamFX public API `1.0`.

If this is your first integration, complete sections 1–3 first. Sections 4–5
explain how to adapt that first beam. Everything after that is a recipe or
reference you can return to when you need it.

## Guide map

- **Get a first result:** [install](#1-install-beamfx),
  [add a global adapter](#2-add-a-global-adapter-to-your-mod), and
  [draw one beam](#3-quick-start-draw-one-beam).
- **Build real effects:** [method chooser](#5-which-producer-method-should-i-use),
  [common recipes](#6-common-recipes), and
  [timing](#7-beam-timing-versus-segment-timing).
- **Integrate safely:** [spaces](#8-positions-and-spaces),
  [other script contexts](#9-calling-from-player-or-local-scripts),
  [reset recovery](#10-recovering-after-a-provider-reset), and
  [cleanup](#12-cleanup).
- **Polish and ship:** [styles](#11-styles-and-friendly-starter-values),
  [capacity](#13-capacity-guidance), [errors](#14-handling-errors),
  [diagnostics](#15-diagnostics), [troubleshooting](#16-troubleshooting), and
  [the production checklist](#17-production-checklist).

## A few words used in this guide

- **Producer handle:** the private table your mod uses to publish and manage
  its own beams.
- **Beam:** one owned visual effect with a lifecycle and one or more segments.
- **Segment:** one line from `startPos` to `endPos` with an appearance.
- **Space:** the interior or exterior worldspace in which a beam may render.
- **Current game state:** facts checked by your global script, such as an
  object's current Cell, rather than values trusted blindly from an event.
- **Beam generation:** the current lifetime of a beam ID. Recreating a removed
  or finished beam starts a new generation.
- **Provider session (`providerEpoch`):** the current BeamFX runtime session. A
  new value means producers must register again and reconstruct their visuals.

## 1. Install BeamFX

Extract BeamFX so `beamfx.omwscripts` is directly inside the selected BeamFX
directory, not inside an extra nested folder. Add that directory as its own
OpenMW data root and enable the manifest in `openmw.cfg`:

```text
data=<BeamFX directory>
content=beamfx.omwscripts
```

This ordering is recommended for clarity, but consumer mods must still acquire
the API lazily rather than relying on script order:

```text
data=<BeamFX directory>
data=<your mod directory>

content=beamfx.omwscripts
content=<your mod>.omwscripts
```

Enable postprocessing in `settings.cfg`:

```ini
[Post Processing]
enabled = true
```

In OpenMW `0.51`, you can instead enable the same switch through
**Launcher → Settings → Visuals → Post Processing** or
**Options → Video → Post Processing** in game.

Do not add `beamfx_core.omwfx` to the F2 postprocessing chain. BeamFX loads and
controls that shader dynamically.

Restart OpenMW completely after changing data roots or script manifests. The
in-game postprocessing switch applies immediately.

## 2. Add a global adapter to your mod

The BeamFX producer API is available only in OpenMW's **global** Lua context.
Create a manifest in your own mod, for example:

```text
GLOBAL: scripts/example_beams/global.lua
```

Player, local, and custom scripts should not call BeamFX directly. They send a
namespaced event to their own global adapter; the adapter validates
current game state, derives the space key, and publishes the visual.

## 3. Quick start: draw one beam

The following complete global script draws a blue electric beam in front of
the first player. It checks twice per simulation second until both the player
and BeamFX are ready.

Before copying it, replace:

- `author.modname.quickstart` with your own stable, namespaced producer ID;
- `My Mod` with your mod's display name.

A producer ID may contain ASCII letters, digits, `.`, `_`, and `-`, and its
first character must be alphanumeric.

Copy the script to the global-script path from your manifest:

```lua
local core = require("openmw.core")
local I = require("openmw.interfaces")
local world = require("openmw.world")

local producer = nil
local finished = false
local nextAttemptAt = 0
local producerIdWarningShown = false

local function reset()
    producer = nil
    finished = false
    nextAttemptAt = 0
    producerIdWarningShown = false
end

local function firstPlayer()
    local players = world.players
    if players == nil then
        return nil
    end
    local ok, player = pcall(function()
        return players[1]
    end)
    return ok and player or nil
end

local function acquireProducer(api)
    if producer ~= nil then
        return producer
    end

    local newProducer, err = api.registerProducer({
        id = "author.modname.quickstart",
        displayName = "My Mod",
        apiMajor = 1,
    })
    if newProducer ~= nil then
        producer = newProducer
        producerIdWarningShown = false
    elseif err == "producer_id_in_use" then
        if not producerIdWarningShown then
            print(
                "[My Mod] BeamFX producer ID is busy; retrying. "
                    .. "If this persists, choose a unique ID."
            )
            producerIdWarningShown = true
        end
    elseif err ~= "provider_reset" then
        print("[My Mod] BeamFX registration failed: " .. tostring(err))
        finished = true
    end
    return producer
end

local function tryFirstBeam()
    if finished then
        return
    end

    local now = core.getSimulationTime()
    if now < nextAttemptAt then
        return
    end
    nextAttemptAt = now + 0.5

    local api = I.BeamFX
    if api == nil or api.apiMajor ~= 1 then
        return
    end

    local handle = acquireProducer(api)
    local player = firstPlayer()
    if handle == nil or player == nil or player.cell == nil then
        return
    end

    local spaceKey = api.spaceKeyForCell(player.cell)
    if type(spaceKey) ~= "string" then
        return
    end

    local yaw = player.rotation:getYaw()
    local forwardX = math.sin(yaw)
    local forwardY = math.cos(yaw)
    local position = player.position

    local result, err = handle:upsert("welcome_beam", {
        spaceKey = spaceKey,
        lifecycle = {
            mode = "transient",
            duration = 8.0,
            fadeDuration = 0.5,
        },
        maxSegments = 1,
        segments = {
            {
                startPos = {
                    x = position.x + forwardX * 100,
                    y = position.y + forwardY * 100,
                    z = position.z + 110,
                },
                endPos = {
                    x = position.x + forwardX * 800,
                    y = position.y + forwardY * 800,
                    z = position.z + 110,
                },
                radius = 8,
                outerColor = { 0.05, 0.35, 1.0 },
                coreColor = { 0.80, 0.94, 1.0 },
                coreRatio = 0.24,
                intensity = 2.0,
                style = "electric",
                styleScale = 14,
                seed = 7,
            },
        },
    })

    if result ~= nil then
        finished = true
        print("[My Mod] BeamFX quick-start beam published")
    elseif err == "stale_producer" or err == "provider_reset" then
        producer = nil
    else
        finished = true
        print("[My Mod] BeamFX publish failed: " .. tostring(err))
    end
end

return {
    engineHandlers = {
        onUpdate = tryFirstBeam,
        onLoad = reset,
        onNewGame = reset,
    },
}
```

What should happen:

- within half a simulation second of both systems becoming ready, a blue
  electric beam appears in front of the player;
- it remains for eight simulation-time seconds and fades during the last
  `0.5` seconds;
- the log contains `[My Mod] BeamFX quick-start beam published`;
- if BeamFX is missing, the script quietly waits and the rest of your mod can
  continue.

Reload a save or start a new game to run the one-time example again. If it
reports success but nothing is visible, go directly to
[troubleshooting](#16-troubleshooting).

This first-result script deliberately stays small. Before shipping, add the
provider-session recovery pattern in
[section 10](#10-recovering-after-a-provider-reset).

## 4. Understanding the first beam

The important call is:

```lua
producer:upsert(localBeamId, beamSpec)
```

`localBeamId` belongs only to your producer. Another mod may use the same
local ID without colliding with you.

The beam specification answers four questions:

| Question | Field |
|---|---|
| Where may it render? | `spaceKey` |
| How long does it live? | `lifecycle` |
| How important is it within your own producer? | `priority` |
| What should it look like? | `segments` |

See [styles and friendly starter values](#11-styles-and-friendly-starter-values)
when you are ready to change the look.

Every mutation returns `result, err`. On success, `result` is a table and
`err` is `nil`. On failure, `result` is
`nil` and `err` is a stable string such as `invalid_spec`.

## 5. Which producer method should I use?

| Goal | Method |
|---|---|
| Create a beam or replace its full specification | `upsert` |
| Move or reshape an existing beam | `replaceSegments` |
| Add points to a bounded rolling trail | `appendSegments` |
| Keep a leased persistent visual alive without resending geometry | `renew` |
| End with a hold/fade | `finish` |
| Remove one beam immediately | `remove` |
| Remove all your beams but keep your registration | `clear` |
| Remove everything and invalidate your producer | `release` |
| Inspect your current counts and limits | `stats` |

Always call producer methods with a colon:

```lua
producer:remove("beam_id", "cancelled")
```

The producer handle is runtime-only. Do not put it in an event, saved data, or
another context.

## 6. Common recipes

These are focused snippets rather than complete scripts. They assume
`producer` is your registered producer handle and `spaceKey` is the current
string returned by `I.BeamFX.spaceKeyForCell(...)`.

They also use position names such as `from`, `to`, `firstPoint`, and
`nextPoint`. Each means a current world-coordinate table such as
`{ x = 10, y = 20, z = 30 }`.

### One-shot or projectile beam

Use a transient lifecycle. Use a unique local ID when shots may overlap:

```lua
-- Define this once near the top of your script, outside the firing function:
local shotSerial = 0

-- Run the following whenever your mod fires a visual shot:
shotSerial = shotSerial + 1
local id = "shot_" .. tostring(shotSerial)

local result, err = producer:upsert(id, {
    spaceKey = spaceKey,
    lifecycle = {
        mode = "transient",
        duration = 0.25,
        fadeDuration = 0.10,
    },
    priority = "high",
    maxSegments = 1,
    segments = {
        {
            startPos = from,
            endPos = to,
            radius = 6,
            style = "smooth",
            outerColor = { 1.0, 0.10, 0.05 },
            coreColor = { 1.0, 0.92, 0.80 },
            coreRatio = 0.28,
            intensity = 1.8,
        },
    },
})
```

Reusing an active ID with `upsert` replaces the full beam and restarts its
lifecycle. That is useful for a single repeatedly replaced effect, but not for
overlapping shots.

### Continuous beam

Here, `from` and `to` are the current endpoints. Create the beam once as
persistent:

```lua
producer:upsert("continuous_link", {
    spaceKey = spaceKey,
    lifecycle = { mode = "persistent" },
    priority = "normal",
    maxSegments = 1,
    segments = {
        {
            startPos = from,
            endPos = to,
            radius = 5,
            style = "smooth",
            outerColor = { 0.08, 1.0, 0.18 },
            coreColor = { 0.88, 1.0, 0.90 },
            coreRatio = 0.30,
            intensity = 1.9,
        },
    },
})
```

When either endpoint moves, set `newFrom` and `newTo` to the new world
positions and update only the geometry:

```lua
local result, err = producer:replaceSegments("continuous_link", {
    {
        startPos = newFrom,
        endPos = newTo,
        radius = 5,
        style = "smooth",
        outerColor = { 0.08, 1.0, 0.18 },
        coreColor = { 0.88, 1.0, 0.90 },
        coreRatio = 0.30,
        intensity = 1.9,
    },
})
```

When the effect ends, fade it once:

```lua
producer:finish("continuous_link", {
    holdDuration = 0,
    fadeDuration = 0.14,
})
```

Repeated `finish` calls on the same finishing generation are idempotent and
do not extend the fade.

### Rolling trail

Set `firstPoint` and `secondPoint` to the first two sampled world positions.
Create a persistent beam with a bounded history:

```lua
producer:upsert("movement_trail", {
    spaceKey = spaceKey,
    lifecycle = { mode = "persistent" },
    priority = "low",
    maxSegments = 24,
    segments = {
        {
            startPos = firstPoint,
            endPos = secondPoint,
            radius = 4,
            style = "trail",
            outerColor = { 1.0, 0.18, 0.08 },
            coreColor = { 1.0, 0.92, 0.70 },
            intensity = 1.5,
        },
    },
})
```

As the source moves, set `previousPoint` and `nextPoint` to consecutive sampled
positions and append the new piece:

```lua
producer:appendSegments("movement_trail", {
    {
        startPos = previousPoint,
        endPos = nextPoint,
        radius = 4,
        style = "trail",
        outerColor = { 1.0, 0.18, 0.08 },
        coreColor = { 1.0, 0.92, 0.70 },
        intensity = 1.5,
    },
}, {
    duration = 1.25,
    fadeDuration = 0.75,
})
```

BeamFX accepts the whole valid batch and evicts only the oldest retained
history when `maxSegments` is reached. Memory does not grow without bound.

### Persistent effect with orphan protection

Persistent means there is no mandatory time-to-live:

```lua
lifecycle = { mode = "persistent" }
```

If your producer might disappear without cleanup, opt into a visual-only
lease:

```lua
lifecycle = {
    mode = "persistent",
    leaseSeconds = 5,
}
```

Successful `upsert`, `replaceSegments`, and `appendSegments` calls renew the
configured lease. You can also renew without resending geometry:

```lua
producer:renew("persistent_marker")
-- or use a one-off renewal length:
producer:renew("persistent_marker", 8)
```

Lease expiry removes only the visual. It never changes a gameplay object.

## 7. Beam timing versus segment timing

These are separate:

- **Beam lifecycle** decides when the whole beam finishes or expires.
- **Segment timing** lets individual pieces disappear while the beam remains.

For a transient beam:

```lua
lifecycle = {
    mode = "transient",
    duration = 0.30,
    fadeDuration = 0.10,
}
```

`duration` includes the fade. The beam begins fading at
`duration - fadeDuration`.

Segment timing is most useful for rolling trails:

```lua
segment.duration = 1.25
segment.fadeDuration = 0.75
```

If a segment has no duration, it remains until replacement, rolling eviction,
beam finish/removal, producer release, or provider reset.

`replaceSegments` and `appendSegments` do not extend a transient beam's
overall expiry.

## 8. Positions and spaces

`startPos` and `endPos` are world-coordinate vectors with finite `x`, `y`,
and `z` fields:

```lua
startPos = { x = 10, y = 20, z = 30 }
```

Derive a space key in global context from the object's current Cell. In this
snippet, `object` means a live global `GameObject` owned or trusted by your
mod:

```lua
local spaceKey, err = I.BeamFX.spaceKeyForCell(object.cell)
```

Do not:

- invent your own space string;
- send a raw Cell through an event;
- reuse an old key after the effect changes space.

`spaceKey` is immutable within one beam generation. To move an effect between
spaces:

1. remove the old beam generation;
2. derive the new key from current game state;
3. upsert a new generation in the new space;
4. for a transient effect, use only its real remaining lifetime.

```lua
producer:remove("portal_link", "space_changed")

local newKey, err = I.BeamFX.spaceKeyForCell(object.cell)
if newKey ~= nil then
    -- buildPortalSpec is your function for constructing the current beam.
    producer:upsert("portal_link", buildPortalSpec(newKey))
end
```

Never restart a full transient duration merely because the object crossed a
space boundary.

## 9. Calling from player or local scripts

Player and local scripts cannot call the global BeamFX API directly. Send a
request to a global script in your own mod:

```text
player/local script -> your global event handler -> BeamFX
```

The event normally arrives on a later frame and has no direct return value.
Use a unique, namespaced event name, and treat the payload as a request rather
than trusted game state.

Here is the player-script side. Call `requestBeam(endPos)` from your own input
or gameplay code:

```lua
local core = require("openmw.core")
local self = require("openmw.self")

local EVENT = "author.modname.beams.draw"

local function isFinite(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function copyPosition(value)
    if type(value) ~= "table" and type(value) ~= "userdata" then
        return nil
    end
    local okX, x = pcall(function() return value.x end)
    local okY, y = pcall(function() return value.y end)
    local okZ, z = pcall(function() return value.z end)
    if not okX or not okY or not okZ
        or not isFinite(x) or not isFinite(y) or not isFinite(z)
    then
        return nil
    end
    return { x = x, y = y, z = z }
end

local function requestBeam(endPos)
    local copiedEndPos = copyPosition(endPos)
    if copiedEndPos == nil then
        return false
    end

    core.sendGlobalEvent(EVENT, {
        source = self.object,
        endPos = copiedEndPos,
    })
    return true
end
```

Use the same `EVENT` string in your global adapter. This complete handler
checks the object reference, obtains position and Cell in global context, and
then publishes the visual:

```lua
local I = require("openmw.interfaces")

local EVENT = "author.modname.beams.draw"
local producer = nil

local function isFinite(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function validPosition(value)
    return type(value) == "table"
        and isFinite(value.x)
        and isFinite(value.y)
        and isFinite(value.z)
end

local function acquireProducer(api)
    if producer ~= nil then
        return producer
    end
    producer = api.registerProducer({
        id = "author.modname.beams",
        displayName = "My Mod",
        apiMajor = 1,
    })
    return producer
end

local function onBeamRequest(request)
    if type(request) ~= "table" or not validPosition(request.endPos) then
        return
    end

    local source = request.source
    local validCall, sourceIsValid = pcall(function()
        return source ~= nil and source:isValid()
    end)
    if not validCall or not sourceIsValid then
        return
    end

    local ok, sourceCell, sourcePosition = pcall(function()
        return source.cell, source.position
    end)
    if not ok or sourceCell == nil or sourcePosition == nil then
        return
    end

    -- Add your own gameplay/ownership check here. Do not trust the event alone.

    local api = I.BeamFX
    if api == nil or api.apiMajor ~= 1 then
        return
    end
    local handle = acquireProducer(api)
    if handle == nil then
        return
    end

    local spaceKey = api.spaceKeyForCell(sourceCell)
    if type(spaceKey) ~= "string" then
        return
    end

    local result, err = handle:upsert("requested_beam", {
        spaceKey = spaceKey,
        lifecycle = {
            mode = "transient",
            duration = 0.25,
            fadeDuration = 0.10,
        },
        maxSegments = 1,
        segments = {
            {
                startPos = {
                    x = sourcePosition.x,
                    y = sourcePosition.y,
                    z = sourcePosition.z + 100,
                },
                endPos = request.endPos,
                radius = 6,
                style = "smooth",
                outerColor = { 1.0, 0.10, 0.05 },
                coreColor = { 1.0, 0.92, 0.80 },
                intensity = 1.8,
            },
        },
    })

    if err == "stale_producer" or err == "provider_reset" then
        producer = nil
    elseif result == nil then
        print("[My Mod] BeamFX request failed: " .. tostring(err))
    end
end

local function reset()
    producer = nil
end

return {
    engineHandlers = {
        onLoad = reset,
        onNewGame = reset,
    },
    eventHandlers = {
        [EVENT] = onBeamRequest,
    },
}
```

The same `self.object` sender works in player, local, and custom scripts. Send
a different supported `GameObject` only when that other object—not the script's
attached object—owns the effect. Events may contain finite numbers, strings,
booleans, plain tables, and supported object references.

Do not send:

- a Cell;
- a producer handle;
- a closure;
- a shader handle;
- arbitrary userdata.

Private BeamFX renderer events are not a public API. For persistent requests
or guaranteed delivery, keep the desired effect in your own state and use the
recovery pattern in the next section.

## 10. Recovering after a provider reset

BeamFX visual state is intentionally temporary. Your mod owns the gameplay
reason a persistent effect exists.

Cache the provider session with your producer handle:

```lua
local epoch = I.BeamFX.providerEpoch()
```

Reacquire and reconstruct when:

- the current epoch differs from the cached epoch;
- a producer call returns `stale_producer`;
- a producer call returns `provider_reset`;
- OpenMW loads a game or starts a new game.

A useful wrapper pattern is:

```lua
local function invoke(method, ...)
    local producer, acquireErr = acquireProducer()
    if producer == nil then
        return nil, acquireErr
    end

    local operation = producer[method]
    local result, err = operation(producer, ...)
    if err == "stale_producer" or err == "provider_reset" then
        forgetProducer()
    end
    return result, err
end
```

After acquiring a new producer, republish persistent visuals from your mod's
own current game state. Do not treat BeamFX diagnostics as saved gameplay.

## 11. Styles and friendly starter values

All style names are lowercase.

| Style | `radius` | `styleScale` | Notes |
|---|---:|---:|---|
| `smooth` | `4..8` | `0` | clean laser or link |
| `electric` | `6..10` | `8..18` | animated jagged energy |
| `plasma` | `7..14` | `6..18` | noisy bright energy |
| `trail` | `3..7` | `0` | best with segment timing |

Useful general starting values:

```lua
coreRatio = 0.24
intensity = 1.5
opacity = 1.0
```

Colors are RGB tables. Values from `0` to `1` are easiest to reason about,
although API 1 accepts finite values through `4` for bright effects:

```lua
outerColor = { 0.05, 0.35, 1.0 }
coreColor = { 0.80, 0.94, 1.0 }
```

Plasma has two extra rules:

- an ordinary plasma segment uses seed `1..15`;
- a plasma origin-glow segment uses `originGlow = true` and effective seed
  `0`.

Consumers cannot supply GLSL, shader filenames, uniforms, packed metadata, or
custom shader styles.

## 12. Cleanup

Use the narrowest operation that matches your ownership:

```lua
producer:finish("beam_id", {
    holdDuration = 0,
    fadeDuration = 0.14,
})

producer:remove("beam_id", "cancelled")
producer:clear("scene_reset")
producer:release("mod_shutdown")
```

- `finish` gives one beam a terminal hold/fade.
- `remove` immediately removes one beam.
- `clear` removes only this producer's beams and retains the handle.
- `release` removes this producer's beams and invalidates the handle.

One producer can never clear or remove another producer's effects.

## 13. Capacity guidance

The shader can display 64 segments and 16 palettes per frame. Logical state
has larger bounded quotas, but publishing unnecessary geometry still costs
validation, storage, routing, and scheduling work.

Good producer behavior:

- use one segment for a straight beam;
- choose the smallest useful `maxSegments`;
- call `replaceSegments` only when geometry changed;
- append trail pieces at a bounded rate;
- reuse a stable beam ID for a single continuous effect;
- use unique IDs only when effects genuinely overlap;
- clear or release effects you no longer own;
- avoid changing colors every frame unless the appearance truly changes.

Priority is only an ordering hint within your producer. It cannot starve
another producer.

## 14. Handling errors

### Usually retry after reacquiring

| Error/status | Meaning |
|---|---|
| `provider_unavailable` | BeamFX is not currently available |
| `provider_reset` | the provider cannot service this call while resetting or recovering |
| `stale_producer` | this handle belongs to an old or released registration |

Retry at a low bounded rate. Do not spam the log every frame.

### Fix ownership or configuration

| Error | Meaning |
|---|---|
| `producer_id_in_use` | that ID already has a live registration, including a handle your adapter acquired earlier |
| `unsupported_api` | the requested API major is incompatible |
| `duplicate_provider` | multiple incompatible BeamFX copies are present |

Never adopt a producer returned to another script. Use a unique stable ID and
remove duplicate installations.

### Fix the request

| Error | First thing to inspect |
|---|---|
| `invalid_space_key` | the object's current Cell and space |
| `invalid_spec` | unknown fields, non-finite values, style-specific rules |
| `no_valid_segments` | the required segment list is empty |
| `invalid_style` | built-in style name |
| `beam_not_found` | local beam ID and reconstruction state |
| `beam_finishing` | the current generation is terminal after finish or natural expiry; upsert a new generation |
| `producer_quota_exceeded` | a registered-producer or active-beam limit was reached, per producer or globally |
| `segment_quota_exceeded` | batch or retained geometry size |
| `lease_not_enabled` | beam lifecycle lacks `leaseSeconds` |

Geometry mutations are atomic. If one submitted segment is invalid, BeamFX
rejects the entire batch and retains the previous valid state.

## 15. Diagnostics

From a global script:

```lua
local capabilities = I.BeamFX and I.BeamFX.capabilities()
local diagnostics = I.BeamFX and I.BeamFX.diagnostics()
local stats = producer and producer:stats()
```

Useful checks:

- `capabilities.styles` — available built-in styles;
- `capabilities.quotas` — current public bounds;
- `diagnostics.current.registeredProducers` — live producer count;
- `stats.activeBeams` and `stats.retainedSegments` — your current state.

`diagnostics()` and `stats()` are read-only snapshots.

The player-local renderer exposes:

```lua
local status = I.BeamFXRenderer and I.BeamFXRenderer.status()
```

`status.role` is `ownership_pending` while startup ownership is resolving,
`primary` for the active renderer, or `inert` for an inactive duplicate. The
remaining status fields help diagnose shader loading and upload health.
Renderer health does not turn a valid global producer mutation into a
gameplay error.

## 16. Troubleshooting

### `I.BeamFX` is nil

- Confirm BeamFX is an active data root.
- Confirm `beamfx.omwscripts` is enabled.
- Confirm your caller is a global script.
- Acquire lazily; the provider initializes on a deferred update.

### Registration returns `producer_id_in_use`

- Search for duplicate copies of your adapter.
- Confirm two mods did not choose the same producer ID.
- Confirm your adapter did not discard an earlier live handle without
  releasing it.
- During a load/reset transition, retry slowly until the old provider session
  has finished resetting.

### The API accepts the beam, but nothing is visible

- Confirm postprocessing is enabled.
- Check the log for `Beam shader loaded`.
- Confirm the viewer and beam share the same current space.
- Confirm the transient duration is long enough to survive your update and
  render cadence.
- Check `I.BeamFXRenderer.status()` from player-local context.
- Check that `opacity`, `intensity`, and `radius` are not effectively zero.

### A continuous beam disappears after load

That is expected unless your mod reconstructs it. On load/new game/provider
reset, reacquire a producer and republish persistent visuals from
current game state.

### A trail grows forever

Set a bounded `maxSegments` and use `appendSegments`. Add segment duration and
fade if old pieces should disappear before rolling eviction.

### A beam remains visible after an actual space change

Derive a fresh key from the object's current Cell and compare it with the
beam's stored key. Adjacent exterior Cells normally share one worldspace key,
so crossing an ordinary exterior Cell boundary requires no rebuild. Only when
the newly derived key differs should you remove the old generation and upsert
a new one in the new space.

## 17. Production checklist

Before shipping a BeamFX integration:

- [ ] The producer ID is unique, stable, and namespaced.
- [ ] The global adapter checks API major `1`.
- [ ] Missing BeamFX affects visuals only.
- [ ] Warnings are rate-limited.
- [ ] The producer handle and provider session are cached together.
- [ ] `stale_producer` and `provider_reset` trigger reacquisition.
- [ ] Persistent visuals reconstruct after load and new game.
- [ ] Raw Cells and producer handles never cross events.
- [ ] Space transitions use remove plus a new generation.
- [ ] Geometry updates are bounded and sent only when dirty.
- [ ] Trails use a bounded `maxSegments`.
- [ ] Every owned effect has a finish, remove, clear, or release path.
- [ ] The integration has been tested with postprocessing unavailable.

## Where to go next

- [API reference](API.md) — exact fields, ranges, returns, quotas, and errors.
- [Architecture](ARCHITECTURE.md) — provider, broker, routing, and renderer
  internals.
- [README](../README.md) — installation and package overview.
