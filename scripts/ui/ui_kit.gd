class_name UiKit
extends RefCounted

## HUD 与开始菜单共用的排版零件，保证字体、面板、描边风格一致。

const FONT_NAMES: PackedStringArray = ["Microsoft YaHei", "SimHei", "Segoe UI"]

static var _cached_font: SystemFont


## 系统字体只建一次：中文用微软雅黑，缺失时退回黑体 / Segoe UI
static func font() -> SystemFont:
	if _cached_font == null:
		_cached_font = SystemFont.new()
		_cached_font.font_names = FONT_NAMES
	return _cached_font


static func label(text: String, size: int, color: Color) -> Label:
	var node := Label.new()
	node.text = text
	node.add_theme_font_override("font", font())
	node.add_theme_font_size_override("font_size", size)
	node.add_theme_color_override("font_color", color)
	node.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	node.add_theme_constant_override("outline_size", 4)
	return node


## 弹窗面板：深底 + 圆角 + 彩色描边
static func panel_style(border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.09, 0.13, 1.0)
	style.set_corner_radius_all(12)
	style.set_content_margin_all(28)
	style.border_color = border
	style.set_border_width_all(2)
	return style


static func flat(bg: Color, border: Color, radius: int, width: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.set_corner_radius_all(radius)
	style.border_color = border
	style.set_border_width_all(width)
	return style


static func divider() -> ColorRect:
	var line := ColorRect.new()
	line.color = Color(1.0, 1.0, 1.0, 0.14)
	line.custom_minimum_size = Vector2(0, 1)
	return line
