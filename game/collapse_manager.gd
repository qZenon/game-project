extends Node

## Обрушение арены (21.12). Стартует через delay секунд после появления золотых подарков.
## Структуры обрушаются преимущественно от внешних краёв к центру с небольшой случайностью.
## Каждая обречённая структура мигает красным за warn_time секунд до падения.
## Центральная платформа и маяк не обрушаются: их нет в списке buildable_structures арены.

signal collapse_started
signal structure_collapsed(structure: Node2D, lost_gifts: int)

@export_range(0.0, 15.0, 0.5) var delay: float = 5.0
@export_range(0.5, 6.0, 0.1) var warn_time: float = 3.0
## За сколько секунд начинается обрушение всех структур (предупреждения идут друг за другом).
@export_range(10.0, 120.0, 1.0) var total_duration: float = 36.0
## Разброс порядка: 0 - строго от дальних к ближним, больше - больше перемешивания.
@export_range(0.0, 0.5, 0.01) var order_randomness: float = 0.12

var arena: Node
var gifts: Node

var running: bool = false
var collapsing: bool = false

var _queue: Array[Node2D] = []
var _next_index: int = 0
var _interval: float = 1.0
var _elapsed: float = 0.0
var _pending: Array[Dictionary] = []  # {"node": Node2D, "left": float}
var _label: Label
var _label_hide_timer: float = 0.0

func _ready() -> void:
    var canvas := CanvasLayer.new()
    canvas.name = "CollapseUI"
    canvas.layer = 70
    add_child(canvas)
    _label = Label.new()
    _label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    _label.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
    _label.offset_top = 36.0
    _label.offset_bottom = 90.0
    _label.add_theme_font_size_override("font_size", 34)
    _label.add_theme_color_override("font_color", Color("ffd84a"))
    _label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.9))
    _label.add_theme_constant_override("shadow_offset_x", 2)
    _label.add_theme_constant_override("shadow_offset_y", 2)
    _label.visible = false
    canvas.add_child(_label)

## Запускает отсчёт до обрушения.
func start() -> void:
    if running:
        return
    running = true
    collapsing = false
    _elapsed = 0.0
    _next_index = 0
    _pending.clear()
    _build_queue()
    _label.visible = true

## Останавливает обрушение (раунд завершён). Уже идущие предупреждения прекращаются.
func stop() -> void:
    running = false
    _label.visible = false
    for entry in _pending:
        var node: Node2D = entry["node"]
        if is_instance_valid(node):
            node.modulate = Color.WHITE
    _pending.clear()

func _build_queue() -> void:
    var keyed: Array[Dictionary] = []
    for structure in arena.buildable_structures:
        var noise := 1.0 + randf_range(-order_randomness, order_randomness)
        keyed.append({"node": structure, "key": structure.position.length() * noise})
    keyed.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["key"] > b["key"])
    _queue.clear()
    for entry in keyed:
        _queue.append(entry["node"])
    _interval = total_duration / float(maxi(1, _queue.size()))

func _process(delta: float) -> void:
    if not running:
        return
    _elapsed += delta

    if not collapsing:
        var remaining := delay - _elapsed
        if remaining > 0.0:
            _label.text = "ОБРУШЕНИЕ ЧЕРЕЗ %d" % ceili(remaining)
            return
        collapsing = true
        _elapsed = 0.0
        _label.text = "ОБРУШЕНИЕ!"
        _label_hide_timer = 2.5
        collapse_started.emit()

    if _label_hide_timer > 0.0:
        _label_hide_timer -= delta
        if _label_hide_timer <= 0.0:
            _label.visible = false

    while _next_index < _queue.size() and _elapsed >= float(_next_index) * _interval:
        var structure := _queue[_next_index]
        _next_index += 1
        if is_instance_valid(structure):
            _pending.append({"node": structure, "left": warn_time})

    for i in range(_pending.size() - 1, -1, -1):
        var entry := _pending[i]
        var node: Node2D = entry["node"]
        if not is_instance_valid(node):
            _pending.remove_at(i)
            continue
        entry["left"] = float(entry["left"]) - delta
        var left: float = entry["left"]
        if left <= 0.0:
            _pending.remove_at(i)
            _collapse(node)
        else:
            # Мигание ускоряется к моменту падения. Подарки лежат выше (z_index 10) и не перекрываются.
            var progress := 1.0 - left / warn_time
            var blink := 0.5 + 0.5 * sin(progress * progress * 40.0 + progress * 6.0)
            node.modulate = Color(1.0, 1.0, 1.0).lerp(Color(1.7, 0.4, 0.45), blink * (0.35 + 0.5 * progress))

func _collapse(structure: Node2D) -> void:
    var rects: Array = arena.call("remove_structure_support", structure)
    var lost := 0
    if gifts != null:
        lost = int(gifts.call("remove_gifts_in_rects", rects))
    structure_collapsed.emit(structure, lost)
    # Падение: платформа темнеет, уменьшается и исчезает.
    structure.modulate = Color(1.0, 0.45, 0.45)
    var tween := create_tween().set_parallel(true)
    tween.tween_property(structure, "modulate:a", 0.0, 0.4)
    tween.tween_property(structure, "scale", Vector2(0.8, 0.8), 0.4).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
    tween.chain().tween_callback(func() -> void:
        if is_instance_valid(structure):
            structure.queue_free())
