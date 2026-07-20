# BeamFX public API 1.3

BeamFX `0.1.0-alpha.4` exposes one global OpenMW interface:

```lua
local I = require("openmw.interfaces")
local BeamFX = I.BeamFX
```

The interface is available only between global scripts. A player, local, or custom consumer sends a namespaced serializable event to its own global adapter; that adapter validates gameplay state and calls BeamFX. BeamFX's private render events are not a public producer API.

BeamFX is visual only. Segment geometry, taper, fades, and longitudinal masks
do not perform raycasts, collision, targeting, or damage. Producer Lua owns
every gameplay decision and submits only the visual result.

For the shortest path from two points to a visible effect, register once and
use `emit`:

```lua
local beamId, err, detail = producer:emit({
    cell = player.cell,
    from = startPos,
    to = endPos,
    preset = "frost",
})
```

`emit` supplies a transient lifecycle, creates the segment, and generates a
unique beam ID. The canonical `upsert` API remains available when an author
needs complete lifecycle and geometry control.

For a tutorial and copy-paste recipes, start with
[`USAGE.md`](USAGE.md). This document is the exact API contract.

## Independent versions

| Track | Value |
|---|---|
| Package | `0.1.0-alpha.4` |
| Public API major/minor | `1.3` |
| Private render protocol | `3` |
| Shader ABI | `3` |
| Producer API shape | `facade` |

API 1.3 changes only the global authoring surface. The private render protocol
and shader ABI remain at version `3`.

Backward-compatible public additions increment `apiMinor`. Breaking public changes increment `apiMajor`. Private packet changes increment `protocolVersion`; uniform or packed-metadata changes increment `shaderAbi`.

Check compatibility before registering:

```lua
if I.BeamFX == nil or I.BeamFX.apiMajor ~= 1 then
    -- Beam visuals are unavailable. Gameplay continues.
    return
end
```

The static interface fields and methods are:

```text
apiMajor
apiMinor
version
protocolVersion
shaderAbi
capabilities()
diagnostics()
providerEpoch()
registerProducer(spec)
spaceKeyForCell(cell)
```

`capabilities()` and `diagnostics()` return defensive copies. `providerEpoch()` returns the current opaque session token after the primary provider initializes. Consumers discard old producer facades and reconstruct their visuals whenever the epoch changes.

## Capability discovery

`I.BeamFX.capabilities()` is available before deferred provider initialization and describes the selected build without allocating broker state:

```lua
{
    apiMajor = 1,
    apiMinor = 3,
    version = "0.1.0-alpha.4",
    protocolVersion = 3,
    shaderAbi = 3,
    shaderResource = "beamfx_core_v3",
    producerApiShape = "facade",
    styles = { string, ... },
    presets = {
        "frost",
        "fire",
        "lightning",
        "laser",
        "fishing_line",
        "energy_blade",
    },
    producerMethods = {
        "upsert",
        "emit",
        "upsertPath",
        "replaceSegments",
        "appendSegments",
        "renew",
        "finish",
        "remove",
        "clear",
        "release",
        "stats",
    },
    convenienceMethods = { "emit", "upsertPath" },
    longitudinalModes = { "solid", "travel", "pulse", "dash" },
    minPixelWidthStyles = { "filament" },
    segmentCapacity = 64,
    paletteCapacity = 16,
    lifecycleModes = { "transient", "persistent" },
    audienceModes = { "same_space" },
    spaceFiltering = true,
    coalescing = {
        fullSnapshots = true,
        latestRevisionPerUpdate = true,
        terminalPrecedence = true,
    },
    optionalLeases = true,
    features = {
        globalProvider = true,
        globalDiagnostics = true,
        playerPostprocessing = true,
        perViewerRouting = true,
        targetedReconciliation = true,
        segmentTaper = true,
        segmentMinPixelWidth = true,
        segmentBaseMaterial = true,
        segmentSpatialFades = true,
        segmentSoftDepth = true,
        segmentFogInfluence = true,
        segmentLongitudinal = true,
        appearancePresets = true,
        colorShorthand = true,
        segmentDefaults = true,
        producerEmit = true,
        producerPaths = true,
        structuredErrorDetails = true,
    },
    quotas = {
        maxProducerIdLength = number,
        maxProducerDisplayNameLength = number,
        maxBeamIdLength = number,
        maxEpochLength = number,
        maxRendererSessionLength = number,
        maxSpaceKeyLength = number,
        maxReasonLength = number,
        maxAbsCoordinate = number,
        maxRegisteredProducers = number,
        maxBeamsPerProducer = number,
        maxBeamsGlobal = number,
        maxRetainedSegmentsPerProducer = number,
        maxRetainedSegmentsGlobal = number,
        defaultMaxSegments = number,
        maxSegmentsPerBeam = number,
        maxInputSegments = number,
        maxTombstonesPerViewer = number,
    },
    fairness = {
        capacity = 64,
        maxPublicServiceWindowFrames = 2,
        temporaryBridgeProducerGroups = 0,
        maxServiceWindowFrames = 2,
        serviceWindowFormula = "ceil(P / 64)",
    },
}
```

`producerApiShape` identifies the bound eleven-method producer facade
documented below. `producerMethods` lists its complete surface;
`convenienceMethods` identifies the two API 1.3 authoring helpers. `presets`
advertises every accepted appearance preset in deterministic order.
`shaderResource` names the renderer-owned shader resource;
`longitudinalModes` and `minPixelWidthStyles` advertise the exact public
feature subsets. `features` declares implemented framework surfaces, `quotas`
names every advertised input/state bound, and `fairness` describes the shared
compositor service bound. `temporaryBridgeProducerGroups` is a reserved
compatibility field and is always `0` in this release; the public and overall
maximum service windows are therefore both two frames. Consumers should
inspect keys they depend on and tolerate future backward-compatible keys
after an API-minor compatibility check.

## Global diagnostics

`I.BeamFX.diagnostics()` is read-only and session-scoped. It never registers a producer, changes a revision, renews a lease, dirties geometry, or sends a render packet. Provider reset starts a fresh diagnostic session together with the new provider epoch.

```lua
{
    apiMajor = 1,
    apiMinor = 3,
    version = "0.1.0-alpha.4",
    providerEpoch = string,
    current = {
        registeredProducers = number,
        brokerProducerStates = number,
        activeBeams = number,
        retainedSegments = number,
        pendingChanges = number,
        updateSerial = number,
        viewers = number,
        readyViewers = number,
        deliveredBeams = number,
        rendererTombstones = number,
    },
    cumulative = {
        successfulMutations = number,
        acceptedSegments = number,
        invalidRequests = number,
        createdBeamGenerations = number,
        removedBeamGenerations = number,
        registrationAttempts = number,
        successfulRegistrations = number,
        boundaryInvalidRequests = number,
        staleProducerRequests = number,
        releasedProducers = number,
    },
    producers = {
        {
            producerId = string,
            producerGeneration = number,
            displayName = string,
            current = {
                activeBeams = number,
                retainedSegments = number,
            },
            cumulative = {
                successfulMutations = number,
                acceptedSegments = number,
                invalidRequests = number,
                createdBeamGenerations = number,
                removedBeamGenerations = number,
                boundaryInvalidRequests = number,
                staleProducerRequests = number,
            },
        },
    },
}
```

`producers` contains live registrations and is sorted by normalized producer ID, then generation. A registered producer that has not called the broker has zero broker counters and is still listed. Released registrations leave the live list; their release and accepted work remain in the aggregate counters until provider reset.

Counter semantics are exact:

- `successfulMutations` counts successful facade mutation calls that changed broker state; `release` counts because it removes the broker registration. It excludes initial registration, `stats`, idempotent `finish`/`remove`, and an empty `clear`.
- `acceptedSegments` sums complete successful `upsert`, `emit`, `upsertPath`, `replaceSegments`, and `appendSegments` batches. Rejected and partial batches contribute zero.
- `invalidRequests` is the sum of broker-operation rejections and registry-boundary rejections. Boundary rejections include malformed/duplicate/quota registration attempts, stale facade calls, and contained callback/result failures.
- `createdBeamGenerations` counts successful `upsert`, `emit`, and `upsertPath` calls that created a generation.
- `removedBeamGenerations` includes explicit remove/clear/release, superseding upsert, natural/lease/finish expiry, and other broker removals within the current provider epoch.
- `brokerProducerStates` may be smaller than `registeredProducers` because a newly registered facade does not allocate broker state until its first broker call.

These are provider-global broker, registry, and routing diagnostics. The `viewers`, `readyViewers`, `deliveredBeams`, and `rendererTombstones` values summarize global per-viewer routing state; they do not report what any one player's shader rendered.

## Player-local renderer status

The player-context singleton is diagnostic infrastructure for the local renderer, not a producer API:

```lua
local Renderer = I.BeamFXRenderer

Renderer.version         -- "0.1.0-alpha.4"
Renderer.protocolVersion -- 3
Renderer.shaderAbi       -- 3
local status = Renderer.status()
```

`I.BeamFXRenderer.status()` returns a new per-viewer status table:

```lua
{
    role = "ownership_pending" | "primary" | "inert",
    compatibleBase = boolean,
    rendererLoaded = boolean,
    rendererLoadFailed = boolean,
    rendererSession = string | nil,
    readySerial = number,
    providerEpoch = string | nil,
    providerEpochConfirmed = boolean | nil,
    viewerSyncGeneration = number,
    tombstoneCount = number | nil,
    blockedSyncGeneration = number | nil,
    resyncRequested = boolean | nil,
    retiredProviderEpochs = number | nil,

    retainedBeams = number | nil,
    retainedSegments = number | nil,
    eligibleSegments = number | nil,
    renderedSegments = number | nil,
    culledBySpace = number | nil,
    culledByCapacity = number | nil,
    paletteCount = number | nil,
    paletteOverflow = boolean | nil,
    uploadHealthy = boolean | nil,

    rendererAvailable = boolean | nil,
    shaderLoaded = boolean | nil,
    shaderEnabled = boolean | nil,
    error = "duplicate_provider" | nil,
}
```

Renderer/protocol fields marked `nil` are absent until the deferred first
player frame successfully loads the renderer. `retainedBeams` and
`retainedSegments` count copied local public-producer render state.
`eligibleSegments` is the current-space, live set whose lifecycle opacity is
positive and whose segment `opacity` or `baseOpacity` is positive, before
intensity and longitudinal-mask evaluation and before the 64-slot scheduler;
`renderedSegments` is the selected/uploaded count.
`culledBySpace` counts retained segments rejected by the independent
player-space check, while `culledByCapacity` is eligible minus selected.
`paletteCount` is the uploaded combined appearance/feature-profile count and
`paletteOverflow` reports pressure beyond 16 compatible profiles.

`rendererAvailable` means the local postprocessing API and callable shader loader exist. `shaderLoaded` and `shaderEnabled` report the local shader handle and enable state; `uploadHealthy` reports the most recent uniform-upload health. These fields are per-viewer observations and never turn a valid global producer mutation into an error. An inert compatible duplicate delegates `status()` to the original player singleton; an incompatible duplicate reports `error = "duplicate_provider"` and remains side-effect free.

## Why the API returns a producer facade

OpenMW 0.51 was tested with a provider global script and a separate consumer global sandbox. A table of bound closures returned by `registerProducer` remained callable over multiple updates, retained its captured generation, rejected use after release, and allowed generation-2 re-registration. Forward and reversed duplicate load orders were also tested. A separate run exercised the exact colon-method form documented below.

The selected API major 1 shape is therefore:

```lua
local producer, err = I.BeamFX.registerProducer({
    id = "example.author.mod.beams",
    displayName = "Example beam producer",
    apiMajor = 1,
})

local result, opErr = producer:upsert("beam_1", beamSpec)
```

Producer IDs are normalized to lowercase. They must be nonempty, no longer than 96 bytes, use only ASCII letters, digits, `.`, `_`, and `-`, begin with an alphanumeric character, and remain stable within a provider epoch. Conventionally namespaced IDs avoid collisions. Display names are limited to 128 bytes.

`apiMajor` is required and must equal `1`. Optional `apiMinor` defaults to
`0` and must be a nonnegative integer; a consumer requiring a later minor
must inspect the provider before registration. Optional `displayName`
defaults to the normalized producer ID. Unknown registration fields and
control characters are rejected.

Registration is deliberately not idempotent by public string:

- The first live registration of an ID in one provider epoch succeeds.
- A second live registration returns `nil, "producer_id_in_use"` and never leaks the existing facade.
- Every successful registration receives the next session-wide `producerGeneration`; `release` invalidates the facade and permits the same ID to register with a different generation.
- The allocator is constant-space and never retains released producer IDs. If its safe-integer space is exhausted, registration fails closed with `provider_reset` until provider reset begins a fresh epoch and allocator.
- Provider reset invalidates every facade.
- Every operation through a released or reset facade returns `nil, "stale_producer"`.

The facade is runtime-only. Never put it in an event, saved data, or render packet.

## Producer methods

Every method returns `result, nil` on success or
`nil, "stable_error_code", detail` on failure. The third value is optional:

```lua
detail = {
    path = "segments[2].minPixelWidth",
    reason = "requires_filament",
    message = "minPixelWidth is only supported by the filament style.",
}
```

`path` locates the rejected input, `reason` is a concise machine-readable
diagnostic, and `message` is written for a mod author. Existing consumers that
read only the first two return values remain compatible. Callers must continue
to branch on the stable second error code; the detail is explanatory and is
not guaranteed for every failure. Returned detail tables are defensive copies.

### `producer:upsert(localBeamId, spec)`

Atomically creates or replaces the complete beam specification and geometry. It
starts or restarts both the lifecycle and the longitudinal animation clock.
Upserting an active generation increments its revision and stamps a new
`animationStartedAt`; upserting a removed or finishing local ID creates a new
`beamGeneration`.

Success:

```lua
{
    id = localBeamId,
    producerGeneration = number,
    beamGeneration = number,
    revision = number,
    acceptedSegments = number,
    retainedSegments = number,
    created = boolean,
}
```

### `producer:emit(spec)`

Creates one short-lived beam or connected path and returns a generated opaque
beam ID:

```lua
local beamId, err, detail = producer:emit({
    cell = player.cell, -- or spaceKey = "..."

    -- Choose exactly one geometry form:
    from = startPos,
    to = endPos,
    -- points = { a, b, c, ... },

    preset = "frost",
    color = { 0.20, 0.65, 1.00 },
    radius = 6,

    duration = 0.25,
    fadeDuration = 0.10,
})
```

The generated ID is unique among the producer's live beams at insertion time
and cannot overwrite a manually named beam. Treat its exact spelling as
opaque. On success the return value is the ID string itself, not the ordinary
upsert result table. Retain it only if later `finish` or `remove` control is
needed.

`cell` and `spaceKey` are mutually exclusive. A supplied Cell is converted
immediately by `spaceKeyForCell`; BeamFX never retains the raw engine object.
This Cell convenience is therefore available only to a producer running in
global context. A player/local script must resolve the authoritative Cell in
its global adapter, or send a primitive `spaceKey`.

Geometry is either both `from` and `to`, or a dense `points` array containing
2 through 257 finite positions. `points` creates one connected segment between
each adjacent pair. The helper calculates cumulative
`longitudinal.pathOffset` values automatically.

The default lifecycle is:

```lua
lifecycle = {
    mode = "transient",
    duration = 0.25,
    fadeDuration = 0.10,
}
```

Top-level `duration` and `fadeDuration` override those defaults. A supplied
`lifecycle` table may override them too, but its mode must be `transient`;
`emit` rejects persistent lifecycle. Duration still includes its fade interval.

The top-level appearance keys accepted by `emit` are the canonical segment
appearance and longitudinal fields documented below plus `preset` and
`color`; endpoints and timing are exceptions. They become defaults for every
generated segment. `segmentDefaults` accepts every segment field except
`startPos` and `endPos`, including segment-relative `duration` and
`fadeDuration`. Top-level `duration`/`fadeDuration` always describe the beam
lifecycle.

`audience`, `priority`, and `maxSegments` have the same meanings as canonical
`upsert`. When omitted, `maxSegments` becomes the greater of `24` and the
generated segment count.

### `producer:upsertPath(localBeamId, spec)`

Creates or replaces a named connected path without manually constructing
segments:

```lua
local result, err, detail = producer:upsertPath("fishing_line", {
    cell = player.cell, -- or spaceKey
    points = {
        rodTip,
        sagPoint1,
        sagPoint2,
        bobber,
    },
    preset = "fishing_line",
})
```

`upsertPath` accepts the same space, geometry, appearance, audience, priority,
and `maxSegments` inputs as `emit`; `from` plus `to` is also valid for a
one-segment path. It returns the ordinary `upsert` result table and applies the
same atomic replacement, generation, revision, and animation-clock rules.

Unlike `emit`, an omitted lifecycle defaults to `{ mode = "persistent" }`.
Supplying top-level `duration` or `fadeDuration` selects a transient lifecycle
with the same `0.25`/`0.10` defaults for an omitted companion field. A complete
canonical `lifecycle` table is also accepted.

Each generated segment joins consecutive points. Its
`longitudinal.pathOffset` equals the supplied base offset (default `0`) plus
the cumulative world-space length of all preceding segments. For looping
`travel`, an omitted `loopLength` is set to the complete path length. As with
`emit`, a supplied Cell is converted immediately and never retained.

### `producer:replaceSegments(localBeamId, segments, options)`

Atomically replaces only geometry and segment-relative timing. It preserves the
enclosing beam lifecycle and its `animationStartedAt`, so traveling, pulsing,
and dashed patterns keep their phase. It never extends transient beam expiry.
Per-segment timing fields take precedence over operation defaults.

Success:

```lua
{
    id = localBeamId,
    beamGeneration = number,
    revision = number,
    acceptedSegments = number,
    retainedSegments = number,
}
```

### `producer:appendSegments(localBeamId, segments, options)`

Atomically appends a complete batch through the rolling history policy. It
preserves `animationStartedAt`, so new connected pieces share the existing
pattern clock. A batch larger than the beam's `maxSegments` is rejected. A
valid batch is accepted in full; only older retained history may be evicted.

Success:

```lua
{
    id = localBeamId,
    beamGeneration = number,
    revision = number,
    acceptedSegments = number,
    retainedSegments = number,
    evictedSegments = number,
}
```

### `producer:renew(localBeamId, leaseSeconds)`

Renews an opted-in persistent lease without dirtying or resending geometry. Omit `leaseSeconds` to use the beam's configured lease length. A supplied finite positive value applies to this renewal only.

Success:

```lua
{
    id = localBeamId,
    beamGeneration = number,
    revision = number,
    leaseExpiresAt = number,
}
```

### `producer:finish(localBeamId, options)`

Cancels transient or lease timing and starts one terminal hold/fade schedule at
broker simulation time. It preserves `animationStartedAt`; finishing does not
restart a longitudinal pattern.

```lua
options = {
    holdDuration = 0,
    fadeDuration = 0.14,
}
```

Both finish durations must be finite and nonnegative; they are not clamped.
Repeated finish on the same finishing generation is idempotent and does not
extend it.

Success:

```lua
{
    id = localBeamId,
    beamGeneration = number,
    revision = number,
    finishing = true,
    idempotent = boolean,
}
```

### `producer:remove(localBeamId, reason)`

Removes the current generation immediately. Repeated remove on an absent ID succeeds idempotently and sends no new removal.

Success:

```lua
{
    id = localBeamId,
    removed = boolean,
    idempotent = boolean,
    beamGeneration = number | nil,
    terminalRevision = number | nil,
}
```

Reasons are optional diagnostic strings limited to 128 bytes.

### `producer:clear(reason)`

Removes every beam owned by this producer while retaining its registration:

```lua
{
    removedBeams = number,
    removedSegments = number,
}
```

### `producer:release(reason)`

Removes every owned beam and invalidates the facade:

```lua
{
    released = true,
    removedBeams = number,
    removedSegments = number,
}
```

### `producer:stats()`

Returns a defensive, read-only snapshot. It does not mutate state, increment revisions, dirty geometry, or renew a lease:

```lua
{
    producerId = string,
    producerGeneration = number,
    activeBeams = number,
    retainedSegments = number,
    limits = {
        activeBeams = 128,
        retainedSegments = 2048,
    },
    cumulative = {
        successfulMutations = number,
        acceptedSegments = number,
        invalidRequests = number,
        createdBeamGenerations = number,
        removedBeamGenerations = number,
        boundaryInvalidRequests = number,
        staleProducerRequests = number,
    },
}
```

## API 1.3 authoring conveniences

Presets, `color`, and `segmentDefaults` are input conveniences. BeamFX expands
them into the canonical segment schema before validation and storage. They add
no shader type, uniform, render-protocol field, or saved state.

### Appearance presets

Accepted preset names are case-insensitive; spaces and hyphens normalize to
underscores. For example, `"Fishing Line"` and `"fishing-line"` select
`fishing_line`. Unknown names return `invalid_spec` with an
`unknown_preset` detail reason.

Every API 1.3 preset expands to these exact canonical values:

```lua
frost = {
    style = "smooth",
    radius = 6,
    outerColor = { 0.20, 0.65, 1.00 },
    coreColor = { 0.82, 0.96, 1.15 },
    baseColor = { 0.04, 0.13, 0.22 },
    coreRatio = 0.30,
    intensity = 1.25,
    opacity = 0.92,
    baseOpacity = 0.12,
    depthSoftness = 3,
    fogInfluence = 0.70,
}

fire = {
    style = "plasma",
    radius = 8,
    outerColor = { 1.00, 0.18, 0.025 },
    coreColor = { 1.35, 0.82, 0.28 },
    baseColor = { 0.28, 0.035, 0.005 },
    coreRatio = 0.22,
    intensity = 1.65,
    opacity = 0.95,
    baseOpacity = 0.12,
    depthSoftness = 3,
    fogInfluence = 0.25,
    styleScale = 10,
}

lightning = {
    style = "electric",
    radius = 5,
    outerColor = { 0.26, 0.52, 1.00 },
    coreColor = { 1.05, 1.22, 1.45 },
    baseColor = { 0.04, 0.09, 0.22 },
    coreRatio = 0.18,
    intensity = 1.75,
    opacity = 1.00,
    baseOpacity = 0.06,
    depthSoftness = 2,
    fogInfluence = 0.30,
    styleScale = 12,
}

laser = {
    style = "smooth",
    radius = 3,
    outerColor = { 1.00, 0.08, 0.04 },
    coreColor = { 1.40, 0.85, 0.70 },
    baseColor = { 0.24, 0.015, 0.008 },
    coreRatio = 0.22,
    intensity = 1.80,
    opacity = 1.00,
    baseOpacity = 0.08,
    depthSoftness = 1,
    fogInfluence = 0.20,
}

fishing_line = {
    style = "filament",
    radius = 0.10,
    minPixelWidth = 0.75,
    outerColor = { 0.36, 0.43, 0.50 },
    coreColor = { 0.78, 0.84, 0.90 },
    baseColor = { 0.11, 0.13, 0.15 },
    coreRatio = 0.35,
    intensity = 0.45,
    opacity = 0.80,
    baseOpacity = 0.35,
    depthSoftness = 1,
    fogInfluence = 1.00,
}

energy_blade = {
    style = "smooth",
    radius = 6,
    outerColor = { 0.05, 0.45, 1.00 },
    coreColor = { 1.15, 1.35, 1.60 },
    baseColor = { 0.02, 0.10, 0.22 },
    coreRatio = 0.50,
    intensity = 2.20,
    opacity = 1.00,
    baseOpacity = 0.10,
    depthSoftness = 2,
    fogInfluence = 0.25,
}
```

These are curated starting appearances. A preset never adds particles,
collision, damage, a channeled-spell controller, or a motion ribbon.
`energy_blade`, for example, is a static smooth-beam appearance.

### One-color shorthand

`color = { r, g, b }` derives the three canonical colors:

```text
outerColor[i] = color[i]
coreColor[i]  = min(4, 0.75 + 0.45 * color[i])
baseColor[i]  = min(1, 0.22 * color[i])
```

The input follows `outerColor`'s finite `0..4` component normalization. Any
explicit `outerColor`, `coreColor`, or `baseColor` at the same layer overrides
only that derived field.

### Segment defaults and precedence

Canonical `upsert` accepts an optional `segmentDefaults` table. It may contain
any segment field except `startPos` and `endPos`, plus `preset` and `color`:

```lua
producer:upsert("arc", {
    spaceKey = spaceKey,
    lifecycle = { mode = "transient", duration = 0.30 },
    segmentDefaults = {
        preset = "lightning",
        radius = 5,
        intensity = 1.5,
    },
    segments = {
        { startPos = a, endPos = b },
        { startPos = b, endPos = c, radius = 8 },
        { startPos = c, endPos = d, color = { 0.7, 0.2, 1.0 } },
    },
})
```

For each segment, expansion order is:

1. The segment's preset, if supplied; otherwise the default preset.
2. `segmentDefaults.color`, then explicit canonical fields in
   `segmentDefaults`.
3. The segment's `color`, then explicit canonical fields on that segment.

Later values win. Thus a segment can replace the preset, its `color` replaces
default-derived colors, and an explicit `coreColor` on that same segment
replaces only the core derived from its `color`. Non-appearance segment
fields, including `longitudinal` and segment-relative timing, follow the same
default-then-segment precedence.

`preset` and `color` are also accepted directly on individual segment entries
passed to `replaceSegments` and `appendSegments`. Those methods do not have a
beam-level `segmentDefaults` argument; their existing operation options remain
the place for segment timing defaults.

For `emit` and `upsertPath`, segment appearance/longitudinal fields, `preset`,
and `color` may be written at the helper's top level for the common case. A supplied
`segmentDefaults` table overrides matching top-level fields before each
generated segment is expanded. This is a field-by-field merge: `color` does
not erase a separately supplied explicit `outerColor`, `coreColor`, or
`baseColor`; normal explicit-color precedence still applies afterward.

## Beam schema

```lua
{
    spaceKey = I.BeamFX.spaceKeyForCell(authoritativeObject.cell),

    lifecycle = {
        mode = "transient", -- or "persistent"
        duration = 0.22,
        fadeDuration = 0.10,
    },

    audience = {
        mode = "same_space",
    },

    priority = "normal", -- low, normal, high
    maxSegments = 24,

    -- Optional API 1.3 input convenience; not retained.
    segmentDefaults = {
        preset = "frost",
        radius = 6,
    },

    segments = { ... },
}
```

`lifecycle` is required. `audience` defaults to `{ mode = "same_space" }`;
this is the only public v1 audience mode. `priority` defaults to `normal`;
priority strings are normalized to lowercase. `maxSegments` defaults to 24,
is floored, and is clamped to `1..256`. `segmentDefaults` is expanded and
discarded before the canonical specification reaches the broker. Unknown beam,
lifecycle, audience, segment-default, segment, operation-option, and
finish-option fields are rejected.

`spaceKey` and `audience` are immutable within one beam generation. To move an effect, remove the old generation and upsert a new generation in the new space using only the authoritative remaining transient lifetime. Never restart a full transient duration during a move.

### Transient lifecycle

```lua
lifecycle = {
    mode = "transient",
    duration = 0.22,
    fadeDuration = 0.10,
}
```

Both values are relative seconds. Duration must be finite and positive. Fade
defaults to `0`, must be finite and nonnegative when supplied, and is clamped
down to duration. Duration includes fade. The broker stamps:

```text
createdAt   = current simulation time
fadeStartAt = createdAt + duration - fadeDuration
expiresAt   = createdAt + duration
```

Replace and append do not extend this expiry.

At exact natural expiry, the broker culls the beam but retains a one-provider-update terminal handoff. An owner `finish` arriving at that boundary may supersede natural removal and stamp the terminal fade regardless of global-script update order. Other mutations fail. Without boundary finish, the visual never renders beyond its old deadline.

### Persistent lifecycle

```lua
lifecycle = {
    mode = "persistent",
}
```

This has no mandatory TTL. It can survive arbitrary simulation time until finish, remove, producer release, or provider reset. Geometry remains bounded by `maxSegments` and the producer/global quotas.

Optional orphan protection:

```lua
lifecycle = {
    mode = "persistent",
    leaseSeconds = 5,
}
```

Successful upsert, replace, and append renew the configured lease. `renew` can extend it without resending geometry. Lease abandonment removes only the visual; BeamFX never cancels, removes, damages, or expires a gameplay object.

Persistent lifecycle rejects transient-only `duration` and `fadeDuration` fields.

## Segment schema

```lua
{
    startPos = { x = 0, y = 0, z = 0 },
    endPos = { x = 100, y = 0, z = 0 },

    -- Optional API 1.3 input conveniences; not retained.
    preset = "lightning",
    color = { 0.20, 0.65, 1.00 },

    -- radius is the fallback for omitted endpoint radii.
    radius = 5.5,
    startRadius = 5.5,
    endRadius = 1.0,
    minPixelWidth = 0,

    outerColor = { 0.08, 0.45, 1.0 },
    coreColor = { 0.75, 0.96, 1.0 },
    coreRatio = 0.28,
    intensity = 1.45,
    opacity = 1.0,

    baseColor = { 0.02, 0.03, 0.04 },
    baseOpacity = 0,
    startFadeLength = 0,
    endFadeLength = 8,
    depthSoftness = 2,
    fogInfluence = 1,

    style = "electric",
    styleScale = 14,
    seed = 3,
    originGlow = false,

    longitudinal = {
        mode = "dash",
        pathOffset = 0,
        dashLength = 12,
        gapLength = 7,
        speed = 30,
        fadeLength = 1,
    },

    duration = 0.25,
    fadeDuration = 0.14,
}
```

Public API 1 segments have no caller-defined ID. Supplying `segment.id` returns
`invalid_spec`. `preset` and `color` are expanded into the canonical fields
below and are not retained. The broker assigns a monotonically increasing
internal serial within the beam generation for identity, ordering, and
deterministic defaults.

Accepted vector forms expose finite numeric `x`, `y`, and `z` fields. The broker immediately copies them into protocol-safe numeric tables.

Defaults and finite clamps:

| Field | Default | Range |
|---|---:|---:|
| `radius` | `12` | `0.25..512`; `0.10..512` for `filament` |
| `startRadius` | normalized `radius` | exact `0`, or the style's radius range |
| `endRadius` | normalized `radius` | exact `0`, or the style's radius range |
| `minPixelWidth` | `0` | `0..32`; positive values require `filament` |
| `outerColor` | `{0.08, 0.45, 1.0}` | each `0..4` |
| `coreColor` | `{0.75, 0.96, 1.0}` | each `0..4` |
| `coreRatio` | `0.24` | `0.02..1` |
| `intensity` | `1` | `0..8` |
| `opacity` | `1` | `0..1` |
| `baseColor` | `outerColor`, clamped | each `0..1` |
| `baseOpacity` | `0` | `0..1` |
| `startFadeLength` | `0` | `0..1,000,000` world units |
| `endFadeLength` | `0` | `0..1,000,000` world units |
| `depthSoftness` | `0` | `0..512` world units |
| `fogInfluence` | `0` | `0..1` |
| `style` | `smooth` | built-in style |
| `styleScale` | `0` | `0..512` |
| `seed` | deterministic | integer `0..15` |
| `longitudinal` | `{ mode = "solid", pathOffset = 0 }` | schema below |

Built-in styles are `smooth`, `electric`, `plasma`, `trail`, and `filament`.
Generic aliases remain available:

```text
beam/straight       -> smooth
lightning/jagged    -> electric
noisy               -> plasma
fading              -> trail
```

Consumers cannot supply GLSL, shader filenames, uniform names, packed metadata, or arbitrary style plugins.

`smooth`, `electric`, and `plasma` add the light from every overlapping
segment. `trail` and `filament` instead use a shared max-composition path and
have no intensity flicker. This avoids bright round-cap joints in connected
polylines. Because the join-safe path is shared, separate trail or filament
segments also do not become brighter where they cross. `filament` additionally
uses derivative-aware edge coverage for very thin lines.

### Radius, taper, and a filament pixel floor

`radius` remains a backward-compatible shorthand. BeamFX normalizes it first,
then uses it only as the fallback for an omitted `startRadius` or `endRadius`.
Supplying both endpoint fields makes the visible taper explicit.

Endpoint radius `0` is a special exact value for a pointed end. Any other
positive endpoint radius is clamped to `0.25..512`, or `0.10..512` for
`filament`. A segment with both endpoint radii at `0` is valid only when a
positive filament `minPixelWidth` keeps it visible.

`minPixelWidth` is the minimum full body width on screen, excluding halo. It is
an optional readability floor for `filament`, not a world-space thickness and
not a collision radius. A positive value on any other style is `invalid_spec`.

### Base material, spatial fades, depth, and fog

Emission and base material are independent:

- `outerColor`, `coreColor`, `intensity`, and `opacity` control emitted light.
- `baseColor` and `baseOpacity` blend one non-emissive material color for the
  nearest covered beam shell beneath that light.
- `intensity = 0` with positive `baseOpacity` produces a dark or non-emissive
  line, useful for fishing line, wire, or a stylized tether. It is still a
  screen-space visual, not a normally lit mesh.

Beam lifecycle and segment-relative fades apply to both the base and emitted
parts.

`startFadeLength` and `endFadeLength` are distances along the segment in world
units. They are spatial edge fades and are unrelated to time-based
`fadeDuration`.

`depthSoftness = 0` preserves the hard depth intersection. A positive value
softly reduces coverage as the beam approaches opaque scene depth over that
many world units. `fogInfluence = 0` preserves the legacy no-fog response;
values toward `1` increasingly apply the scene's current fog to the segment.

### Longitudinal patterns

`longitudinal` controls visibility along the segment. It is a drawing mask
only; it never changes hit detection. `nil`, `false`, or an omitted table means
solid. `true`, unknown modes, unknown fields, and fields belonging to a
different mode are `invalid_spec`.

All modes accept:

```lua
pathOffset = 0 -- -1,000,000..1,000,000 world units
```

For a manually constructed connected path, set each segment's offset to the
cumulative length of all earlier segments. `producer:upsertPath` and
multi-point `producer:emit` calculate these offsets automatically. For
`pulse` and `dash`, the effective repeated-pattern coordinate is:

```text
pathOffset + distanceAlongSegment
    - speed * (simulationTime - animationStartedAt)
```

For those repeated modes, positive speed moves the pattern from `startPos`
toward `endPos`; negative speed reverses it. `travel` follows the same public
direction convention but advances a single moving window; its connected-path
reverse behavior is described in the `travel` section below. `upsert` stamps
`animationStartedAt`. `replaceSegments`, `appendSegments`, `renew`, and
`finish` preserve that anchor and therefore preserve phase.

#### `solid`

```lua
longitudinal = {
    mode = "solid",
    pathOffset = 0,
}
```

The full segment is visible. `pathOffset` has no visible effect in this mode.

#### `travel`

```lua
longitudinal = {
    mode = "travel",
    pathOffset = 0,
    visibleLength = 30,
    speed = 120,
    headFadeLength = 4,
    tailFadeLength = 8,
    loop = true,
    loopLength = 100,
    loopDelay = 0.25,
}
```

This draws one moving window. `visibleLength` is required in
`0.01..1,000,000`; `speed` is required and nonzero in
`-1,000,000..1,000,000`. Head and tail fade lengths default to `0` and are
clamped to `0..visibleLength`. `loop` defaults to `false`.

When `loop = true`, `loopLength` defaults to the segment length and accepts
`0.01..1,000,000`; `loopDelay` defaults to `0` and accepts `0..3600` seconds.
Supplying either loop field while `loop` is false is invalid.

For one looping window across a connected path, every segment should receive
the same `loopLength` equal to the total path length and its own cumulative
`pathOffset`. Negative looping travel treats that length as the global path end
and visits segments in decreasing offset order. Non-loop negative travel has no
beam-level total-path value to infer from independent packets; use it for one
segment, or reverse the producer's path ordering and offset convention.

#### `pulse`

```lua
longitudinal = {
    mode = "pulse",
    pathOffset = 0,
    period = 40,
    pulseLength = 12,
    speed = 80,
    carrierLevel = 0.20,
    fadeLength = 2,
}
```

This repeats brighter pulses over a continuous carrier. `period` is required
in `0.01..1,000,000`; `pulseLength` is required in `0.01..period`; `speed`
defaults to `0` and accepts `-1,000,000..1,000,000`; `carrierLevel` defaults to
`0.25` and accepts `0..1`; `fadeLength` defaults to `0` and is clamped to
`0..pulseLength / 2`. The base material remains continuous.

#### `dash`

```lua
longitudinal = {
    mode = "dash",
    pathOffset = 0,
    dashLength = 18,
    gapLength = 10,
    speed = 0,
    fadeLength = 1,
}
```

This repeats fully visible dashes separated by gaps. `dashLength` is required
in `0.01..1,000,000`; `gapLength` is required in `0..1,000,000`; `speed`
defaults to `0` and accepts `-1,000,000..1,000,000`; `fadeLength` defaults to
`0` and is clamped to `0..dashLength / 2`. The mask applies to both emission
and base material.

### Plasma origin glow and seeds

- `originGlow = true` is valid only for plasma and forces effective seed 0.
- A conflicting explicit nonzero seed is `invalid_spec`.
- Ordinary plasma requires effective seed `1..15`.
- Omitted ordinary-plasma seed is derived deterministically from full beam identity plus internal segment serial.
- Explicit plasma seed 0 without `originGlow = true` is rejected.
- `originGlow = true` on a non-plasma style is rejected.
- Non-plasma seed 0 is valid.
- Omitted non-plasma seeds are deterministically derived in `0..15`.

The explicit flag preserves the extracted plasma shared-origin presentation.
Shader ABI 3 preserves legacy style identifiers while extending the private
renderer-owned uniform layout for the canonical segment features introduced
before API 1.3. API 1.3's authoring conveniences expand before the private
protocol and therefore do not change Shader ABI 3.

### Segment-relative timing

Segment `duration` includes its fade interval and is independent of the
enclosing beam lifetime. If duration is present and fade is omitted, the
default fade is `min(0.14, duration)`. A supplied fade is clamped down to the
segment duration. Supplying a segment fade without either a segment or
operation-default duration is invalid.

```text
createdAt   = broker simulation time
fadeStartAt = createdAt + max(0, duration - fadeDuration)
expiresAt   = createdAt + duration
```

Omitted duration keeps the segment until replacement, rolling eviction, beam finish/remove, release, or reset. Operation options may supply duration/fade defaults; explicit per-segment values win.

## Atomic mutation rules

Every geometry call is all-or-nothing:

- One malformed segment rejects the full operation.
- Empty required geometry returns `no_valid_segments`.
- A batch larger than the normalized beam `maxSegments` rejects.
- A table larger than the hard input maximum of 256 rejects before deep traversal.
- Append accepts every valid submitted segment and evicts only older retained history.
- If accepting the full batch would exceed producer/global quotas, the full operation rejects.
- Failed replacement retains the previous valid beam and revision.
- Caller-owned tables are never retained.

Clamping a finite visual value is a documented normalization, not partial acceptance.

## Space identity

`I.BeamFX.spaceKeyForCell(cell)` is a global-context-only immediate
normalization helper. The `cell` field accepted by `emit` and `upsertPath`
calls this same normalization during the facade call:

```text
verified exterior + nonempty worldSpaceId -> exterior:<opaque worldspace ID>
verified exterior + no worldSpaceId       -> exterior:<opaque cell ID> fallback
verified interior + nonempty cell.id      -> interior:<opaque cell ID>
otherwise                                 -> nil, invalid_space_key
```

Case is preserved. BeamFX never fabricates `"nil"` or a default worldspace sentinel. `sys::default`, when returned by the engine, is treated as an opaque legitimate ID rather than synthesized.

OpenMW 0.51 source shows that TES3 exterior `Cell.id` may encode grid coordinates even though the generated API prose describes it as worldspace-based. Supported TES3 cells expose `worldSpaceId`; the `cell.id` branch is therefore a fail-closed compatibility fallback with an explicit limitation: adjacent tiles are guaranteed to share a key only when the engine supplies the worldspace ID.

Never put a raw Cell in an event, render packet, or saved structure. BeamFX
does not retain one supplied to a convenience method. A consumer local/player
event sends primitives or a supported object reference; its own global
adapter obtains the authoritative Cell and calls the helper or passes the Cell
directly to `emit`/`upsertPath` while still in global context.

The player renderer independently normalizes its own current Cell every rendered frame. Nil/unresolved or wrong-space state renders zero BeamFX segments.

## Quotas and shared capacity

| Quota | Value |
|---|---:|
| Producer ID bytes | 96 |
| Producer display-name bytes | 128 |
| Local beam ID bytes | 128 |
| Provider epoch bytes | 192 |
| Renderer-session bytes | 192 |
| Space-key bytes | 256 |
| Diagnostic-reason bytes | 128 |
| Absolute coordinate magnitude | 1,000,000,000,000 |
| Registered producers | 128 |
| Active beams per producer | 128 |
| Active beams globally | 1,024 |
| Retained segments per producer | 2,048 |
| Retained segments globally | 16,384 |
| Default segments per beam | 24 |
| Hard segments per beam | 256 |
| Input segment table | 256 |
| Renderer tombstones per viewer/sync generation | 1,024 |
| Physical rendered segments | 64 |
| Physical appearance/feature profiles | 16 |

The logical registry may accept more than the 64 physical slots. Losing a per-frame render competition never deletes accepted state.

Physical selection is producer-fair. For `P` eligible producers:

```text
serviceWindowFrames(P) = ceil(P / 64)
```

Every eligible producer receives one segment before any producer receives a
second fairness quantum in that service cycle. With the 128-producer
registry maximum, the exact bound is two frames.
`temporaryBridgeProducerGroups` is reserved and reports zero in this release.
Priority ranks effects within one producer and cannot starve another
producer.

Profiles are built after segment selection. More than 16 compatible
appearance/feature combinations use deterministic nearest-profile
approximation and recover when pressure drops. Approximation never changes the
longitudinal mode or turns taper, either spatial-fade side, reverse travel,
base material, pixel floor, depth softness, or fog response on or off. If more
than 16 incompatible feature classes are selected simultaneously, excess
incompatible segments fail closed visually; accepted gameplay-independent
state remains retained.

## Provider reset and reconstruction

BeamFX state is intentionally ephemeral. On load, new game, or provider reset:

1. The provider adopts a fresh opaque epoch.
2. Old facades become stale.
3. Renderer state is reset through the private versioned protocol.
4. Consumers observe the epoch change, register a fresh producer generation, and republish still-authoritative visuals.

BeamFX does not save another mod's gameplay state.

## Stable errors

API major 1 uses the following stable second-return codes:

```text
unsupported_api
duplicate_provider
invalid_producer_id
producer_id_in_use
invalid_producer_handle
stale_producer
invalid_beam_id
beam_not_found
beam_finishing
invalid_space_key
invalid_spec
no_valid_segments
invalid_style
invalid_priority
invalid_lifecycle
producer_quota_exceeded
segment_quota_exceeded
lease_not_enabled
provider_reset
```

API 1.3 may add a third `{ path, reason, message }` value without changing
these codes. Detail `reason` values are more specific diagnostics, such as
`unknown_preset`, `requires_filament`, or `missing_endpoint`; they do not
replace the stable error code and may be absent where no useful input path
exists.

`provider_unavailable` is a consumer-side status when `I.BeamFX` does not exist. `renderer_unavailable` is private per-viewer health only; broker mutations remain valid even with no working renderer.
