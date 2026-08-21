# Theming EchoCAD

EchoCAD's entire look — window chrome, ribbon, browser, viewport backdrop,
grids, sketch ink, constraint badges — is driven by **one JSON theme file**.
Pick a theme in *Preferences → Theme*, or drop your own file into the user
themes folder (*Preferences → Open themes folder*) and press *Reload*.

Nothing in the app hard-codes a colour, font or size that a theme can carry.
Code reads tokens through `ThemeService`:

```gdscript
ThemeService.col("accent")          # Color
ThemeService.metric("radius")       # float
ThemeService.font_size("caption")   # int
ThemeService.font(600)              # Font at a variable-font weight
```

## Where themes live

| Location | Purpose |
| --- | --- |
| `res://themes/*.json` | Built-in themes shipped with the app. |
| `user://themes/*.json` | Your themes. On Windows that is `%APPDATA%\Godot\app_userdata\EchoCAD\themes\`; *Preferences → Open themes folder* opens it. The folder is seeded with a `README.txt` and an `examples/` copy of every built-in theme (refreshed on each open; `examples/` itself is **not** scanned — copy a file up one level to use it). |

Built-in: `modernist-dark` (default), `modernist-light`, `classic-dark`.
A user file whose `id` matches a built-in **shadows** it — copy
`themes/modernist-dark.json` next to your user themes, edit a few swatches,
keep the id, and the app picks up your version.

The selected theme id is remembered in `user://settings.cfg` (`[ui] theme`);
the ribbon's *Show tool names* preference lives beside it
(`[ui] show_tool_names`, default off — every ribbon button is an icon square
until it is on).

## File format

```jsonc
{
  "$schema": "echocad-theme/1",
  "id": "my-theme",              // file stem by default; what settings.cfg stores
  "name": "My Theme",            // shown in Preferences
  "appearance": "dark",          // "dark" | "light" — drives light/dark-only logic
  "extends": "modernist-dark",   // optional: inherit every token from this theme

  "palette": {                   // optional named swatches, referenced as "@name"
    "brand": "#1e90ff"
  },
  "colors": {                    // role -> "#rgb", "#rrggbb", "#rrggbbaa",
    "accent": "@brand",          //         "@swatch", "@other_role",
    "selection": "@brand*0.15",  //         any of those with "*alpha" multiplier
    "bg3d": "#202428"
  },
  "fonts": {
    "ui": "res://assets/fonts/Archivo.ttf",   // res:// or an absolute path
    "weight_regular": 500, "weight_bold": 600, "weight_heading": 700
  },
  "font_sizes": { "body": 12, "small": 11, "label": 10, "caption": 9, "title": 14 },
  "metrics":    { "radius": 3, "ribbon_height": 84, "browser_width": 238 }
}
```

Rules:

- Every section is optional. Missing tokens come from the `extends` parent,
  then from the built-in fallbacks in `ThemeService.FALLBACK_*`, so a
  ten-line theme is valid.
- `extends` chains are followed recursively (child wins); cycles are
  reported and broken.
- Colour references resolve palette first, then other roles, then the
  fallback table. `"@accent*0.15"` is the idiom for tinted fills.
- Bad values log a warning and fall back — a broken theme never blanks the UI.
- Keys starting with `_` (e.g. `_comment`) are ignored.

## Colour roles

**Shell** — `window_bg`, `titlebar`, `menubar`, `ribbon`, `panel`,
`panel_header`, `panel_alt`, `field`, `hud`, `border`, `border_soft`, `divider`

**Controls** — `btn`, `btn_border`, `btn_hover`, `btn_hover_border`,
`btn_pressed`, `btn_pressed_border`, `btn_pressed_text`

**Text / icons** — `text`, `text_strong`, `text_dim`, `text_faint`, `icon`

**Accent** — `accent`, `accent_hover`, `accent_text`, `on_accent`, `selection`

**Semantic** — `success`, `success_bg`, `warning`, `error`

**Viewport** — `bg3d`, `ambient`, `sketch_bg`, `grid_minor`, `grid_major`,
`sk_grid_minor`, `sk_grid_major`, `axis_x`, `axis_y`, `axis_z`, `plane`,
`plane_hover`, `body`, `body_selected`, `body_edge`, `hover`, `view_cube`
(cube faces, a light grey), `view_cube_text` (face labels + edges),
`view_cube_nav` (the house glyph beside the cube — pick one that reads
against `bg3d`), `edge_candidate` (pickable edge lines while a fillet /
chamfer pick is armed; picked edges use `body_selected`, the hovered chain
`hover`), `section_cap` (the cut face of bodies in section analysis)

**Sketch ink** — `ink_free` (under-constrained), `ink_constrained`,
`ink_construction`, `ink_projected`, `ink_reference`, `region_fill`,
`dim_line`, `dim_driven`, `constraint_ok`, `constraint_unsolved`,
`constraint_redundant`, `constraint_conflict`, `constraint_selected`,
`sk_point` (vertex markers — pick one that reads against `sketch_bg`),
`sk_selected` (selection outline), `sk_hover` (hover pre-highlight)

## Metrics

`radius`, `radius_small`, `border_width`, `menubar_height`, `ribbon_height`,
`big_button_w/h`, `small_button_w/h`, `browser_width`, `row_height`,
`hud_height`, `timeline_height`, `timeline_chip_w`, `status_height`,
`icon_big`, `icon_small`, `icon_row`, `title_height` (embedded dialog title
bar), `dialog_label_w` / `dialog_pad` / `dialog_gap` / `dialog_min_w` /
`dialog_field_w` (feature dialog row label width, outer padding, row gap,
minimum width, field width) — all in pixels. `small_button_w/h` is the icon-only ribbon square,
`big_button_w/h` the footprint once *Show tool names* is on.

## Type variations

`build_theme()` registers named variations that the shell uses; a theme
changes them through the tokens above, code opts in with
`control.theme_type_variation = "..."`:

`ToolButton` (every ribbon button; `BigToolButton` / `SmallToolButton`
are aliases of it), `FlyoutButton` (rows in a stack's flyout), `HudButton`, `PrimaryButton`,
`TimelineChip` (`TimelineChipActive` = the sketch being edited,
`TimelineChipError` = a feature that failed to compute, reason in its
tooltip — border + label in `error`; `TimelineChipWarn` = computed from a
stale reference, in `warning`), `MenuBarButton`, `CaptionLabel`, `HeaderLabel`,
`StatusLabel`, `StatusKeyLabel`, `StatusIdLabel`, `DimLabel`, `BrandLabel`,
`DialogLabel` / `DialogErrorLabel` / `TargetChip` (feature dialogs, M39), `Ribbon`,
`MenuBarPanel`, `SidePanel`, `PanelHeader`, `HudPanel`, `TimelinePanel`,
`StatusPanel`, `Divider`. `Window` additionally carries
`embedded_border` / `embedded_unfocused_border` (title bar in `titlebar` /
`menubar`), a themed close glyph and `title_height`, so embedded dialogs
match the appearance.

## Fonts

The shipped UI face is **Archivo** (variable TTF, SIL OFL — see
`assets/fonts/Archivo-OFL.txt`). `fonts.ui` may point at any TTF/OTF; weights
are applied through the `wght` axis when the font has one, otherwise they are
ignored. A path that does not exist falls back to the engine font.

## Writing code that respects themes

- Never write a literal `Color(...)` for anything a user could reasonably want
  to recolour; add a role to `FALLBACK_COLORS`, document it here, and read it
  with `ThemeService.col()`.
- Colours baked into materials/textures at build time must be rebuilt in
  `apply_theme()` of their owner (see `CadWorld.apply_theme`).
- `AppRoot.apply_theme()` is the single fan-out; `set_theme_id(id)` is the
  entry point (RPC + tests use it).
