class_name ThemeService
extends RefCounted

## M26: light/dark theming. One static palette the whole app reads — the UI
## Theme resource is built from it, and the render layer (world background,
## grids, sketch canvas) looks colors up per draw so a switch repaints
## everything without rebuilding scenes. Persisted in user://settings.cfg.

const SETTINGS_PATH := "user://settings.cfg"
const ICON_DIR := "res://assets/icons"

static var dark := true
static var _icon_cache := {}

## Dark palette carries the pre-M26 hardcoded colors verbatim, so the default
## look is unchanged.
const DARK := {
	"bg3d": Color(0.13, 0.14, 0.16),
	"ambient": Color(0.55, 0.57, 0.62),
	"grid_minor": Color(1, 1, 1, 0.085),
	"grid_major": Color(1, 1, 1, 0.17),
	"sk_grid_minor": Color(1, 1, 1, 0.14),
	"sk_grid_major": Color(1, 1, 1, 0.26),
	"panel": Color(0.16, 0.17, 0.19),
	"panel_alt": Color(0.135, 0.145, 0.165),
	"btn": Color(0.215, 0.225, 0.255),
	"btn_hover": Color(0.265, 0.28, 0.32),
	"btn_pressed": Color(0.16, 0.30, 0.47),
	"border": Color(0.30, 0.32, 0.36),
	"field": Color(0.11, 0.115, 0.13),
	"text": Color(0.90, 0.91, 0.93),
	"text_dim": Color(0.60, 0.63, 0.68),
	"icon": Color(0.88, 0.90, 0.94),
	"accent": Color(0.30, 0.62, 0.96),
}

const LIGHT := {
	"bg3d": Color(0.91, 0.92, 0.94),
	"ambient": Color(0.72, 0.74, 0.77),
	"grid_minor": Color(0, 0, 0, 0.10),
	"grid_major": Color(0, 0, 0, 0.20),
	"sk_grid_minor": Color(0, 0, 0, 0.14),
	"sk_grid_major": Color(0, 0, 0, 0.26),
	"panel": Color(0.855, 0.865, 0.885),
	"panel_alt": Color(0.895, 0.905, 0.92),
	"btn": Color(0.945, 0.95, 0.96),
	"btn_hover": Color(0.98, 0.985, 0.99),
	"btn_pressed": Color(0.75, 0.84, 0.96),
	"border": Color(0.70, 0.72, 0.76),
	"field": Color(0.99, 0.99, 1.0),
	"text": Color(0.12, 0.13, 0.15),
	"text_dim": Color(0.40, 0.43, 0.48),
	"icon": Color(0.20, 0.22, 0.26),
	"accent": Color(0.12, 0.42, 0.80),
}


static func col(key: String) -> Color:
	var pal: Dictionary = DARK if dark else LIGHT
	return pal.get(key, Color.MAGENTA)


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


static func _flat(bg: Color, border: Color, radius := 4) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 4.0
	return sb


static func build_theme() -> Theme:
	var t := Theme.new()
	var text := col("text")
	var border := col("border")

	# Buttons (OptionButton/MenuButton/CheckBox inherit Button styles where
	# unset, but get explicit entries so popups look right too).
	for cls in ["Button", "OptionButton", "MenuButton"]:
		t.set_stylebox("normal", cls, _flat(col("btn"), border))
		t.set_stylebox("hover", cls, _flat(col("btn_hover"), border))
		t.set_stylebox("pressed", cls, _flat(col("btn_pressed"), col("accent")))
		t.set_stylebox("focus", cls, _flat(col("btn"), col("accent")))
		var dis := _flat(col("btn"), border)
		dis.bg_color.a = 0.5
		t.set_stylebox("disabled", cls, dis)
		for cn in ["font_color", "font_hover_color", "font_focus_color"]:
			t.set_color(cn, cls, text)
		t.set_color("font_pressed_color", cls, text)
		t.set_color("font_disabled_color", cls, col("text_dim"))
		for cn in ["icon_normal_color", "icon_hover_color", "icon_focus_color"]:
			t.set_color(cn, cls, col("icon"))
		t.set_color("icon_pressed_color", cls, col("icon"))
		var icon_dis := col("icon")
		icon_dis.a = 0.45
		t.set_color("icon_disabled_color", cls, icon_dis)
		t.set_constant("icon_max_width", cls, 18)

	for cls in ["CheckBox", "CheckButton"]:
		var empty := StyleBoxEmpty.new()
		empty.content_margin_left = 4.0
		empty.content_margin_right = 4.0
		t.set_stylebox("normal", cls, empty)
		t.set_stylebox("hover", cls, empty)
		t.set_stylebox("pressed", cls, empty)
		t.set_stylebox("focus", cls, empty)
		t.set_color("font_color", cls, text)
		t.set_color("font_hover_color", cls, text)
		t.set_color("font_pressed_color", cls, text)

	t.set_color("font_color", "Label", text)

	for cls in ["LineEdit", "TextEdit"]:
		t.set_stylebox("normal", cls, _flat(col("field"), border, 3))
		t.set_stylebox("focus", cls, _flat(col("field"), col("accent"), 3))
		t.set_color("font_color", cls, text)
		t.set_color("caret_color", cls, text)
		t.set_color("font_placeholder_color", cls, col("text_dim"))

	var panel := StyleBoxFlat.new()
	panel.bg_color = col("panel")
	t.set_stylebox("panel", "PanelContainer", panel)
	var wpanel := StyleBoxFlat.new()
	wpanel.bg_color = col("panel_alt")
	t.set_stylebox("panel", "Window", wpanel)
	t.set_color("title_color", "Window", text)
	var ppanel := _flat(col("panel"), border, 3)
	t.set_stylebox("panel", "PopupMenu", ppanel)
	t.set_color("font_color", "PopupMenu", text)
	t.set_color("font_hover_color", "PopupMenu", text)
	var pitem := StyleBoxFlat.new()
	pitem.bg_color = col("btn_pressed")
	t.set_stylebox("hover", "PopupMenu", pitem)

	var tbg := StyleBoxFlat.new()
	tbg.bg_color = col("panel_alt")
	t.set_stylebox("panel", "Tree", tbg)
	t.set_color("font_color", "Tree", text)
	var tsel := StyleBoxFlat.new()
	tsel.bg_color = col("btn_pressed")
	t.set_stylebox("selected", "Tree", tsel)
	t.set_stylebox("selected_focus", "Tree", tsel)
	t.set_color("font_selected_color", "Tree", text)

	t.set_color("font_color", "TooltipLabel", text)
	t.set_stylebox("panel", "TooltipPanel", _flat(col("panel"), border, 3))
	return t


static func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		dark = bool(cfg.get_value("ui", "dark", true))


static func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)   # keep unrelated sections if any
	cfg.set_value("ui", "dark", dark)
	cfg.save(SETTINGS_PATH)
