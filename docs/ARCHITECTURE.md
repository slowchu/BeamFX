# BeamFX architecture

BeamFX is a visual framework. It accepts neutral beam geometry from independent global-script producers, routes it to eligible players, and composites selected segments through one player-owned OMWFX shader. It owns no collision, raycasting, damage, projectile cancellation, carrier object, spell record, sound, mesh, or saved gameplay authority.

Mod authors looking for practical integration steps should start with
[`USAGE.md`](USAGE.md). Exact public contracts are in [`API.md`](API.md).

```text
consumer global adapters
          |
          | producer-bound I.BeamFX facade
          v
one BeamFX global broker
  - ownership and validation
  - lifecycle and bounded geometry
  - space/audience routing
  - coalescing and reconciliation
          |
          | private protocol v1
          v
one BeamFX player renderer
  - epoch/generation/revision reducer
  - current-space rejection
  - fair 64-slot selection
  - 16-palette approximation
          |
          v
one beamfx_core compositor
```

Each consumer is an ordinary public producer. Its own global adapter acquires
the interface, derives authoritative space, converts its gameplay state into
neutral segments, and reconstructs visuals after a provider reset. BeamFX
contains no consumer-specific gameplay adapter, private producer route, or
consumer-selectable render event.

## Context boundaries

The manifest contains:

```text
GLOBAL: scripts/beamfx/global/init.lua
PLAYER: scripts/beamfx/player/init.lua
```

The global context owns the public interface, broker, producers, authoritative visual timestamps, routing, and private packet emission. The player context alone imports `openmw.postprocessing`, loads `beamfx_core`, owns the shader, and uploads uniforms.

Shared modules are pure/context-neutral. Cross-context packets contain only strings, booleans, finite numbers, numeric tables, and arrays. A player GameObject is allowed only in the private ready/resync handshake so global code can identify the sender. No Cell, closure, producer facade, shader handle, or arbitrary userdata enters a render packet.

The global `capabilities()` snapshot is static discovery, not runtime health. Its top-level version and capacity fields are accompanied by `producerApiShape`, the `features` flags (`globalProvider`, `globalDiagnostics`, `playerPostprocessing`, `perViewerRouting`, and `targetedReconciliation`), the named public `quotas`, and `fairness` (`capacity`, public and overall service windows, the zero-valued compatibility bridge-group field, and formula). The complete returned key structure is specified in `docs/API.md`.

## Duplicate-copy singleton

OpenMW interface replacement does not unregister an older script's engine handlers, so the interface name is not sufficient. BeamFX owns two singleton interfaces:

```text
BeamFX          global provider
BeamFXRenderer  player renderer
```

Each instance begins `ownership_pending`. Module top level and `onInit` perform no broker, packet, renderer, postprocessing, shader, or uniform side effect.

`engineHandlers.onInterfaceOverride(baseInterface)` is one-way:

- A later compatible instance captures the prior interface and becomes permanently inert.
- Its visible public calls delegate through the captured compatible base.
- A third duplicate may delegate through the second and still resolves to the first.
- An incompatible base keeps the later instance inert and returns `duplicate_provider`.
- A compatible global base must match `apiMajor`, `apiMinor`, package `version`, `protocolVersion`, and `shaderAbi` exactly and expose the complete API 1.0 surface, including defensive diagnostics. A version mismatch never activates a second broker.
- An inert instance never promotes later, even if override callbacks recur or receive a different/nil base.
- Every inert update, event, load, reset, and frame handler immediately returns.
- The inert player never requires the renderer or `openmw.postprocessing`, loads/enables/disables a shader, uploads a uniform, or clears primary state.

The first instance promotes at its first deferred update/frame and initializes there.

### Exact-build timing evidence

Three isolated compatibility runs used OpenMW 0.51.0 revision `b850d13e58`:

1. Primary → duplicate → third.
2. Third → duplicate → primary.
3. The exact producer colon-method call shape.

In both load orders, later instances received `onInterfaceOverride` before their `onInit` and before any update/frame. Only the first player instance touched postprocessing. The third visible interface delegated to the first. The returned producer facade remained callable across updates, release, stale rejection, and generation-2 re-registration.

OpenMW source independently confirms synchronous interface insertion/override before initialization and later frame dispatch. The installed API prose only states that override can run before `onInit`, so the retained exact-build fixture remains part of the evidence.

## Producer ownership and identity

Every internal beam generation is identified by:

```text
(providerEpoch, producerId, producerGeneration, localBeamId, beamGeneration)
```

The composite render key is a length-prefixed encoding of all five members. Delimiters inside public IDs cannot make two tuples ambiguous.

- `providerEpoch` is a fresh opaque string per provider session/reset.
- `producerGeneration` comes from one session-wide monotonic safe-integer scalar. It changes on every successful registration, including reuse of a released public producer ID, without retaining per-ID tombstones.
- Producer-generation exhaustion fails registration closed until provider reset establishes a fresh epoch and resets the scalar.
- `beamGeneration` is monotonic for new generations owned by one producer registration.
- `revision` is monotonic within one live beam generation.
- The producer facade closes over its private registry state; callers do not submit an owner ID on every mutation.
- Returned facades are strict read-only when the engine utility is available. The wrapper is convenience, not authentication; ownership comes from the captured closure.

Two producers can use the same local ID. Remove, finish, renew, clear, and release can affect only the facade's owner.

## Diagnostic accounting

The public global `I.BeamFX.diagnostics()` method merges three defensive snapshots without mutating them:

1. Broker current state and session-cumulative mutation/segment/rejection/generation counters.
2. Registry registration, boundary-rejection, stale-facade, and release counters.
3. Viewer-routing current counts.

The broker accounts successful geometry only after complete validation and commit, so rejected atomic batches never inflate `acceptedSegments`. Handler failures increment the owning producer and aggregate invalid counters. Registry failures that occur before the broker—invalid registration, duplicate ID, registry quota, stale facade, or a contained callback/result failure—increment separate boundary counters and the aggregate invalid total.

Per-producer entries cover all live registrations, including zero-state facades that have not yet allocated a broker record. The merged list is deterministic: normalized producer ID followed by producer generation. Release removes that producer from the live list while aggregate session counters remain until provider reset. Reset replaces the epoch and clears every diagnostic counter with the rest of BeamFX's ephemeral state.

This global surface describes authoritative provider state and aggregate viewer routing only. It does not claim that any particular player loaded or enabled a shader, nor does renderer failure invalidate broker work.

Each player exposes a separate local `I.BeamFXRenderer.status()` snapshot. Its ownership/load fields are `role`, `compatibleBase`, `rendererLoaded`, `rendererLoadFailed`, `rendererSession`, `readySerial`, and optional duplicate `error`. Protocol health is represented by `providerEpoch`, `providerEpochConfirmed`, `viewerSyncGeneration`, `tombstoneCount`, `blockedSyncGeneration`, `resyncRequested`, and `retiredProviderEpochs`.

After the deferred renderer load, the same local snapshot includes retained public-producer state (`retainedBeams`, `retainedSegments`), frame selection (`eligibleSegments`, `renderedSegments`, `culledBySpace`, `culledByCapacity`), palette pressure (`paletteCount`, `paletteOverflow`), and renderer/shader health (`rendererAvailable`, `shaderLoaded`, `shaderEnabled`, `uploadHealthy`). These values belong only to that viewer. They are never aggregated into producer success/failure and never cross the private protocol.

## Lifecycle and geometry

All framework time uses `core.getSimulationTime()`. Pausing consumes no transient duration, segment duration, finish fade, or lease.

Transient beams store absolute broker-stamped `createdAt`, `fadeStartAt`, and `expiresAt`. Natural expiry is visually exact. The broker retains a non-rendering pending generation for one provider update so an owner `finish` at the exact boundary can supersede natural removal regardless of global handler order.

Persistent beams have no natural expiry. An optional lease is only orphan protection for the visual. BeamFX never interprets it as gameplay expiry.

Every beam has finite `maxSegments`. Append accepts a valid batch in full, then evicts only older retained history. Per-beam, per-producer, and global counts are updated atomically.

BeamFX state is ephemeral. Load/new game/provider reset changes the epoch and clears visual state. Consumers reacquire their facade and reconstruct still-authoritative visuals.

## Space and audience

Public v1 supports only:

```lua
audience = { mode = "same_space" }
```

The global broker derives each viewer's current key independently from `player.cell`; a player-sent key is diagnostic only. Viewer records are keyed by the stable documented `player.id`, not by a deserialized GameObject wrapper.

The canonical space form is:

```text
exterior:<opaque engine worldspace ID>
interior:<opaque engine cell ID>
```

For exteriors, an engine-provided nonempty `worldSpaceId` wins. The authoritative compatibility fallback uses an engine-provided nonempty `cell.id`; no value such as `sys::default` is fabricated from nil. Case is preserved.

OpenMW 0.51 source reveals a documentation mismatch: TES3 exterior `Cell.id` is grid-based, while normal TES3 cells expose the real worldspace as `worldSpaceId = "sys::default"`. The fallback is retained for specification compatibility but does not promise adjacent-tile continuity if a future/abnormal Cell omits worldspace identity.

The player renderer recomputes its own key every frame. Nil/unresolved or wrong-space state yields zero selected BeamFX segments, even if an event was delayed across teleport.

## Viewer sessions and reconciliation

Player readiness is not inferred from `onPlayerAdded`; `reloadlua` rebuilds scripts without that callback. A primary renderer creates a fresh runtime `rendererSession` and sends a ready handshake:

- on its first primary frame;
- whenever normalized space changes, including transition to nil;
- when it needs resynchronization.

The handshake carries `self.object`, the renderer session, a ready serial, and an optional observed space hint. The global broker reacquires and validates the player, derives current space itself, allocates a new `viewerSyncGeneration`, sends a targeted reconciliation reset, then sends deterministic authoritative snapshots for every eligible live beam.

Private packets echo:

```text
providerEpoch
rendererSession
viewerSyncGeneration
```

This tuple rejects delayed packets from a prior reload, provider reset, or viewer reconciliation. Per viewer, the broker tracks the exact full generations it actually delivered. Removal targets that set, not only newly eligible viewers.

## Private render protocol 1

The event names are:

```text
BeamFX_Internal_RenderSnapshot_v1
BeamFX_Internal_RenderRemove_v1
BeamFX_Internal_ProviderReset_v1
BeamFX_Internal_ViewerReconcileReset_v1
BeamFX_Internal_ViewerReady_v1
BeamFX_Internal_ViewerResync_v1
```

Provider reset, targeted viewer reset, and beam remove have distinct schemas and semantics.

Snapshots contain full identity, revision, space, priority, lifecycle timestamps, and copied normalized segments. Removes contain full terminal identity and `terminalRevision`.

The renderer:

- requires exact source/protocol/epoch/session/sync;
- ignores stale producer/beam generations and revisions;
- accepts remove-before-snapshot by creating a terminal tombstone;
- never lets a delayed snapshot resurrect a tombstoned generation;
- never lets an old-generation remove affect a reused public ID;
- treats duplicate resets idempotently.

Tombstones remain until provider or targeted reconciliation reset. At 1,024 tombstones, the provider advances the viewer sync and sends a targeted reset before unsafe eviction. A defensive renderer overflow blocks the old sync, drops its local visual state, sends one resync request, and accepts packets again only after a newer reconciliation generation.

## Coalescing

Broker mutations mark state dirty. One provider update emits at most one latest full snapshot per dirty beam/viewer.

Precedence within one identity/sync cycle:

```text
provider or reconciliation reset
explicit remove/release
terminal finish snapshot
ordinary upsert/replace/append snapshot
```

Append followed by remove emits no stale snapshot. Remove followed by deliberate upsert may emit an old-generation remove and a new-generation snapshot because the identities differ. Reliable full snapshots are used in protocol 1; there are no public deltas.

## Capacity and fairness

Logical quotas:

| Resource | Limit |
|---|---:|
| Producer ID bytes | 96 |
| Producer display-name bytes | 128 |
| Local beam ID bytes | 128 |
| Provider epoch / renderer-session bytes | 192 |
| Space-key bytes | 256 |
| Diagnostic-reason bytes | 128 |
| Absolute coordinate magnitude | 1,000,000,000,000 |
| Producers | 128 |
| Active beams per producer | 128 |
| Active beams global | 1,024 |
| Retained segments per producer | 2,048 |
| Retained segments global | 16,384 |
| Segments per beam | 256 |
| Input segment table | 256 |
| Tombstones per viewer/sync | 1,024 |

Physical shader limits remain 64 segments and 16 palettes.

After expiry, transparency, and space rejection, candidates are grouped by full producer identity. Within each producer they are ranked by priority, viewport relevance, camera distance, freshness, composite key, and segment order.

A stateful service-cycle round robin grants one segment to each eligible producer before any producer receives a second fairness quantum:

```text
serviceWindowFrames(P) = ceil(P / 64)
```

At `P=65`, frame one serves 64 distinct producers; frame two first serves the
remaining producer, then redistributes unused capacity. At the
128-producer registry maximum, the exact bound is two frames. The reserved
`temporaryBridgeProducerGroups` capability field is zero in this release.
Priority never crosses producer ownership and cannot starve another producer.

After membership selection, the selected set uses the renderer's stable final
ordering. Palettes are built afterward. More than 16 appearances use
deterministic nearest-palette matching.

## Measurement checkpoint

A representative pure-Lua allocation measured broker state plus a full one-viewer renderer copy:

| Logical segments | Beams | Tombstones | Total table increment |
|---:|---:|---:|---:|
| 16,384 | 1,024 | 1,024 | 33,069.8 KiB |
| 32,768 | 2,048 | 2,048 | 66,097.8 KiB |
| 65,536 | 4,096 | 4,096 | 132,153.8 KiB |

The selected 16,384 ceiling is deliberately conservative relative to the 64-slot compositor. Measurements estimate Lua tables, not total OpenMW process RSS, and quota changes remain documented compatibility changes.

## Failure isolation

Shader load, enable/disable, and uniform uploads are guarded and use retry backoff. Idle state sets segment count to zero when possible, disables the BeamFX shader, and performs no steady upload.

A missing or broken renderer does not reject broker mutations. Accepted visual state remains available for later reconciliation. Diagnostics are rate-limited, and one producer's malformed request cannot corrupt another.

Provider reset clears only BeamFX state. It never touches other postprocessors or any gameplay object.

## Stable shader boundary

Shader ABI 1 keeps:

```text
bfxSegmentCount
bfxSegmentStartRadius[64]
bfxSegmentEndMetadata[64]
bfxPaletteOuterCore[16]
bfxPaletteCoreGeometry[16]
```

Shader ABI 1 fixes the `omw.simulationTime` animation contract, depth
reconstruction, additive composition, plasma origin presentation, metadata
packing, palette quantization, and closest-palette behavior. Consumers cannot
inject GLSL or obtain the shader handle.
