shader_type canvas_item;

// 技能冷却阴影：圆形本体 + 自上而下消退
// ratio = 1 时整圆覆盖；ratio 减小，阴影从顶部开始消失，保留在下方。
uniform float ratio : hint_range(0.0, 1.0) = 1.0;
uniform vec4 shade_color : source_color = vec4(0.02, 0.015, 0.04, 0.78);

void fragment() {
	vec2 p = UV - vec2(0.5);
	if (length(p) > 0.5) {
		discard;
	}
	if (UV.y < 1.0 - ratio) {
		discard;
	}
	COLOR = shade_color;
}
