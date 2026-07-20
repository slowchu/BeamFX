# Changelog

## 0.1.0-alpha.4 — friendly authoring API

### For mod authors

- Added public API `1.3` without changing private protocol `3` or Shader ABI
  `3`.
- Added `producer:emit(spec)` for one-shot effects. It accepts `cell` or
  `spaceKey`, `from`/`to` or a `points` path, generates an opaque
  collision-safe beam ID, and supplies a `0.25`-second transient lifecycle
  with a `0.10`-second fade by default.
- Added `producer:upsertPath(localBeamId, spec)` for persistent or explicitly
  timed connected paths. It builds each segment and computes cumulative
  longitudinal `pathOffset` values automatically.
- Added the `frost`, `fire`, `lightning`, `laser`, `fishing_line`, and
  `energy_blade` appearance presets. Presets expand to existing segment
  controls and may be overridden field by field; they do not add shader
  styles.
- Added a convenient `color = { r, g, b }` input that derives matching outer,
  core, and base colors. Explicit `outerColor`, `coreColor`, and `baseColor`
  retain final precedence.
- Added beam-level `segmentDefaults` for full `upsert` calls. Individual
  segment values override the shared defaults.
- Added an optional third error return containing `path`, stable `reason`, and
  a readable `message`. Existing consumers that read only `result, err`
  remain compatible.
- Added a copyable ordinary-Lua consumer adapter with lazy registration,
  epoch recovery, bounded retries, rate-limited warnings, reconstruction,
  cleanup, and an API 1.2 fallback for one-shot emission.
- Added an optional interactive visual gallery that previews styles, presets,
  radius, intensity, fades, taper, longitudinal modes, and filament pixel
  width while showing or printing the corresponding Lua values.
- The visual gallery now claims interactive UI focus without pausing its
  preview, supports a draggable on-screen-clamped header, adapts to resolution
  and GUI-scale changes, and keeps wrapped recipe output inside a bounded
  read-only field. F7 repositions the preview even while the panel is hidden.
  F8, Escape, and Hide release the panel and cursor without clearing or
  resetting the world preview; a separate Clear/Preview control owns that
  lifecycle.

### Framework behavior

- All friendly authoring inputs expand at the producer-facade boundary.
  Broker storage, private packets, the renderer, and the shader continue to
  receive only the same canonical API 1.2 segment representation.
- A raw Cell accepted by a convenience call is converted immediately and is
  never retained in broker state or sent through the render protocol.
- The producer facade now exposes eleven bound methods: the original nine plus
  `emit` and `upsertPath`.

### Version tracks

| Track | Version |
|---|---|
| Package | `0.1.0-alpha.4` |
| Public API | `1.3` |
| Private render protocol | `3` |
| Shader ABI | `3` |

## 0.1.0-alpha.3 — expressive segment controls

### For mod authors

- Added public API `1.2`.
- Added independent `startRadius` and `endRadius` taper while retaining
  `radius` as a backward-compatible fallback; exact zero is available for a
  pointed endpoint.
- Lowered the `filament` world-radius minimum to `0.10` and added an optional
  filament-only `minPixelWidth` screen-space readability floor.
- Added `baseColor` and `baseOpacity` for dark or non-emissive visual lines
  beneath the existing glow.
- Added world-unit `startFadeLength` and `endFadeLength`, soft opaque-depth
  intersection through `depthSoftness`, and adjustable scene fog response
  through `fogInfluence`.
- Added `solid`, `travel`, `pulse`, and `dash` longitudinal modes, including
  cumulative `pathOffset` support for continuous patterns across connected
  segments.
- Defined animation-anchor behavior: `upsert` restarts longitudinal animation;
  `replaceSegments`, `appendSegments`, `renew`, and `finish` preserve its phase.
- Expanded the usage guide with copy-paste recipes for taper, fine filaments,
  dark fishing line or wire, endpoint fades, soft depth, fog, and connected
  patterns.
- Reaffirmed that every feature is visual only. Producer Lua remains
  responsible for raycasts, hit tests, targeting, and damage.

### Framework behavior

- Advanced the private render protocol and event namespace to version `3`.
- Added broker-stamped `animationStartedAt` to canonical full snapshots.
- Advanced the shader ABI to `3` and versioned its resource as
  `beamfx_core_v3`.
- Added the ABI 3 feature-state, base/shape, and longitudinal uniform arrays
  while retaining the 64-segment and 16-profile physical limits.
- Expanded the 16 profiles from appearance-only palettes to combined
  appearance/feature profiles. Compatible overflow remains deterministic;
  approximation never changes a discrete longitudinal mode or opt-in feature
  class.
- Kept ribbons, swept surfaces, and motion-history geometry outside the BeamFX
  segment compositor. They remain candidates for a separate future renderer.

### Version tracks

| Track | Version |
|---|---|
| Package | `0.1.0-alpha.3` |
| Public API | `1.2` |
| Private render protocol | `3` |
| Shader ABI | `3` |

## 0.1.0-alpha.2 — join-safe connected lines

### For mod authors

- Added public API `1.1` and the built-in `filament` style for thin connected
  curves, tethers, lines, and threads.
- Made `filament` and `trail` steady rather than independently flickering.
- Made overlapping `filament` and `trail` segments use max composition,
  preventing additive bright dots at connected round-cap joints.
- Added derivative-aware outer coverage and a radius-aware core AA floor for
  thin filament lines.
- Documented controlled curves as connected straight segments and disclosed
  the shared non-additive crossing behavior.

### Framework behavior

- Advanced the private render protocol and event namespace to version `2`.
- Advanced the shader ABI to `2` and versioned its resource as
  `beamfx_core_v2`.
- Preserved every positive Shader ABI 1 packed metadata value and full
  eight-bit opacity precision by encoding extended style IDs in the negative
  exact-integer range.
- Kept `smooth`, `electric`, and `plasma` composition additive.

### Version tracks

| Track | Version |
|---|---|
| Package | `0.1.0-alpha.2` |
| Public API | `1.1` |
| Private render protocol | `2` |
| Shader ABI | `2` |

## 0.1.0-alpha.1 — initial alpha release

This version is prepared, locally verified, and released under the MIT
License.

### For mod authors

- Added the public global-script interface `I.BeamFX`, API `1.0`.
- Added producer registration through a bound nine-method facade:
  `upsert`, `replaceSegments`, `appendSegments`, `renew`, `finish`, `remove`,
  `clear`, `release`, and `stats`.
- Added transient and truly persistent visual lifecycles.
- Added optional visual-only leases and bounded rolling geometry.
- Added the built-in `smooth`, `electric`, `plasma`, and `trail` styles.
- Added atomic schema validation with stable error codes.
- Added canonical space keys and same-space viewer routing.
- Added provider epochs, producer and beam generations, revisions, stale
  facade rejection, and explicit reconstruction after reset.
- Added public capability and diagnostic snapshots.
- Added a task-oriented usage guide and a complete API reference.

### Framework behavior

- Added one shared global broker, one player renderer, and one depth-aware
  postprocessing compositor.
- Added deterministic producer-fair scheduling for the 64 physical segment
  slots.
- Added deterministic nearest-appearance approximation when more than
  16 palettes compete.
- Added same-frame mutation coalescing and latest-revision delivery.
- Added targeted viewer synchronization and bounded renderer tombstones.
- Added duplicate-provider and duplicate-renderer singleton protection using
  `onInterfaceOverride`; compatible duplicates remain inert.
- Added bounded quotas for producer IDs, registrations, beams, retained
  geometry, packet history, and renderer state.
- Added fail-open visual behavior: a missing provider or renderer does not
  own or interrupt producer gameplay.

### Version tracks

| Track | Version |
|---|---|
| Package | `0.1.0-alpha.1` |
| Public API | `1.0` |
| Private render protocol | `1` |
| Shader ABI | `1` |

### Known alpha limitations

- Only the `same_space` audience mode is public in API 1.
- Physical output is limited to 64 segments and 16 palettes per frame.
- BeamFX state is intentionally ephemeral; producer mods must reconstruct
  authoritative persistent visuals after load, new game, or provider reset.
- Postprocessing availability is controlled by the local OpenMW
  installation and configuration.

### License

- Released under the MIT License.
- Copyright (c) 2026 slowchu.
