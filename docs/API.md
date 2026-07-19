# BeamFX public API 1.0

BeamFX `0.1.0-alpha.1` exposes one global OpenMW interface:

```lua
local I = require("openmw.interfaces")
local BeamFX = I.BeamFX
```

The interface is available only between global scripts. A player, local, or custom consumer sends a namespaced serializable event to its own global adapter; that adapter validates gameplay state and calls BeamFX. BeamFX's private render events are not a public producer API.

For a tutorial and copy-paste recipes, start with
[`USAGE.md`](USAGE.md). This document is the exact API contract.

## Independent versions

| Track | Value |
|---|---|
| Package | `0.1.0-alpha.1` |
| Public API major/minor | `1.0` |
| Private render protocol | `1` |
| Shader ABI | `1` |
| Producer API shape | `facade` |

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
    apiMinor = 0,
    version = "0.1.0-alpha.1",
    protocolVersion = 1,
    shaderAbi = 1,
    producerApiShape = "facade",
    styles = { string, ... },
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

`producerApiShape` identifies the bound nine-method producer facade documented
below. `features` declares implemented framework surfaces, `quotas` names
every advertised input/state bound, and `fairness` describes the shared
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
    apiMinor = 0,
    version = "0.1.0-alpha.1",
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
- `acceptedSegments` sums complete successful `upsert`, `replaceSegments`, and `appendSegments` batches. Rejected and partial batches contribute zero.
- `invalidRequests` is the sum of broker-operation rejections and registry-boundary rejections. Boundary rejections include malformed/duplicate/quota registration attempts, stale facade calls, and contained callback/result failures.
- `createdBeamGenerations` counts successful `upsert` calls that created a generation.
- `removedBeamGenerations` includes explicit remove/clear/release, superseding upsert, natural/lease/finish expiry, and other broker removals within the current provider epoch.
- `brokerProducerStates` may be smaller than `registeredProducers` because a newly registered facade does not allocate broker state until its first broker call.

These are provider-global broker, registry, and routing diagnostics. The `viewers`, `readyViewers`, `deliveredBeams`, and `rendererTombstones` values summarize global per-viewer routing state; they do not report what any one player's shader rendered.

## Player-local renderer status

The player-context singleton is diagnostic infrastructure for the local renderer, not a producer API:

```lua
local Renderer = I.BeamFXRenderer

Renderer.version         -- "0.1.0-alpha.1"
Renderer.protocolVersion -- 1
Renderer.shaderAbi       -- 1
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

Renderer/protocol fields marked `nil` are absent until the deferred first player frame successfully loads the renderer. `retainedBeams` and `retainedSegments` count copied local public-producer render state. `eligibleSegments` is the current-space, live, positive-opacity set before the 64-slot scheduler; `renderedSegments` is the selected/uploaded count. `culledBySpace` counts retained segments rejected by the independent player-space check, while `culledByCapacity` is eligible minus selected. `paletteCount` is the uploaded palette count and `paletteOverflow` reports deterministic appearance approximation beyond 16 palettes.

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

Every method returns `result, nil` on success or `nil, "stable_error_code"` on failure.

### `producer:upsert(localBeamId, spec)`

Atomically creates or replaces the complete beam specification and geometry. It starts or restarts the lifecycle. Upserting an active generation increments its revision; upserting a removed or finishing local ID creates a new `beamGeneration`.

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

### `producer:replaceSegments(localBeamId, segments, options)`

Atomically replaces only geometry and segment-relative timing. It preserves the enclosing beam lifecycle and never extends transient beam expiry. Per-segment timing fields take precedence over operation defaults.

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

Atomically appends a complete batch through the rolling history policy. A batch larger than the beam's `maxSegments` is rejected. A valid batch is accepted in full; only older retained history may be evicted.

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

Cancels transient or lease timing and starts one terminal hold/fade schedule at broker simulation time.

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
    segments = { ... },
}
```

`lifecycle` is required. `audience` defaults to `{ mode = "same_space" }`;
this is the only public v1 audience mode. `priority` defaults to `normal`;
priority strings are normalized to lowercase. `maxSegments` defaults to 24,
is floored, and is clamped to `1..256`. Unknown beam, lifecycle, audience,
segment, operation-option, and finish-option fields are rejected.

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

    radius = 5.5,
    outerColor = { 0.08, 0.45, 1.0 },
    coreColor = { 0.75, 0.96, 1.0 },
    coreRatio = 0.28,
    intensity = 1.45,
    opacity = 1.0,
    style = "electric",
    styleScale = 14,
    seed = 3,
    originGlow = false,

    duration = 0.25,
    fadeDuration = 0.14,
}
```

Public v1 segments have no caller-defined ID. Supplying `segment.id` returns `invalid_spec`. The broker assigns a monotonically increasing internal serial within the beam generation for identity, ordering, and deterministic defaults.

Accepted vector forms expose finite numeric `x`, `y`, and `z` fields. The broker immediately copies them into protocol-safe numeric tables.

Defaults and finite clamps:

| Field | Default | Range |
|---|---:|---:|
| `radius` | `12` | `0.25..512` |
| `outerColor` | `{0.08, 0.45, 1.0}` | each `0..4` |
| `coreColor` | `{0.75, 0.96, 1.0}` | each `0..4` |
| `coreRatio` | `0.24` | `0.02..1` |
| `intensity` | `1` | `0..8` |
| `opacity` | `1` | `0..1` |
| `style` | `smooth` | built-in style |
| `styleScale` | `0` | `0..512` |
| `seed` | deterministic | integer `0..15` |

Built-in styles are `smooth`, `electric`, `plasma`, and `trail`. Generic aliases remain available:

```text
beam/straight       -> smooth
lightning/jagged    -> electric
noisy               -> plasma
fading              -> trail
```

Consumers cannot supply GLSL, shader filenames, uniform names, packed metadata, or arbitrary style plugins.

### Plasma origin glow and seeds

- `originGlow = true` is valid only for plasma and forces effective seed 0.
- A conflicting explicit nonzero seed is `invalid_spec`.
- Ordinary plasma requires effective seed `1..15`.
- Omitted ordinary-plasma seed is derived deterministically from full beam identity plus internal segment serial.
- Explicit plasma seed 0 without `originGlow = true` is rejected.
- `originGlow = true` on a non-plasma style is rejected.
- Non-plasma seed 0 is valid.
- Omitted non-plasma seeds are deterministically derived in `0..15`.

The explicit flag preserves the extracted plasma shared-origin presentation while keeping packed shader ABI 1 unchanged.

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

`I.BeamFX.spaceKeyForCell(cell)` is a global-context-only immediate normalization helper:

```text
verified exterior + nonempty worldSpaceId -> exterior:<opaque worldspace ID>
verified exterior + no worldSpaceId       -> exterior:<opaque cell ID> fallback
verified interior + nonempty cell.id      -> interior:<opaque cell ID>
otherwise                                 -> nil, invalid_space_key
```

Case is preserved. BeamFX never fabricates `"nil"` or a default worldspace sentinel. `sys::default`, when returned by the engine, is treated as an opaque legitimate ID rather than synthesized.

OpenMW 0.51 source shows that TES3 exterior `Cell.id` may encode grid coordinates even though the generated API prose describes it as worldspace-based. Supported TES3 cells expose `worldSpaceId`; the `cell.id` branch is therefore a fail-closed compatibility fallback with an explicit limitation: adjacent tiles are guaranteed to share a key only when the engine supplies the worldspace ID.

Never put a raw Cell in an event, render packet, or saved structure. A consumer local/player event sends primitives or a supported object reference; its own global adapter obtains the authoritative Cell and calls the helper.

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
| Physical rendered palettes | 16 |

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

Palettes are built after segment selection. More than 16 appearances use the deterministic nearest-palette approximation from the parity-proven renderer and recover when pressure drops.

## Provider reset and reconstruction

BeamFX state is intentionally ephemeral. On load, new game, or provider reset:

1. The provider adopts a fresh opaque epoch.
2. Old facades become stale.
3. Renderer state is reset through the private versioned protocol.
4. Consumers observe the epoch change, register a fresh producer generation, and republish still-authoritative visuals.

BeamFX does not save another mod's gameplay state.

## Stable errors

API major 1 uses:

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

`provider_unavailable` is a consumer-side status when `I.BeamFX` does not exist. `renderer_unavailable` is private per-viewer health only; broker mutations remain valid even with no working renderer.
