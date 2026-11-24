class_name UiKit
extends RefCounted

## HUD 与开始菜单共用的排版零件，保证字体、面板、描边风格一致。

## 内嵌字体，不用 SystemFont：Web 平台访问不到操作系统字体，SystemFont 会
## 静默退化成引擎内置的 OpenSans，中文全部变成方块。字体文件必须打进库里。
## 该文件是 Noto Sans SC 的子集（ASCII + GB2312 全表 + 项目文案），约 1.5MB。
const FONT_PATH: String = "res://assets/fonts/NotoSansSC-subset.otf"

static var _cached_font: Font


## 字体只加载一次。调用方签名保持返回 Font，Label / draw_string 都接受。
static func font() -> Font:
	if _cached_font == null:
		var loaded: Resource = load(FONT_PATH) if ResourceLoader.exists(FONT_PATH) else null
		if loaded is Font:
			_cached_font = loaded
		else:
			# 字体丢了也不能让 UI 建不出来：宁可显示方块，也要保证游戏能进
			push_warning("字体加载失败，退回引擎内置字体：%s" % FONT_PATH)
			_cached_font = ThemeDB.fallback_font
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
