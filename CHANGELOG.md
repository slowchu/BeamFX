# Changelog

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

No later public package has been released.

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
