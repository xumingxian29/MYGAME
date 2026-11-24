shader_type canvas_item;

// 低血量红边。只在屏幕四边染色，中心完全透明。
// 用方形距离 max(|uv-0.5|) 而不是圆形距离：圆形会让四个角先亮，
// 看起来像"隧道视野"，而方形是四边均匀压边，更像屏幕本身在报警。
uniform float intensity : hint_range(0.0, 1.0) = 0.0;
// 软边宽度：从 edge = 1-softness 开始渐亮到边缘全亮
uniform float softness : hint_range(0.05, 0.95) = 0.38;
uniform vec4 tint : source_color = vec4(0.66, 0.05, 0.08, 1.0);
// 边缘最大不透明度上限。给到 1.0 时四边完全是实心红，会盖掉刚从屏外走进来的敌人，
// 玩家在最危险的时候反而看不见威胁；0.7 能压住画面但保留轮廓。
uniform float max_alpha : hint_range(0.2, 1.0) = 0.7;

void fragment() {
	vec2 d = abs(UV - vec2(0.5)) * 2.0;
	float edge = max(d.x, d.y);
	float v = smoothstep(1.0 - softness, 1.0, edge);
	COLOR = vec4(tint.rgb, v * intensity * max_alpha);
}
