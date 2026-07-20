# BeamFX interactive visual gallery

This is an **optional developer data root**, not part of the normal BeamFX
runtime. It is a public-API-only reference consumer for BeamFX API 1.3.

Load this directory as a data root after BeamFX, then enable:

```text
beamfx.omwscripts
beamfx_visual_gallery.omwscripts
```

OpenMW's profile-wide **Post Processing** setting must be enabled.

The gallery opens automatically, immediately enters an interactive UI mode,
and places a connected preview path in front of the player. The cursor is
available without first opening the inventory or main menu, while the game
and animated preview remain unpaused. If scenery blocks the preview, use
**Reposition** in the panel or press the configurable reposition binding (F7
by default), including while the panel is hidden. The configurable F8 binding
hides or reopens the panel. **Escape** and the panel's **Hide** button also
hide it. Hiding releases the cursor and interactive UI mode but deliberately
leaves the world preview visible and animating; reopening preserves its
position, appearance values, and animation state. Both configurable bindings
appear under **Options > Scripts > BeamFX Visual Gallery**.

The panel sizes itself to the current UI viewport, including OpenMW GUI-scale
and resolution changes, and stays clamped on screen. Drag its header to move
it. The copy-ready recipe is shown in a bounded, read-only field that wraps
long Lua input instead of drawing outside the panel.

Because BeamFX animation follows simulation time, this developer gallery keeps
the game running while its cursor is active. Use it from a safe test location.
The normal Interface pause behavior is restored whenever the panel is hidden.

## Controls

- Select a property with the upper `<` and `>` controls.
- Change its value with the lower `-` and `+` controls.
- Drag the panel header to move the gallery within the visible UI viewport.
- Press **F7** (default binding) to place the preview in front of the player,
  even while the panel is hidden.
- Press **F8** (default binding) to hide or reopen the panel. **Escape** and
  **Hide** hide it too; none of these clear the world preview.
- Use **Clear** to remove the world preview separately. That button then
  becomes **Preview**, which recreates it using the current appearance values.
- Cycle presets, styles, radius, intensity, both spatial fades, taper,
  longitudinal modes, and filament minimum pixel width.
- Setting a positive pixel width automatically selects `filament`; selecting
  another style clears the filament-only width.
- **Pause** freezes pulse and dash motion. Travel uses the smallest accepted
  nonzero speed while paused because API 1.3 deliberately rejects a
  zero-speed traveling window.
- **Reset** restores the initial frost recipe and animation phase.
- **Expanded** switches from concise public input to the deterministic
  canonical appearance represented by the documented preset values.
- **Print** writes both copy-ready forms to `openmw.log`; the wrapped recipe
  field itself is deliberately read-only.
- Hiding the panel does not reset its location or current recipe.

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
- clears its producer when **Clear** is selected, or on load or new game.

No BeamFX implementation module, private render event, shader uniform, LuaLS
stub, or Cod3x feature is used.

## Scope

The preview is a visual design aid. It performs no raycast, collision, damage,
or targeting. `upsertPath` draws connected straight segments through the
chosen points; it does not create mathematically curved geometry.
