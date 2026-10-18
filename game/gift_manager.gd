extends Node2D

## Пункт 21.10: подарки и их сбор.
## Расставляет подарки по прямым линиям, которые рассчитывает арена (кроме центральной
## платформы), обрабатывает сбор и показывает счётчик «собрано / всего».
## Золотые подарки, маяк и обрушение (21.12) подключаются к сигналам и флагу "golden".

signal gift_collected(collected: int, total: int)
## Собраны все обычные подарки: пора заменить их золотыми (21.12).
signal all_gifts_collected
signal golden_gifts_spawned(total: int)
signal golden_gift_collected(collected: int, total: int)
signal all_golden_gifts_collected

const PICKUP_RADIUS := 17.0
const SPAWN_ANIM_TIME := 0.3
const SPAWN_STAGGER := 0.6
const GOLDEN_STAGGER := 0.5
const POP_TIME := 0.38

const GIFT_PINK := Color("d65db1")
const GIFT_PINK_DARK := Color("5e2552")
const GIFT_RIBBON := Color("f4e4ff")
const GIFT_GOLD := Color("e8c04a")
const GIFT_GOLD_DARK := Color("6b5314")
const GIFT_GOLD_RIBBON := Color("fff4b8")

## Подарки появляются после подготовки арены: их запускает RoundController.
@export var auto_spawn: bool = false
@export var player_path: NodePath = ^"../CharacterBody2D"

var collected_count: int = 0   # собрано обычных подарков
var total_count: int = 0       # всего обычных подарков в раунде
var golden_phase: bool = false
var golden_collected: int = 0  # собрано золотых подарков
var golden_total: int = 0

# Каждый подарок: {"position": Vector2, "phase": float, "spawn_at": float, "golden": bool}
var gifts: Array[Dictionary] = []
# Короткие эффекты сбора: {"position": Vector2, "age": float, "golden": bool}
var pops: Array[Dictionary] = []

var _original_points: Array[Vector2] = []  # места, где лежали обычные подарки: на них появятся золотые
var _time: float = 0.0
var _player: Node2D
var _hud_panel: PanelContainer
var _hud_label: Label

func _ready() -> void:
	z_index = 10  # выше платформ, ниже персонажа (у него z_index = 100)
	_create_hud()
	_update_hud()
	if not auto_spawn:
		return
	# Дочерние узлы готовы раньше родителя, а арена генерируется в её _ready.
	var arena := get_parent()
	if not arena.is_node_ready():
		await arena.ready
	spawn_gifts()

## Расставляет подарки текущего раунда арены (число и линии задаёт арена). Счётчик сбрасывается.
func spawn_gifts() -> void:
	clear_gifts()
	var arena := get_parent()
	if arena == null or not arena.has_method("get_gift_points"):
		push_warning("GiftManager: у родителя нет get_gift_points()")
		return

	var points: Array = arena.call("get_gift_points")
	for point in points:
		gifts.append({
			"position": point,
			"phase": randf() * TAU,
			"spawn_at": _time + randf() * SPAWN_STAGGER,
			"golden": false,
		})
	total_count = gifts.size()
	collected_count = 0
	_original_points.clear()
	for gift in gifts:
		_original_points.append(gift["position"])
	_hud_panel.visible = true
	_update_hud()

## Доля подарков, уже полностью появившихся на карте (0..1). Нужна полосе подготовки арены.
func get_spawn_progress() -> float:
	if gifts.is_empty():
		return 1.0
	var appeared := 0
	for gift in gifts:
		if float(gift["spawn_at"]) + SPAWN_ANIM_TIME <= _time:
			appeared += 1
	return float(appeared) / float(gifts.size())

func clear_gifts() -> void:
	gifts.clear()
	pops.clear()
	total_count = 0
	collected_count = 0
	golden_phase = false
	golden_total = 0
	golden_collected = 0
	_update_hud()

func remaining_count() -> int:
	return gifts.size()

## Ближайший оставшийся подарок (для Gift Radar). Возвращает локальные координаты или null.
func get_nearest_gift_position(from_global: Vector2) -> Variant:
	var from_local := to_local(from_global)
	var best: Variant = null
	var best_distance := INF
	for gift in gifts:
		var distance := from_local.distance_squared_to(gift["position"])
		if distance < best_distance:
			best_distance = distance
			best = gift["position"]
	return best

## Заменяет собранные обычные подарки золотыми: на тех же местах, на которых лежали обычные.
## Вызывается, когда собраны все обычные подарки.
func convert_all_to_golden() -> void:
	golden_phase = true
	gifts.clear()
	for point in _original_points:
		gifts.append({
			"position": point,
			"phase": randf() * TAU,
			"spawn_at": _time + randf() * GOLDEN_STAGGER,
			"golden": true,
		})
	golden_total = gifts.size()
	golden_collected = 0
	_update_hud()
	_flash_hud()
	golden_gifts_spawned.emit(golden_total)

## Подарки на обрушившейся структуре пропадают вместе с ней (rect - в локальных координатах арены).
## Возвращает, сколько подарков потеряно.
func remove_gifts_in_rect(rect: Rect2) -> int:
	var lost := 0
	for i in range(gifts.size() - 1, -1, -1):
		if rect.has_point(gifts[i]["position"]):
			gifts.remove_at(i)
			lost += 1
	return lost

## То же для структуры из нескольких прямоугольников (например, "плюс"): подарки теряются только на ней самой.
func remove_gifts_in_rects(rects: Array) -> int:
	var lost := 0
	for rect in rects:
		lost += remove_gifts_in_rect(rect)
	return lost

func _process(delta: float) -> void:
	_time += delta
	for i in range(pops.size() - 1, -1, -1):
		pops[i]["age"] += delta
		if pops[i]["age"] >= POP_TIME:
			pops.remove_at(i)
	queue_redraw()

func _physics_process(_delta: float) -> void:
	if gifts.is_empty():
		return
	if _player == null or not is_instance_valid(_player):
		_player = get_node_or_null(player_path) as Node2D
		if _player == null:
			return
	if _player.get("is_void_dead") == true:
		return

	var player_local := to_local(_player.global_position)
	var radius_sq := PICKUP_RADIUS * PICKUP_RADIUS
	for i in range(gifts.size() - 1, -1, -1):
		var gift := gifts[i]
		if gift["spawn_at"] > _time:
			continue  # ещё не появился на экране
		if player_local.distance_squared_to(gift["position"]) <= radius_sq:
			_collect(i)

func _collect(index: int) -> void:
	var gift := gifts[index]
	pops.append({"position": gift["position"], "age": 0.0, "golden": gift["golden"]})
	gifts.remove_at(index)
	var was_golden: bool = gift["golden"]
	if was_golden:
		golden_collected += 1
	else:
		collected_count += 1
	_update_hud()
	_flash_hud()
	if was_golden:
		golden_gift_collected.emit(golden_collected, golden_total)
	else:
		gift_collected.emit(collected_count, total_count)
	if gifts.is_empty():
		if golden_phase:
			all_golden_gifts_collected.emit()
		elif total_count > 0:
			all_gifts_collected.emit()

# ---------------------------------------------------------------- отрисовка

func _spawn_scale(gift: Dictionary) -> float:
	var t := clampf((_time - float(gift["spawn_at"])) / SPAWN_ANIM_TIME, 0.0, 1.0)
	# easeOutBack: небольшой «выскок» при появлении
	var c1 := 1.70158
	var c3 := c1 + 1.0
	return 1.0 + c3 * pow(t - 1.0, 3.0) + c1 * pow(t - 1.0, 2.0) if t > 0.0 else 0.0

func _draw() -> void:
	for gift in gifts:
		var s := _spawn_scale(gift)
		if s <= 0.0:
			continue
		var golden: bool = gift["golden"]
		var body := GIFT_GOLD if golden else GIFT_PINK
		var edge := GIFT_GOLD_DARK if golden else GIFT_PINK_DARK
		var ribbon := GIFT_GOLD_RIBBON if golden else GIFT_RIBBON
		var bob := sin(_time * 2.4 + float(gift["phase"])) * 1.6

		draw_set_transform(gift["position"], 0.0, Vector2(s, s))
		# мягкое свечение и тень на поверхности
		draw_circle(Vector2(0.0, bob), 11.0, Color(body, 0.16))
		draw_rect(Rect2(Vector2(-6.0, 5.0), Vector2(12.0, 3.0)), Color(0.0, 0.0, 0.0, 0.35))
		# коробка с лентой, вид строго сверху
		var box := Rect2(Vector2(-6.0, bob - 6.0), Vector2(12.0, 12.0))
		draw_rect(box, body)
		draw_rect(box, edge, false, 1.5)
		draw_rect(Rect2(Vector2(-1.3, bob - 6.0), Vector2(2.6, 12.0)), ribbon)
		draw_rect(Rect2(Vector2(-6.0, bob - 1.3), Vector2(12.0, 2.6)), ribbon)
		draw_circle(Vector2(0.0, bob), 2.4, ribbon)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	for pop in pops:
		var t: float = pop["age"] / POP_TIME
		var color := GIFT_GOLD_RIBBON if pop["golden"] else GIFT_RIBBON
		var radius := 6.0 + 16.0 * t
		var alpha := 1.0 - t
		draw_arc(pop["position"], radius, 0.0, TAU, 24, Color(color, alpha), 2.0)
		for k in range(8):
			var angle := TAU * float(k) / 8.0
			var direction := Vector2(cos(angle), sin(angle))
			draw_line(pop["position"] + direction * (radius * 0.5), pop["position"] + direction * (radius * 0.9), Color(color, alpha), 1.5)

# ---------------------------------------------------------------- интерфейс

func _create_hud() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "GiftHUD"
	canvas.layer = 90  # ниже предупреждений о падении (слой 100)
	add_child(canvas)

	_hud_panel = PanelContainer.new()
	_hud_panel.name = "GiftCounter"
	_hud_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.03, 0.06, 0.08, 0.8)
	style.border_color = Color("5b4a78")
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.content_margin_left = 16.0
	style.content_margin_right = 16.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 8.0
	_hud_panel.add_theme_stylebox_override("panel", style)
	_hud_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT, Control.PRESET_MODE_MINSIZE, 24)
	_hud_panel.visible = false  # покажется, когда подарки появятся на карте
	canvas.add_child(_hud_panel)

	_hud_label = Label.new()
	_hud_label.name = "GiftCounterLabel"
	_hud_label.add_theme_font_size_override("font_size", 26)
	_hud_label.add_theme_color_override("font_color", Color("f1d98a"))
	_hud_label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.9))
	_hud_label.add_theme_constant_override("shadow_offset_x", 2)
	_hud_label.add_theme_constant_override("shadow_offset_y", 2)
	_hud_panel.add_child(_hud_label)

func _update_hud() -> void:
	if _hud_label == null:
		return
	if golden_phase:
		_hud_label.text = "ЗОЛОТЫЕ ПОДАРКИ  %d / %d" % [golden_collected, golden_total]
		_hud_label.add_theme_color_override("font_color", Color("ffd84a"))
	else:
		_hud_label.text = "ПОДАРКИ  %d / %d" % [collected_count, total_count]
		_hud_label.add_theme_color_override("font_color", Color("f1d98a"))

func _flash_hud() -> void:
	if _hud_panel == null:
		return
	_hud_panel.modulate = Color(1.7, 1.5, 0.9)
	var tween := create_tween()
	tween.tween_property(_hud_panel, "modulate", Color.WHITE, 0.25)
