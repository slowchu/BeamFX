# BeamFX interactive visual gallery

This is an **optional developer data root**, not part of the normal BeamFX
runtime. It is a public-API-only reference consumer for BeamFX API 1.3.

Load this directory as a data root after BeamFX, then enable:

```text
beamfx.omwscripts
beamfx_visual_gallery.omwscripts
```

OpenMW's profile-wide **Post Processing** setting must be enabled.

The gallery opens automatically and places a connected preview path in front
of the player. If scenery blocks it, use **Reposition** in the panel or press
the configurable reposition binding (F7 by default). The configurable F8
binding closes and clears the gallery or opens it again. Both bindings appear
under **Options > Scripts > BeamFX Visual Gallery**.

## Controls

- Select a property with the upper `<` and `>` controls.
- Change its value with the lower `-` and `+` controls.
- Cycle presets, styles, radius, intensity, both spatial fades, taper,
  longitudinal modes, and filament minimum pixel width.
- Setting a positive pixel width automatically selects `filament`; selecting
  another style clears the filament-only width.
- **Pause** freezes pulse and dash motion. Travel uses the smallest accepted
  nonzero speed while paused because API 1.3 deliberately rejects a
  zero-speed traveling window.
- **Reset** restores the initial frost recipe and animation phase.
- **Show expanded** switches from concise public input to the deterministic
  canonical appearance represented by the documented preset values.
- **Print** writes both copy-ready forms to `openmw.log`.
- **Close + clear** removes all visuals owned by the gallery producer.

The UI shows structured validation details from BeamFX, including the failing
field path and stable reason when the provider supplies them.

## Script ownership

The player script owns ordinary input and UI. It sends only serializable
commands, primitive configuration values, and the supported player object
reference to its global adapter. The global script:

- confirms the sender is a player;
- reads the authoritative player position, facing, and Cell;
- immediately converts the Cell to a BeamFX space key;
- owns the producer facade and preview geometry;
- notices provider-epoch and Cell changes;
- republishes through `producer:upsertPath`;
- clears its producer on close, load, or new game.

No BeamFX implementation module, private render event, shader uniform, LuaLS
stub, or Cod3x feature is used.

## Scope

The preview is a visual design aid. It performs no raycast, collision, damage,
or targeting. `upsertPath` draws connected straight segments through the
chosen points; it does not create mathematically curved geometry.
