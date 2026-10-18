extends CharacterBody2D

signal void_death

## Базовая скорость персонажа. Улучшения скорости будут менять это значение.
@export var SPEED: float = 75.0
@export_range(0.1, 2.0, 0.05) var void_rescue_time: float = 0.5
## Временно: после смерти игрок возвращается в главное меню через эту паузу (чтобы успеть увидеть надпись).
@export_range(0.0, 5.0, 0.1) var death_menu_delay: float = 1.5
const MAIN_MENU_SCENE := "res://menu/menu.tscn"

var kda: bool = true
var hp: int = 100
var stm: float = 100.0
var fall_time_left: float = 0.0
var is_falling_into_void: bool = false
var is_void_dead: bool = false

@onready var anim: AnimatedSprite2D = $AnimatedSprite2D
@onready var camera: Camera2D = $Camera2D

const MIN_CAMERA_ZOOM: float = 2.0
const MAX_CAMERA_ZOOM: float = 5.5
const CAMERA_ZOOM_STEP: float = 0.25
const CAMERA_ZOOM_SMOOTHING: float = 10.0
var target_camera_zoom: float = 3.5

var void_overlay: ColorRect
var fall_label: Label
var void_death_label: Label
var void_overlay_material: ShaderMaterial

func _ready() -> void:
    target_camera_zoom = camera.zoom.x
    _create_void_ui()

func _physics_process(delta: float) -> void:
    if is_void_dead:
        velocity = Vector2.ZERO
        return

    var input_direction := Input.get_vector("left", "right", "up", "down")
    velocity = input_direction * SPEED

    if kda:
        if input_direction.length_squared() > 0.0:
            anim.play("run")
        else:
            anim.play("idle")

        if input_direction.x < 0.0:
            anim.flip_h = true
        elif input_direction.x > 0.0:
            anim.flip_h = false

    move_and_slide()
    _update_void_state(delta)

func _process(delta: float) -> void:
    var zoom_value := lerpf(camera.zoom.x, target_camera_zoom, 1.0 - exp(-CAMERA_ZOOM_SMOOTHING * delta))
    camera.zoom = Vector2(zoom_value, zoom_value)

func _unhandled_input(event: InputEvent) -> void:
    if is_void_dead:
        return
    if event is InputEventMouseButton and event.pressed:
        if event.button_index == MOUSE_BUTTON_WHEEL_UP:
            target_camera_zoom = minf(target_camera_zoom + CAMERA_ZOOM_STEP, MAX_CAMERA_ZOOM)
        elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
            target_camera_zoom = maxf(target_camera_zoom - CAMERA_ZOOM_STEP, MIN_CAMERA_ZOOM)

func _update_void_state(delta: float) -> void:
    var arena := get_parent()
    if arena == null or not arena.has_method("is_position_supported"):
        return

    var supported: bool = arena.call("is_position_supported", global_position)
    if supported:
        if is_falling_into_void:
            is_falling_into_void = false
            fall_time_left = 0.0
            _set_fall_warning(false)
        return

    if not is_falling_into_void:
        is_falling_into_void = true
        fall_time_left = void_rescue_time
        _set_fall_warning(true)

    fall_time_left = maxf(0.0, fall_time_left - delta)
    if fall_time_left <= 0.0:
        _trigger_void_death()

func _create_void_ui() -> void:
    var canvas := CanvasLayer.new()
    canvas.name = "VoidWarningUI"
    canvas.layer = 100
    add_child(canvas)

    void_overlay = ColorRect.new()
    void_overlay.name = "VoidEdgeWarning"
    void_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    void_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
    void_overlay.color = Color.WHITE
    var edge_shader := Shader.new()
    edge_shader.code = """
shader_type canvas_item;
uniform float warning_amount : hint_range(0.0, 1.0) = 0.0;
void fragment() {
    float edge_distance = min(min(UV.x, 1.0 - UV.x), min(UV.y, 1.0 - UV.y));
    float edge_glow = 1.0 - smoothstep(0.0, 0.24, edge_distance);
    float alpha = edge_glow * warning_amount * 0.58;
    COLOR = vec4(0.95, 0.025, 0.08, alpha);
}
"""
    void_overlay_material = ShaderMaterial.new()
    void_overlay_material.shader = edge_shader
    void_overlay_material.set_shader_parameter("warning_amount", 0.0)
    void_overlay.material = void_overlay_material
    canvas.add_child(void_overlay)

    fall_label = Label.new()
    fall_label.name = "FallWarningText"
    fall_label.text = "ПАДЕНИЕ!"
    fall_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    fall_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    fall_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
    fall_label.position = Vector2(-150.0, 42.0)
    fall_label.size = Vector2(300.0, 55.0)
    fall_label.add_theme_font_size_override("font_size", 30)
    fall_label.add_theme_color_override("font_color", Color("ff4656"))
    fall_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
    fall_label.add_theme_constant_override("shadow_offset_x", 2)
    fall_label.add_theme_constant_override("shadow_offset_y", 2)
    fall_label.visible = false
    canvas.add_child(fall_label)

    void_death_label = Label.new()
    void_death_label.name = "VoidDeathText"
    void_death_label.text = "VOID DEATH\nЗАБЕГ ОКОНЧЕН"
    void_death_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    void_death_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    void_death_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
    void_death_label.position = Vector2(-260.0, -65.0)
    void_death_label.size = Vector2(520.0, 130.0)
    void_death_label.add_theme_font_size_override("font_size", 38)
    void_death_label.add_theme_color_override("font_color", Color("ff4656"))
    void_death_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 1))
    void_death_label.add_theme_constant_override("shadow_offset_x", 3)
    void_death_label.add_theme_constant_override("shadow_offset_y", 3)
    void_death_label.visible = false
    canvas.add_child(void_death_label)

func _set_fall_warning(enabled: bool) -> void:
    fall_label.visible = enabled and not is_void_dead
    void_overlay_material.set_shader_parameter("warning_amount", 1.0 if enabled else 0.0)
    if enabled:
        anim.modulate = Color("ffb0b0")
    else:
        anim.modulate = Color.WHITE

func _trigger_void_death() -> void:
    if is_void_dead:
        return
    is_void_dead = true
    is_falling_into_void = false
    velocity = Vector2.ZERO
    fall_label.visible = false
    void_overlay_material.set_shader_parameter("warning_amount", 1.0)
    void_death_label.visible = true
    anim.modulate = Color("ff4656")
    void_death.emit()
    _return_to_main_menu()

func _return_to_main_menu() -> void:
    await get_tree().create_timer(death_menu_delay).timeout
    if is_inside_tree():
        get_tree().paused = false
        get_tree().change_scene_to_file(MAIN_MENU_SCENE)
