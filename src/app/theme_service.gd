class_name ThemeService
extends RefCounted

## M36: file-driven theming. The whole look of the app — UI chrome, 3D
## environment, grids, sketch ink — is described by a human-readable JSON
## theme file (see docs/THEMING.md). Built-in themes ship in res://themes/,
## user themes drop into user://themes/ and show up in Preferences without a
## restart. One resolved token table is what everything reads:
##
##   ThemeService.col("accent")        -> Color
##   ThemeService.metric("radius")     -> float
##   ThemeService.font_size("caption") -> int
##   ThemeService.build_theme()        -> the Godot Theme for the UI tree
##
## A theme file may `extends` another theme id and override only the tokens
## it cares about; color values may be hex strings or `@name` references to
## the theme's `palette` (or to another role), so a user can re-tint a whole
## theme by editing a handful of swatches.

const SETTINGS_PATH := "user://settings.cfg"
const ICON_DIR := "res://assets/icons"
const BUILTIN_DIR := "res://themes"
const USER_DIR := "user://themes"
const SCHEMA := "echocad-theme/1"
const DEFAULT_THEME := "modernist-dark"
## Legacy ids from the M26 dark/light toggle map onto these.
const LEGACY_DARK := "modernist-dark"
const LEGACY_LIGHT := "modernist-light"

## Id of the active theme (file stem).
static var theme_id := ""
## True when the active theme declares "appearance": "dark". Render code that
## only needs a light/dark decision (ghost ink, veils) reads this.
static var dark := true
## M27: model-mode camera projection preference (sketch mode is always ortho).
static var model_ortho := false
## Ribbon buttons show their title under the icon (Preferences; off by
## default so every button is the same icon-only square).
static var show_tool_names := false

static var _icon_cache := {}
static var _font_cache := {}
## Resolved token table of the active theme: {"colors": {role: Color},
## "metrics": {key: float}, "font_sizes": {key: int}, "fonts": {key: path}}.
static var _tokens := {}
## id -> {"id", "name", "path", "appearance", "extends"} for every theme
## found on disk (built-in + user). Rebuilt by scan_themes().
static var _catalog := {}


## Colors every theme is expected to define; anything missing falls back to
## these so a sparse user theme still renders. Also the reference list for
## docs/THEMING.md.
const FALLBACK_COLORS := {
	# shell
	"window_bg": "#151414", "titlebar": "#0f0e0e", "menubar": "#1a1919",
	"ribbon": "#1f1e1e", "panel": "#1a1919", "panel_header": "#1f1e1e",
	"panel_alt": "#1d1c1c", "field": "#131212", "hud": "#1b1a1ae6",
	"border": "#0b0a0a", "border_soft": "#ffffff14", "divider": "#ffffff12",
	# controls
	"btn": "#00000000", "btn_border": "#00000000",
	"btn_hover": "#ffffff12", "btn_hover_border": "#ffffff18",
	"btn_pressed": "#ec301324", "btn_pressed_border": "#ec301355",
	"btn_pressed_text": "#ffb2a4",
	# text + icons
	"text": "#dedbda", "text_strong": "#ffffff", "text_dim": "#8c8887",
	"text_faint": "#6f6b6a", "icon": "#bdb9b8",
	# accent
	"accent": "#ec3013", "accent_hover": "#ff563c", "accent_text": "#ffb2a4",
	"on_accent": "#ffffff", "selection": "#ec301318",
	# semantic
	"success": "#7fc97f", "success_bg": "#1e2a1e", "warning": "#e5a13f",
	"error": "#de6358",
	# viewport + canvas
	"bg3d": "#232222", "ambient": "#8d8a88", "sketch_bg": "#242322",
	"grid_minor": "#ffffff10", "grid_major": "#ffffff1a",
	"sk_grid_minor": "#ffffff0d", "sk_grid_major": "#ffffff16",
	"axis_x": "#e05a4a", "axis_y": "#7fc97f", "axis_z": "#6f9fd8",
	"plane": "#8ca6d91a", "plane_hover": "#8cbfff47",
	"body": "#9e9a97", "body_selected": "#ffb840", "body_edge": "#1a1919",
	"view_cube": "#cfcbc8", "view_cube_text": "#2a2827",
	"hover": "#ffe08c59",
	# sketch ink
	"ink_free": "#f0edeb", "ink_constrained": "#7fc97f",
	"ink_construction": "#b88cf2", "ink_projected": "#d973d9",
	"ink_reference": "#73808c8c", "region_fill": "#ec30131a",
	"dim_line": "#eae7e6", "dim_driven": "#a6a29e",
	"constraint_ok": "#7fc97f", "constraint_unsolved": "#c2c6cf",
	"constraint_redundant": "#d9a040", "constraint_conflict": "#de6358",
	"constraint_selected": "#ffd94d",
}

const FALLBACK_METRICS := {
	"radius": 3.0, "radius_small": 2.0, "border_width": 1.0,
	"menubar_height": 26.0, "ribbon_height": 84.0,
	"big_button_w": 64.0, "big_button_h": 64.0,
	"small_button_w": 48.0, "small_button_h": 44.0,
	"browser_width": 238.0, "row_height": 22.0, "hud_height": 30.0,
	"timeline_height": 52.0, "timeline_chip_w": 52.0, "status_height": 24.0,
	"icon_big": 36.0, "icon_small": 24.0, "icon_row": 14.0,
	"title_height": 28.0,
}

const FALLBACK_FONT_SIZES := {
	"body": 12, "small": 11, "caption": 9, "label": 10, "title": 14,
}

const FALLBACK_FONTS := {
	"ui": "res://assets/fonts/Archivo.ttf",
	"weight_regular": 500, "weight_bold": 600, "weight_heading": 700,
}


## --- token access -------------------------------------------------------------

static func col(key: String, fallback := Color.MAGENTA) -> Color:
	_ensure_loaded()
	var colors: Dictionary = _tokens.get("colors", {})
	if colors.has(key):
		return colors[key]
	if FALLBACK_COLORS.has(key):
		return Color.html(FALLBACK_COLORS[key])
	return fallback


static func metric(key: String, fallback := 0.0) -> float:
	_ensure_loaded()
	var m: Dictionary = _tokens.get("metrics", {})
	if m.has(key):
		return float(m[key])
	return float(FALLBACK_METRICS.get(key, fallback))


static func font_size(key: String) -> int:
	_ensure_loaded()
	var s: Dictionary = _tokens.get("font_sizes", {})
	if s.has(key):
		return int(s[key])
	return int(FALLBACK_FONT_SIZES.get(key, 12))


static func font_path(key := "ui") -> String:
	_ensure_loaded()
	var f: Dictionary = _tokens.get("fonts", {})
	return String(f.get(key, FALLBACK_FONTS.get(key, "")))


static func font_weight(key: String) -> int:
	_ensure_loaded()
	var f: Dictionary = _tokens.get("fonts", {})
	return int(f.get(key, FALLBACK_FONTS.get(key, 500)))


## The UI font at a given variable-font weight (Archivo ships as a variable
## TTF). Missing/invalid font paths fall back to the engine default font so a
## theme that points at a font the user does not have still works.
static func font(weight := -1) -> Font:
	_ensure_loaded()
	if weight < 0:
		weight = font_weight("weight_regular")
	var path := font_path("ui")
	var key := "%s@%d" % [path, weight]
	if _font_cache.has(key):
		return _font_cache[key]
	var base: Font = null
	if path != "" and ResourceLoader.exists(path):
		base = load(path) as Font
	elif path != "" and FileAccess.file_exists(path):
		var ff := FontFile.new()
		if ff.load_dynamic_font(path) == OK:
			base = ff
	if base == null:
		base = ThemeDB.fallback_font
	var fv := FontVariation.new()
	fv.base_font = base
	var ts := TextServerManager.get_primary_interface()
	fv.variation_opentype = {ts.name_to_tag("wght"): weight}
	_font_cache[key] = fv
	return fv


## Release engine resources held in statics before shutdown — statics
## outlive the servers and get reported as leaks otherwise (QA §M31).
static func drop_static_caches() -> void:
	_icon_cache.clear()
	_font_cache.clear()


## Icons ship as white-stroke SVGs; the Button theme's icon colors tint them
## per theme, so one asset set serves both looks. Returns null when the icon
## does not exist (button falls back to text-only).
static func icon(icon_name: String) -> Texture2D:
	if icon_name == "":
		return null
	if _icon_cache.has(icon_name):
		return _icon_cache[icon_name]
	var path := "%s/%s.svg" % [ICON_DIR, icon_name]
	var tex: Texture2D = load(path) if ResourceLoader.exists(path) else null
	_icon_cache[icon_name] = tex
	return tex


## --- theme files --------------------------------------------------------------

## Every theme on disk, built-in first then user://themes, each as
## {"id", "name", "path", "appearance", "extends", "builtin"}.
static func available_themes() -> Array:
	scan_themes()
	var out: Array = []
	for id: String in _catalog:
		out.append(_catalog[id])
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["builtin"] != b["builtin"]:
			return a["builtin"]
		return String(a["name"]) < String(b["name"]))
	return out


static func scan_themes() -> void:
	_catalog.clear()
	_scan_dir(BUILTIN_DIR, true)
	_scan_dir(USER_DIR, false)


static func _scan_dir(dir_path: String, builtin: bool) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for fname in dir.get_files():
		# Exported builds may keep the .json or wrap it as .json.import-less
		# resource; both list fine via DirAccess.
		if not fname.ends_with(".json"):
			continue
		var path := dir_path.path_join(fname)
		var raw := _read_json(path)
		if raw.is_empty():
			continue
		var id := String(raw.get("id", fname.get_basename()))
		# A user theme with a built-in id shadows it — that is how a user
		# tweaks a shipped theme without touching the install.
		_catalog[id] = {
			"id": id,
			"name": String(raw.get("name", id)),
			"path": path,
			"appearance": String(raw.get("appearance", "dark")),
			"extends": String(raw.get("extends", "")),
			"builtin": builtin,
		}


static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK:
		push_warning("ThemeService: %s:%d: %s" % [path, json.get_error_line(),
			json.get_error_message()])
		return {}
	if not (json.data is Dictionary):
		push_warning("ThemeService: %s is not a JSON object" % path)
		return {}
	return json.data


## The user theme folder, created on demand so "Open themes folder" in
## Preferences always has somewhere to go. It is seeded with a README and an
## `examples/` copy of every built-in theme to start from (QA §M36 — an empty
## folder left testers with nothing to copy). `examples/` is not scanned, so
## the copies only become themes once moved up a level.
static func user_theme_dir() -> String:
	var abs := ProjectSettings.globalize_path(USER_DIR)
	DirAccess.make_dir_recursive_absolute(abs)
	seed_user_theme_dir()
	return abs


static func seed_user_theme_dir() -> void:
	var ex := USER_DIR.path_join("examples")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ex))
	var src := DirAccess.open(BUILTIN_DIR)
	if src != null:
		for fname in src.get_files():
			if not fname.ends_with(".json"):
				continue
			var f := FileAccess.open(BUILTIN_DIR.path_join(fname), FileAccess.READ)
			if f == null:
				continue
			var out := FileAccess.open(ex.path_join(fname), FileAccess.WRITE)
			if out != null:
				out.store_string(f.get_as_text())
	var readme := USER_DIR.path_join("README.txt")
	if not FileAccess.file_exists(readme):
		var r := FileAccess.open(readme, FileAccess.WRITE)
		if r != null:
			r.store_string("EchoCAD user themes\n"
				+ "===================\n\n"
				+ "Any *.json theme file in THIS folder appears in Preferences > Theme\n"
				+ "after pressing Reload (or restarting).\n\n"
				+ "To start one: copy a file out of examples/ into this folder, rename it,\n"
				+ "change its \"id\" and \"name\", then edit colours in \"palette\" /\n"
				+ "\"colors\". A file that keeps a built-in id (e.g. modernist-dark)\n"
				+ "replaces that built-in theme.\n\n"
				+ "examples/ is refreshed from the shipped themes every time the folder\n"
				+ "is opened and is not scanned for themes. Format: docs/THEMING.md.\n")


## Load and resolve a theme by id. Unknown ids fall back to the default theme;
## a default that cannot be read resolves to the FALLBACK_* tables. Returns
## the id actually loaded.
static func load_theme(id: String) -> String:
	scan_themes()
	if not _catalog.has(id):
		if id != "":
			push_warning("ThemeService: no theme '%s', using %s" % [id, DEFAULT_THEME])
		id = DEFAULT_THEME
	var merged := _merged_raw(id, [])
	_tokens = _resolve(merged)
	theme_id = id
	dark = String(merged.get("appearance", "dark")) != "light"
	_font_cache.clear()
	return id


## Raw dicts along the `extends` chain, deep-merged child-over-parent.
static func _merged_raw(id: String, seen: Array) -> Dictionary:
	if not _catalog.has(id) or id in seen:
		if id in seen:
			push_warning("ThemeService: circular extends at '%s'" % id)
		return {}
	seen.append(id)
	var raw := _read_json(_catalog[id]["path"])
	var parent_id := String(raw.get("extends", ""))
	var out := _merged_raw(parent_id, seen) if parent_id != "" else {}
	for section in ["palette", "colors", "metrics", "font_sizes", "fonts"]:
		var mine: Dictionary = raw.get(section, {})
		var base: Dictionary = out.get(section, {})
		var merged := base.duplicate()
		for k in mine:
			merged[k] = mine[k]
		out[section] = merged
	for k in ["name", "appearance", "id"]:
		if raw.has(k):
			out[k] = raw[k]
	return out


## Turn the raw merged dict into typed tokens. Color values: "#rgb(a)" hex,
## "@swatch" (palette entry) or "@role" (another color), optionally with a
## trailing "*alpha" multiplier ("@accent*0.15" — the design's tinted fills).
static func _resolve(raw: Dictionary) -> Dictionary:
	var palette: Dictionary = raw.get("palette", {})
	var roles: Dictionary = raw.get("colors", {})
	var colors := {}
	for role in roles:
		colors[role] = _resolve_color(String(roles[role]), palette, roles, [])
	var metrics := {}
	for k in raw.get("metrics", {}):
		metrics[k] = float(raw["metrics"][k])
	var sizes := {}
	for k in raw.get("font_sizes", {}):
		sizes[k] = int(raw["font_sizes"][k])
	return {"colors": colors, "metrics": metrics, "font_sizes": sizes,
		"fonts": raw.get("fonts", {}).duplicate()}


static func _resolve_color(spec: String, palette: Dictionary, roles: Dictionary,
		seen: Array) -> Color:
	spec = spec.strip_edges()
	var alpha_mul := 1.0
	var star := spec.find("*")
	if star > 0:
		alpha_mul = float(spec.substr(star + 1))
		spec = spec.substr(0, star).strip_edges()
	var c := Color.MAGENTA
	if spec.begins_with("@"):
		var ref := spec.substr(1)
		if ref in seen:
			push_warning("ThemeService: circular color reference '@%s'" % ref)
		elif palette.has(ref):
			seen.append(ref)
			c = _resolve_color(String(palette[ref]), palette, roles, seen)
		elif roles.has(ref):
			seen.append(ref)
			c = _resolve_color(String(roles[ref]), palette, roles, seen)
		elif FALLBACK_COLORS.has(ref):
			c = Color.html(FALLBACK_COLORS[ref])
		else:
			push_warning("ThemeService: unknown color reference '@%s'" % ref)
	elif Color.html_is_valid(spec):
		c = Color.html(spec)
	else:
		push_warning("ThemeService: bad color '%s'" % spec)
	c.a *= alpha_mul
	return c


static func _ensure_loaded() -> void:
	if _tokens.is_empty():
		load_theme(theme_id if theme_id != "" else DEFAULT_THEME)


## --- Godot Theme ----------------------------------------------------------------

static func _flat(bg: Color, border: Color, radius := -1.0,
		margin := Vector2(8, 4)) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(int(metric("border_width")))
	sb.set_corner_radius_all(int(radius if radius >= 0.0 else metric("radius")))
	sb.content_margin_left = margin.x
	sb.content_margin_right = margin.x
	sb.content_margin_top = margin.y
	sb.content_margin_bottom = margin.y
	return sb


static func _fill(bg: Color, margin := 0.0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_content_margin_all(margin)
	return sb


static func _empty(margin := 0.0) -> StyleBoxEmpty:
	var sb := StyleBoxEmpty.new()
	sb.set_content_margin_all(margin)
	return sb


## Button family styles: a flat, borderless rest state that lights up on
## hover and tints with the accent when pressed (the design's tool buttons).
static func _style_button(t: Theme, cls: String, margin: Vector2,
		radius: float) -> void:
	t.set_stylebox("normal", cls, _flat(col("btn"), col("btn_border"), radius, margin))
	t.set_stylebox("hover", cls, _flat(col("btn_hover"), col("btn_hover_border"),
		radius, margin))
	t.set_stylebox("pressed", cls, _flat(col("btn_pressed"),
		col("btn_pressed_border"), radius, margin))
	t.set_stylebox("hover_pressed", cls, _flat(col("btn_pressed").lightened(0.05),
		col("btn_pressed_border"), radius, margin))
	t.set_stylebox("focus", cls, _empty())
	var dis := _flat(col("btn"), col("btn_border"), radius, margin)
	t.set_stylebox("disabled", cls, dis)
	t.set_color("font_color", cls, col("text"))
	t.set_color("font_hover_color", cls, col("text_strong"))
	t.set_color("font_focus_color", cls, col("text"))
	t.set_color("font_pressed_color", cls, col("btn_pressed_text"))
	t.set_color("font_hover_pressed_color", cls, col("btn_pressed_text"))
	var dim := col("text_dim")
	dim.a *= 0.6
	t.set_color("font_disabled_color", cls, dim)
	t.set_color("icon_normal_color", cls, col("icon"))
	t.set_color("icon_hover_color", cls, col("text_strong"))
	t.set_color("icon_focus_color", cls, col("icon"))
	t.set_color("icon_pressed_color", cls, col("btn_pressed_text"))
	t.set_color("icon_hover_pressed_color", cls, col("btn_pressed_text"))
	var icon_dis := col("icon")
	icon_dis.a *= 0.35
	t.set_color("icon_disabled_color", cls, icon_dis)
	t.set_font("font", cls, font(font_weight("weight_regular")))
	t.set_font_size("font_size", cls, font_size("body"))


static func build_theme() -> Theme:
	_ensure_loaded()
	var t := Theme.new()
	var text := col("text")
	var radius := metric("radius")
	var radius_sm := metric("radius_small")
	t.default_font = font()
	t.default_font_size = font_size("body")

	# --- buttons ------------------------------------------------------------
	for cls in ["Button", "OptionButton", "MenuButton", "CheckBox", "CheckButton"]:
		_style_button(t, cls, Vector2(8, 4), radius)
	t.set_constant("icon_max_width", "Button", int(metric("icon_small")))
	for cls in ["OptionButton", "MenuButton"]:
		t.set_constant("icon_max_width", cls, int(metric("icon_row")))
		t.set_color("font_color", cls, col("text"))
	# Option/menu buttons show a hairline so they read as fields.
	t.set_stylebox("normal", "OptionButton", _flat(col("field"), col("border_soft"),
		radius, Vector2(8, 4)))
	for cls in ["CheckBox", "CheckButton"]:
		t.set_stylebox("normal", cls, _empty(4))
		t.set_stylebox("pressed", cls, _empty(4))
		t.set_stylebox("hover", cls, _flat(col("btn_hover"), Color.TRANSPARENT,
			radius_sm, Vector2(4, 2)))
		t.set_stylebox("hover_pressed", cls, _flat(col("btn_hover"),
			Color.TRANSPARENT, radius_sm, Vector2(4, 2)))
		t.set_color("font_pressed_color", cls, text)
		t.set_color("font_hover_pressed_color", cls, text)
		t.set_font_size("font_size", cls, font_size("small"))
	t.set_icon("checked", "CheckBox", _check_icon(true))
	t.set_icon("unchecked", "CheckBox", _check_icon(false))
	t.set_icon("checked_disabled", "CheckBox", _check_icon(true))
	t.set_icon("unchecked_disabled", "CheckBox", _check_icon(false))

	# Ribbon tool button (M36 QA): ONE look for every ribbon button — a
	# square icon, optionally with its title underneath when
	# show_tool_names is on. BigToolButton / SmallToolButton stay as
	# aliases of it for code and docs that still name them.
	t.add_type("ToolButton")
	t.set_type_variation("ToolButton", "Button")
	_style_button(t, "ToolButton", Vector2(3, 3), radius)
	t.set_constant("icon_max_width", "ToolButton", int(metric("icon_big")))
	t.set_constant("h_separation", "ToolButton", 3)
	t.set_font_size("font_size", "ToolButton", font_size("caption"))
	t.set_font("font", "ToolButton", font(font_weight("weight_regular")))
	for alias in ["BigToolButton", "SmallToolButton"]:
		t.add_type(alias)
		t.set_type_variation(alias, "ToolButton")
	# Flyout rows: icon + title, left aligned, inside a stack's popup.
	t.add_type("FlyoutButton")
	t.set_type_variation("FlyoutButton", "Button")
	_style_button(t, "FlyoutButton", Vector2(10, 5), radius_sm)
	t.set_constant("icon_max_width", "FlyoutButton", int(metric("icon_small")))
	t.set_constant("h_separation", "FlyoutButton", 8)
	t.set_font_size("font_size", "FlyoutButton", font_size("small"))
	t.set_stylebox("panel", "PopupPanel", _flat(col("panel"), col("border_soft"),
		radius, Vector2(4, 4)))
	# HUD pill buttons inside the viewport.
	t.add_type("HudButton")
	t.set_type_variation("HudButton", "Button")
	_style_button(t, "HudButton", Vector2(7, 2), radius_sm)
	t.set_constant("icon_max_width", "HudButton", 16)
	t.set_font_size("font_size", "HudButton", font_size("label"))
	t.set_font("font", "HudButton", font(font_weight("weight_regular")))
	# Primary action (Finish Sketch, dialog OK): solid accent.
	t.add_type("PrimaryButton")
	t.set_type_variation("PrimaryButton", "Button")
	_style_button(t, "PrimaryButton", Vector2(10, 4), radius)
	t.set_stylebox("normal", "PrimaryButton", _flat(col("accent"),
		col("accent_hover"), radius, Vector2(10, 4)))
	t.set_stylebox("hover", "PrimaryButton", _flat(col("accent_hover"),
		col("accent_hover"), radius, Vector2(10, 4)))
	t.set_stylebox("pressed", "PrimaryButton", _flat(col("accent").darkened(0.1),
		col("accent_hover"), radius, Vector2(10, 4)))
	for cn in ["font_color", "font_hover_color", "font_pressed_color",
			"icon_normal_color", "icon_hover_color", "icon_pressed_color"]:
		t.set_color(cn, "PrimaryButton", col("on_accent"))
	t.set_font("font", "PrimaryButton", font(font_weight("weight_bold")))
	t.set_font_size("font_size", "PrimaryButton", font_size("label"))
	# Timeline chip: icon above label, thin.
	t.add_type("TimelineChip")
	t.set_type_variation("TimelineChip", "Button")
	_style_button(t, "TimelineChip", Vector2(2, 3), radius)
	t.set_constant("icon_max_width", "TimelineChip", 19)
	t.set_font_size("font_size", "TimelineChip", font_size("caption"))
	t.set_constant("h_separation", "TimelineChip", 2)
	# The sketch being edited: same footprint, accent fill.
	t.add_type("TimelineChipActive")
	t.set_type_variation("TimelineChipActive", "TimelineChip")
	t.set_stylebox("normal", "TimelineChipActive", _flat(col("accent"),
		col("accent_hover"), radius, Vector2(2, 3)))
	t.set_stylebox("hover", "TimelineChipActive", _flat(col("accent_hover"),
		col("accent_hover"), radius, Vector2(2, 3)))
	t.set_stylebox("pressed", "TimelineChipActive", _flat(col("accent"),
		col("accent_hover"), radius, Vector2(2, 3)))
	for cn in ["font_color", "font_hover_color", "font_pressed_color",
			"icon_normal_color", "icon_hover_color", "icon_pressed_color"]:
		t.set_color(cn, "TimelineChipActive", col("on_accent"))
	# Rollback marker: a thin accent bar.
	t.add_type("TimelineMarker")
	t.set_type_variation("TimelineMarker", "Button")
	var mk := _fill(col("accent"))
	mk.set_corner_radius_all(int(radius_sm))
	mk.set_content_margin_all(0)
	mk.expand_margin_left = -2
	mk.expand_margin_right = -2
	t.set_stylebox("normal", "TimelineMarker", mk)
	var mkh := _fill(col("accent_hover"))
	mkh.set_corner_radius_all(int(radius_sm))
	mkh.set_content_margin_all(0)
	t.set_stylebox("hover", "TimelineMarker", mkh)
	t.set_stylebox("pressed", "TimelineMarker", mkh)
	t.set_stylebox("hover_pressed", "TimelineMarker", mkh)
	t.set_stylebox("focus", "TimelineMarker", _empty())
	# Menu bar entries: flat text.
	t.add_type("MenuBarButton")
	t.set_type_variation("MenuBarButton", "MenuButton")
	_style_button(t, "MenuBarButton", Vector2(10, 2), 0.0)
	t.set_font_size("font_size", "MenuBarButton", font_size("small"))
	t.set_stylebox("normal", "MenuBar", _empty())
	t.set_stylebox("hover", "MenuBar", _flat(col("btn_hover"), Color.TRANSPARENT,
		0.0, Vector2(10, 2)))
	t.set_stylebox("pressed", "MenuBar", _flat(col("btn_pressed"),
		Color.TRANSPARENT, 0.0, Vector2(10, 2)))
	t.set_stylebox("disabled", "MenuBar", _empty())
	t.set_stylebox("normal", "MenuBar", _flat(Color.TRANSPARENT, Color.TRANSPARENT,
		0.0, Vector2(10, 2)))
	t.set_color("font_color", "MenuBar", col("text"))
	t.set_color("font_hover_color", "MenuBar", col("text_strong"))
	t.set_color("font_pressed_color", "MenuBar", col("btn_pressed_text"))
	t.set_color("font_hover_pressed_color", "MenuBar", col("btn_pressed_text"))
	t.set_font_size("font_size", "MenuBar", font_size("small"))
	t.set_constant("h_separation", "MenuBar", 0)

	# --- labels -------------------------------------------------------------
	t.set_color("font_color", "Label", text)
	t.set_font_size("font_size", "Label", font_size("body"))
	t.add_type("CaptionLabel")     # ribbon group caption: CREATE ›
	t.set_type_variation("CaptionLabel", "Label")
	t.set_color("font_color", "CaptionLabel", col("text_dim"))
	t.set_font_size("font_size", "CaptionLabel", font_size("caption"))
	t.set_font("font", "CaptionLabel", font(font_weight("weight_bold")))
	t.add_type("HeaderLabel")      # panel header: BROWSER
	t.set_type_variation("HeaderLabel", "Label")
	t.set_color("font_color", "HeaderLabel", col("text_dim"))
	t.set_font_size("font_size", "HeaderLabel", font_size("caption"))
	t.set_font("font", "HeaderLabel", font(font_weight("weight_bold")))
	t.add_type("StatusLabel")      # status bar values
	t.set_type_variation("StatusLabel", "Label")
	t.set_color("font_color", "StatusLabel", col("text"))
	t.set_font_size("font_size", "StatusLabel", font_size("label"))
	t.add_type("StatusIdLabel")    # status bar identity readout: e4 line #3
	t.set_type_variation("StatusIdLabel", "Label")
	t.set_color("font_color", "StatusIdLabel", col("text_dim"))
	t.set_font_size("font_size", "StatusIdLabel", font_size("label"))
	t.add_type("StatusKeyLabel")   # status bar keys: CURSOR / UNITS
	t.set_type_variation("StatusKeyLabel", "Label")
	t.set_color("font_color", "StatusKeyLabel", col("text_faint"))
	t.set_font_size("font_size", "StatusKeyLabel", font_size("label"))
	t.add_type("DimLabel")
	t.set_type_variation("DimLabel", "Label")
	t.set_color("font_color", "DimLabel", col("text_dim"))
	t.set_font_size("font_size", "DimLabel", font_size("small"))
	t.add_type("BrandLabel")
	t.set_type_variation("BrandLabel", "Label")
	t.set_color("font_color", "BrandLabel", col("text_dim"))
	t.set_font_size("font_size", "BrandLabel", font_size("small"))
	t.set_font("font", "BrandLabel", font(font_weight("weight_bold")))

	# --- fields -------------------------------------------------------------
	for cls in ["LineEdit", "TextEdit", "SpinBox"]:
		t.set_stylebox("normal", cls, _flat(col("field"), col("border_soft"),
			radius_sm, Vector2(8, 4)))
		t.set_stylebox("focus", cls, _flat(col("field"), col("accent"),
			radius_sm, Vector2(8, 4)))
		t.set_stylebox("read_only", cls, _flat(col("field"), col("border_soft"),
			radius_sm, Vector2(8, 4)))
		t.set_color("font_color", cls, text)
		t.set_color("caret_color", cls, col("accent"))
		t.set_color("font_placeholder_color", cls, col("text_dim"))
		t.set_color("selection_color", cls, col("selection"))
	t.set_color("font_selected_color", "LineEdit", col("text_strong"))

	# --- panels -------------------------------------------------------------
	t.set_stylebox("panel", "PanelContainer", _fill(col("panel")))
	# Plain Panel serves as the themed backdrop behind the shelf rows and
	# inside raw Window dialogs (see AppRoot).
	t.set_stylebox("panel", "Panel", _fill(col("window_bg")))
	t.add_type("Ribbon")
	t.set_type_variation("Ribbon", "PanelContainer")
	var rib := _fill(col("ribbon"))
	rib.border_color = col("border")
	rib.border_width_bottom = 1
	rib.content_margin_top = 5.0
	t.set_stylebox("panel", "Ribbon", rib)
	t.add_type("MenuBarPanel")
	t.set_type_variation("MenuBarPanel", "PanelContainer")
	var mb := _fill(col("menubar"))
	mb.border_color = col("border")
	mb.border_width_bottom = 1
	t.set_stylebox("panel", "MenuBarPanel", mb)
	t.add_type("SidePanel")
	t.set_type_variation("SidePanel", "PanelContainer")
	var side := _fill(col("panel"))
	side.border_color = col("border")
	side.border_width_right = 1
	t.set_stylebox("panel", "SidePanel", side)
	t.add_type("PanelHeader")
	t.set_type_variation("PanelHeader", "PanelContainer")
	var ph := _fill(col("panel_header"))
	ph.border_color = col("border")
	ph.border_width_bottom = 1
	ph.content_margin_left = 8.0
	ph.content_margin_right = 8.0
	t.set_stylebox("panel", "PanelHeader", ph)
	t.add_type("HudPanel")
	t.set_type_variation("HudPanel", "PanelContainer")
	t.set_stylebox("panel", "HudPanel", _flat(col("hud"), col("border_soft"),
		radius, Vector2(3, 2)))
	t.add_type("TimelinePanel")
	t.set_type_variation("TimelinePanel", "PanelContainer")
	var tl := _fill(col("panel"))
	tl.border_color = col("border")
	tl.border_width_top = 1
	tl.content_margin_left = 8.0
	tl.content_margin_right = 8.0
	t.set_stylebox("panel", "TimelinePanel", tl)
	t.add_type("StatusPanel")
	t.set_type_variation("StatusPanel", "PanelContainer")
	var st := _fill(col("titlebar"))
	st.border_color = col("border")
	st.border_width_top = 1
	st.content_margin_left = 10.0
	st.content_margin_right = 10.0
	t.set_stylebox("panel", "StatusPanel", st)
	t.add_type("Divider")
	t.set_type_variation("Divider", "Panel")
	t.set_stylebox("panel", "Divider", _fill(col("divider")))

	# --- windows + dialogs ----------------------------------------------------
	t.set_stylebox("panel", "Window", _fill(col("panel_alt")))
	t.set_color("title_color", "Window", text)
	t.set_font_size("title_font_size", "Window", font_size("body"))
	t.set_font("title_font", "Window", font(font_weight("weight_bold")))
	# Embedded sub-windows (dialogs, file pickers) draw their title bar from
	# this stylebox, not from the OS — without it a light theme keeps the
	# engine's charcoal bar over a light panel (QA §M36).
	var th := int(metric("title_height"))
	t.set_constant("title_height", "Window", th)
	for nm in ["embedded_border", "embedded_unfocused_border"]:
		var eb := _flat(col("titlebar") if nm == "embedded_border"
			else col("menubar"), col("border"), radius, Vector2.ZERO)
		eb.expand_margin_top = th
		eb.expand_margin_left = 1
		eb.expand_margin_right = 1
		eb.expand_margin_bottom = 1
		eb.shadow_color = Color(0, 0, 0, 0.35 if dark else 0.18)
		eb.shadow_size = 10
		t.set_stylebox(nm, "Window", eb)
	t.set_icon("close", "Window", _close_icon(col("text_dim")))
	t.set_icon("close_pressed", "Window", _close_icon(col("text_strong")))
	t.set_constant("close_h_offset", "Window", 22)
	t.set_constant("close_v_offset", "Window", th - 8)
	for cls in ["AcceptDialog", "ConfirmationDialog", "FileDialog"]:
		t.set_stylebox("panel", cls, _fill(col("panel_alt"), 8.0))
	t.set_stylebox("panel", "PopupMenu", _flat(col("panel"), col("border_soft"),
		radius, Vector2(4, 4)))
	t.set_color("font_color", "PopupMenu", text)
	t.set_color("font_hover_color", "PopupMenu", col("text_strong"))
	t.set_color("font_disabled_color", "PopupMenu", col("text_faint"))
	t.set_color("font_accelerator_color", "PopupMenu", col("text_dim"))
	t.set_color("font_separator_color", "PopupMenu", col("text_faint"))
	t.set_font_size("font_size", "PopupMenu", font_size("small"))
	t.set_stylebox("hover", "PopupMenu", _flat(col("btn_pressed"),
		Color.TRANSPARENT, radius_sm, Vector2(4, 2)))
	t.set_stylebox("separator", "PopupMenu", _fill(col("divider")))
	t.set_constant("v_separation", "PopupMenu", 6)
	t.set_stylebox("panel", "TooltipPanel", _flat(col("hud"), col("border_soft"),
		radius, Vector2(8, 4)))
	t.set_color("font_color", "TooltipLabel", text)
	t.set_font_size("font_size", "TooltipLabel", font_size("small"))

	# --- tree ---------------------------------------------------------------
	t.set_stylebox("panel", "Tree", _fill(col("panel"), 4.0))
	t.set_stylebox("focus", "Tree", _empty())
	t.set_color("font_color", "Tree", text)
	t.set_font_size("font_size", "Tree", font_size("small"))
	var tsel := _fill(col("selection"))
	tsel.border_color = col("accent")
	tsel.border_width_left = 2
	t.set_stylebox("selected", "Tree", tsel)
	t.set_stylebox("selected_focus", "Tree", tsel)
	t.set_stylebox("hovered", "Tree", _fill(col("btn_hover")))
	t.set_stylebox("hovered_dimmed", "Tree", _fill(col("btn_hover")))
	# Hover-while-selected has its own entries (Godot 4.4+); left unset, the
	# engine defaults paint the selected label white over our pale band.
	t.set_stylebox("hovered_selected", "Tree", tsel)
	t.set_stylebox("hovered_selected_focus", "Tree", tsel)
	t.set_stylebox("cursor", "Tree", _empty())
	t.set_stylebox("cursor_unfocused", "Tree", _empty())
	t.set_color("font_selected_color", "Tree", col("text_strong"))
	t.set_color("font_hovered_color", "Tree", col("text_strong"))
	t.set_color("font_hovered_selected_color", "Tree", col("text_strong"))
	t.set_color("font_hovered_dimmed_color", "Tree", col("text_dim"))
	t.set_color("font_disabled_color", "Tree", col("text_dim"))
	t.set_color("guide_color", "Tree", Color.TRANSPARENT)
	t.set_color("relationship_line_color", "Tree", col("divider"))
	t.set_color("children_hl_line_color", "Tree", col("divider"))
	t.set_color("parent_hl_line_color", "Tree", col("divider"))
	t.set_constant("v_separation", "Tree", int(metric("row_height")) - 16)
	t.set_constant("item_margin", "Tree", 12)
	t.set_constant("inner_item_margin_left", "Tree", 2)
	t.set_constant("h_separation", "Tree", 6)
	t.set_icon("checked", "Tree", _eye_icon(true))
	t.set_icon("unchecked", "Tree", _eye_icon(false))
	t.set_icon("checked_disabled", "Tree", _eye_icon(true))
	t.set_icon("unchecked_disabled", "Tree", _eye_icon(false))

	# --- separators + misc --------------------------------------------------
	var vsep := StyleBoxLine.new()
	vsep.color = col("divider")
	vsep.vertical = true
	vsep.grow_begin = -8
	vsep.grow_end = -8
	t.set_stylebox("separator", "VSeparator", vsep)
	t.set_constant("separation", "VSeparator", 1)
	var hsep := StyleBoxLine.new()
	hsep.color = col("divider")
	t.set_stylebox("separator", "HSeparator", hsep)
	t.set_color("font_color", "ProgressBar", text)
	t.set_color("font_color", "ItemList", text)
	t.set_stylebox("panel", "ItemList", _fill(col("field"), 4.0))
	t.set_stylebox("panel", "ScrollContainer", _empty())
	t.set_stylebox("panel", "TabContainer", _fill(col("panel")))
	t.set_stylebox("grabber", "VScrollBar", _flat(col("btn_hover"),
		Color.TRANSPARENT, 2.0, Vector2(0, 0)))
	t.set_stylebox("grabber", "HScrollBar", _flat(col("btn_hover"),
		Color.TRANSPARENT, 2.0, Vector2(0, 0)))
	return t


## Title-bar close glyph: a thin × in the given color.
static func _close_icon(c: Color) -> Texture2D:
	var s := 14
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for i in range(3, s - 3):
		_dot(img, i, i, c)
		_dot(img, s - 1 - i, i, c)
	return ImageTexture.create_from_image(img)


## Checkbox glyphs drawn from theme colors (the design's filled accent box
## with a white tick; an outlined box when off).
static func _check_icon(on: bool) -> Texture2D:
	var s := 14
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	var bg := col("accent") if on else col("field")
	var border := col("accent_hover") if on else col("border_soft")
	border.a = maxf(border.a, 0.35)
	for y in s:
		for x in s:
			var edge := x == 0 or y == 0 or x == s - 1 or y == s - 1
			img.set_pixel(x, y, border if edge else bg)
	if on:
		var ink := col("on_accent")
		# A tick: (3,7)->(6,10)->(11,4), two pixels thick.
		for i in 4:
			_dot(img, 3 + i, 7 + i, ink)
			_dot(img, 3 + i, 8 + i, ink)
		for i in 6:
			_dot(img, 6 + i, 10 - i, ink)
			_dot(img, 6 + i, 9 - i, ink)
	return ImageTexture.create_from_image(img)


## Browser eye glyph: an open eye with a pupil when visible; a faint eye
## with a slash through it when hidden. Drawn 2x and downsampled so the
## curves read cleanly at 16px.
static func _eye_icon(on: bool) -> Texture2D:
	var s := 32
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color.TRANSPARENT)
	var ink := col("icon") if on else col("text_faint")
	var cx := 15.5
	var cy := 15.5
	var rx := 13.0
	var ry := 8.0
	for y in s:
		for x in s:
			var dx := (x - cx) / rx
			var dy := (y - cy) / ry
			var d := dx * dx + dy * dy
			if d <= 1.0 and d >= 0.70:
				img.set_pixel(x, y, ink)
			elif on and (x - cx) * (x - cx) + (y - cy) * (y - cy) <= 4.2 * 4.2:
				img.set_pixel(x, y, ink)
	if not on:
		for i in range(4, 28):
			for t in range(-1, 2):
				_dot(img, i + t, 31 - i, ink)
	img.resize(16, 16, Image.INTERPOLATE_LANCZOS)
	return ImageTexture.create_from_image(img)


static func _dot(img: Image, x: int, y: int, c: Color) -> void:
	if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
		img.set_pixel(x, y, c)


## --- settings -------------------------------------------------------------------

static func load_settings() -> void:
	var cfg := ConfigFile.new()
	var id := ""
	if cfg.load(SETTINGS_PATH) == OK:
		id = String(cfg.get_value("ui", "theme", ""))
		# Pre-M36 settings only knew dark/light; honor that choice once.
		if id == "" and cfg.has_section_key("ui", "dark"):
			id = LEGACY_DARK if bool(cfg.get_value("ui", "dark", true)) \
				else LEGACY_LIGHT
		model_ortho = bool(cfg.get_value("view", "ortho", false))
		show_tool_names = bool(cfg.get_value("ui", "show_tool_names", false))
	load_theme(id if id != "" else DEFAULT_THEME)


static func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)   # keep unrelated sections if any
	cfg.set_value("ui", "theme", theme_id)
	cfg.set_value("ui", "dark", dark)
	cfg.set_value("view", "ortho", model_ortho)
	cfg.set_value("ui", "show_tool_names", show_tool_names)
	cfg.save(SETTINGS_PATH)
