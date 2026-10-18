shader_type canvas_item;



uniform vec2 speed = vec2(0.02, 0.0); 

void fragment() {
    // Встроенная функция abs() зеркально отражает текстуру на стыках, убирая видимые швы
    vec2 mirrored_uv = abs(mod(UV + (speed * TIME) + 1.0, 2.0) - 1.0);
    
    COLOR = texture(TEXTURE, mirrored_uv);
}