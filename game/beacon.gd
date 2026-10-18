extends Node2D

## Золотой маяк в центре арены (21.12). Появляется, когда подарки становятся золотыми.
## Касание завершает раунд: маяк отправляет сигнал touched.

signal touched

const GOLD := Color("ffd84a")
const GOLD_LIGHT := Color("fff4b8")
const GOLD_DARK := Color("7a5a12")
const APPEAR_TIME := 0.6

@export var touch_radius: float = 26.0

var player: Node2D
var active: bool = false

var _time: float = 0.0
var _appear: float = 0.0

func _ready() -> void:
    z_index = 6  # выше платформ и метки центра, ниже подарков (10) и персонажа (100)
    visible = false

func activate() -> void:
    active = true
    visible = true
    _appear = 0.0

func deactivate() -> void:
    active = false

func _process(delta: float) -> void:
    if not visible:
        return
    _time += delta
    _appear = minf(1.0, _appear + delta / APPEAR_TIME)
    queue_redraw()

func _physics_process(_delta: float) -> void:
    if not active or _appear < 1.0 or player == null or not is_instance_valid(player):
        return
    if player.get("is_void_dead") == true:
        return
    if player.global_position.distance_to(global_position) <= touch_radius:
        active = false
        touched.emit()

func _draw() -> void:
    # easeOutBack: маяк чуть «выскакивает» при появлении
    var c1 := 1.70158
    var c3 := c1 + 1.0
    var s := 1.0 + c3 * pow(_appear - 1.0, 3.0) + c1 * pow(_appear - 1.0, 2.0)
    if s <= 0.0:
        return
    var pulse := 0.5 + 0.5 * sin(_time * 3.0)

    # свечение и вращающиеся лучи
    draw_circle(Vector2.ZERO, 54.0 * s, Color(GOLD, 0.08 + 0.05 * pulse))
    draw_circle(Vector2.ZERO, 38.0 * s, Color(GOLD, 0.14 + 0.07 * pulse))
    for k in range(8):
        var angle := _time * 0.8 + TAU * float(k) / 8.0
        var direction := Vector2(cos(angle), sin(angle))
        draw_line(direction * 24.0 * s, direction * (36.0 + 6.0 * pulse) * s, Color(GOLD_LIGHT, 0.55), 2.0)

    # корпус: ромб в кольце
    draw_arc(Vector2.ZERO, 26.0 * s, 0.0, TAU, 32, Color(GOLD, 0.9), 2.5)
    var outer := PackedVector2Array([Vector2(0, -20) * s, Vector2(15, 0) * s, Vector2(0, 20) * s, Vector2(-15, 0) * s])
    draw_colored_polygon(outer, GOLD_DARK)
    var inner := PackedVector2Array([Vector2(0, -16) * s, Vector2(11, 0) * s, Vector2(0, 16) * s, Vector2(-11, 0) * s])
    draw_colored_polygon(inner, GOLD)
    var core := PackedVector2Array([Vector2(0, -8) * s, Vector2(5, 0) * s, Vector2(0, 8) * s, Vector2(-5, 0) * s])
    draw_colored_polygon(core, GOLD_LIGHT)
