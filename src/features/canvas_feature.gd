class_name CanvasFeature
extends Feature
## M30 reference image ("canvas"): a raster image placed on a plane, drawn
## under sketch geometry for trace-over work. The image BYTES live in the
## document (base64 in .ecad) so files stay portable; placement is a
## center (plane uv, mm) + width (mm, height follows the aspect) + rotation
## about the center. Canvases are timeline features (undo, suppress,
## browser row) but never geometry: no snap, no profiles, no solver.

var plane := "XY"                 # origin-plane name or plane feature id
var image_data := PackedByteArray()
var image_format := "png"         # "png" | "jpg"
var center := Vector2.ZERO        # uv on the plane, mm
var width_mm := 100.0
var rotation := 0.0               # radians about center, in-plane
var opacity := 0.6
var locked := false

var _tex: ImageTexture = null
var _tex_aspect := 1.0


func kind() -> String:
	return "canvas"


func plane_transform() -> Transform3D:
	if SketchFeature.PLANES.has(plane):
		return Transform3D(SketchFeature.plane_basis(plane), Vector3.ZERO)
	var d := document()
	return d.plane_transform(plane) if d != null else Transform3D.IDENTITY


func plane_label() -> String:
	var d := document()
	return d.plane_label(plane) if d != null else plane


## Decoded texture (cached). Null when the bytes don't decode.
func texture() -> ImageTexture:
	if _tex != null:
		return _tex
	var img := Image.new()
	var err := ERR_INVALID_DATA
	if image_format == "jpg":
		err = img.load_jpg_from_buffer(image_data)
	else:
		err = img.load_png_from_buffer(image_data)
	if err != OK:
		return null
	_tex = ImageTexture.create_from_image(img)
	_tex_aspect = float(img.get_height()) / maxf(float(img.get_width()), 1.0)
	return _tex


func height_mm() -> float:
	if _tex == null:
		texture()
	return width_mm * _tex_aspect


## The image format the bytes actually are, sniffed from their magic
## number — "png", "jpg", or "" for anything else. Trusting the file
## extension let renamed garbage reach the engine decoders, which spam
## the console with driver-level errors before failing (QA §M30.8).
static func sniff_format(bytes: PackedByteArray) -> String:
	if bytes.size() >= 8 and bytes[0] == 0x89 and bytes[1] == 0x50 \
			and bytes[2] == 0x4E and bytes[3] == 0x47:
		return "png"
	if bytes.size() >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 \
			and bytes[2] == 0xFF:
		return "jpg"
	return ""


## Load bytes from a file path; "" on success, else the reason.
func load_file(path: String) -> String:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return "cannot read %s" % path
	var fmt := sniff_format(bytes)
	if fmt == "":
		return "not a PNG/JPEG image: %s" % path
	image_format = fmt
	image_data = bytes
	_tex = null
	if texture() == null:
		image_data = PackedByteArray()
		return "not a decodable PNG/JPEG: %s" % path
	return ""


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["plane"] = plane
	d["format"] = image_format
	d["data"] = Marshalls.raw_to_base64(image_data)
	d["center"] = [center.x, center.y]
	d["width_mm"] = width_mm
	d["rotation"] = rotation
	d["opacity"] = opacity
	d["locked"] = locked
	return d


static func from_dict(d: Dictionary) -> CanvasFeature:
	var f := CanvasFeature.new()
	f._read_base(d)
	f.plane = String(d.get("plane", "XY"))
	f.image_format = String(d.get("format", "png"))
	f.image_data = Marshalls.base64_to_raw(String(d.get("data", "")))
	var c: Array = d.get("center", [0, 0])
	f.center = Vector2(float(c[0]), float(c[1]))
	f.width_mm = float(d.get("width_mm", 100.0))
	f.rotation = float(d.get("rotation", 0.0))
	f.opacity = float(d.get("opacity", 0.6))
	f.locked = bool(d.get("locked", false))
	return f
