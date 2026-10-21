extends Node

## Пункт 21.11: подготовка арены, фактический прогресс, советы и отсчёт.
##
## Порядок раунда: ПОДГОТОВКА (камера показывает арену целиком, структуры появляются по одной,
## затем подарки; игрок стоит, таймеры и враги ждут) -> ПРИБЛИЖЕНИЕ камеры к игроку ->
## ОТСЧЁТ «3, 2, 1, НАЧАЛИ!» -> ИГРА (21.11).
## 21.12: когда собраны все обычные подарки, они становятся золотыми, в центре появляется маяк,
## через 5 секунд начинается обрушение. Касание маяка завершает раунд.
## 21.13: после маяка загружается лобби следующего раунда (lobby.tscn), контекст забега
## (класс, враги, проклятия) берётся из RunState.
## Остальные системы (враги, таймеры) должны стартовать по сигналу round_started
## и до него проверять round_active.

signal preparation_finished
signal round_started
## Раунд завершён касанием маяка: сколько золотых подарков собрано из всех.
signal round_finished(golden_collected: int, golden_total: int)

enum Phase { PREPARING, ZOOMING, COUNTDOWN, PLAYING, FINISHED }

## Пауза между появлением соседних структур. Прогресс считается по реально появившимся
## структурам и подаркам, а не по таймеру.
@export_range(0.03, 0.6, 0.01) var structure_interval: float = 0.14
@export_range(1.0, 8.0, 0.1) var tip_interval: float = 3.2
@export_range(0.5, 6.0, 0.1) var banner_hold_time: float = 2.5
@export_range(0.3, 3.0, 0.1) var zoom_in_time: float = 1.3
@export_range(0.5, 2.0, 0.1) var countdown_step: float = 1.0
@export_range(0.0, 1.5, 0.05) var post_gift_hold: float = 0.4
## «РАУНД n / 16» над ареной. Тип этапа (враг/проклятие/улучшения) теперь показывает лобби (21.13),
## поэтому здесь он по умолчанию скрыт; «ФИНАЛЬНЫЙ РАУНД» показывается всегда.
@export var show_stage_type: bool = false

## Контекст забега для подбора советов. В _ready заполняется из RunState (21.13).
## Идентификаторы: класс "normal" / "teleporter"; враги "slash", "mimic", "operator";
## проклятия "displacement", "no_time_to_think", "closing_gap", "deep_cuts", "jackpot".
var run_context: Dictionary = {"class": "normal", "enemies": [], "curses": []}

var phase: Phase = Phase.PREPARING
## true только после «НАЧАЛИ!». Таймеры и враги не должны идти, пока это false.
var round_active: bool = false

const RUN := preload("res://game/run_state.gd")
const LOBBY_SCENE := "res://game/lobby.tscn"
const BEACON_SCRIPT := preload("res://game/beacon.gd")
const SLASH_SCRIPT := preload("res://game/enemy_slash.gd")
const COLLAPSE_SCRIPT := preload("res://game/collapse_manager.gd")
const PREVIEW_MARGIN := 90.0       # запас вокруг арены при обзоре, в пикселях мира
const PREVIEW_UI_RESERVE := 420.0  # высота экрана под баннер и панель подготовки
const PROGRESS_SPEED := 3.0  # как быстро полоса догоняет фактический прогресс (доля в секунду)
const FINAL_ROUND := 16

const SFX_PATHS := {
	"3": "res://audio/sfx/countdown_3.wav",
	"2": "res://audio/sfx/countdown_2.wav",
	"1": "res://audio/sfx/countdown_1.wav",
	"go": "res://audio/sfx/countdown_go.wav",
	"gold": "res://audio/sfx/gold_swap.wav",
	"beacon": "res://audio/sfx/beacon_touch.wav",
}

# Советы. Условие class/enemy/curse делает совет специальным; без условий - общий.
const TIPS: Array[Dictionary] = [
	{"id": "gen_gold", "text": "Когда собраны все обычные подарки, они становятся золотыми. Через 5 секунд начнётся обрушение."},
	{"id": "gen_beacon", "text": "Касание золотого маяка в центре мгновенно завершает раунд. Оставшиеся золотые подарки пропадут."},
	{"id": "gen_collapse_warn", "text": "Каждая обрушающаяся платформа предупреждает за 3 секунды. Успейте уйти."},
	{"id": "gen_collapse_dir", "text": "Обрушение идёт от внешних краёв к центру. Далёкие подарки лучше собирать раньше."},
	{"id": "gen_counted", "text": "Засчитываются только собранные подарки. Решите, когда идти к маяку."},
	{"id": "gen_currency", "text": "Золотые подарки нужны для улучшений, но пропадают, если забег заканчивается."},
	{"id": "gen_void", "text": "Потеряв опору, вы получаете 0,5 секунды, чтобы вернуться на платформу. Иначе — Пустота."},
	{"id": "cls_teleporter", "class": "teleporter", "text": "Телепортер: ЛКМ переносит в точку клика. Край платформы не корректируется, целиться за край опасно."},
	{"id": "enemy_slash", "enemy": "slash", "text": "Slash: разрез пройдёт через вашу позицию. У вас 1 секунда, чтобы сойти с линии."},
	{"id": "enemy_mimic", "enemy": "mimic", "text": "Mimic повторяет ваш путь с задержкой. Не возвращайтесь по собственным следам."},
	{"id": "enemy_operator", "enemy": "operator", "text": "Operator: когда он появится, полностью остановитесь до того, как индикатор станет красным."},
	{"id": "curse_displacement", "curse": "displacement", "text": "Displacement: раунд начнётся в случайной точке платформы. Сначала осмотритесь."},
	{"id": "curse_no_time", "curse": "no_time_to_think", "text": "No Time to Think: на реакцию у Operator остаётся вдвое меньше времени."},
	{"id": "curse_closing_gap", "curse": "closing_gap", "text": "Closing Gap: Mimic следует за вами с меньшей задержкой. Держите дистанцию."},
	{"id": "curse_deep_cuts", "curse": "deep_cuts", "text": "Deep Cuts: в каждой серии Slash больше разрезов."},
	{"id": "curse_jackpot", "curse": "jackpot", "text": "Jackpot: награда раунда с шансом 50% обнулится и с шансом 50% удвоится."},
]

var _arena: Node
var _gifts: Node
var _player: Node

var _structures: Array[Node2D] = []
var _prep_started := false
var _revealed := 0
var _reveal_timer := 0.0
var _gifts_spawned := false
var _hold_timer := 0.0
var _display_progress := 0.0
var _tip_timer := 0.0
var _banner_time := 0.0
var _count_value := 3
var _count_timer := 0.0
var _zoom_timer := 0.0
var _beacon: Node2D
var _collapse: Node
var _flash_rect: ColorRect
## Враги, выбранные в этом забеге. У каждого есть start() и stop().
var _enemies: Array[Node] = []

var _sfx: Dictionary = {}
var _canvas: CanvasLayer
var _banner_root: Control
var _prep_panel: PanelContainer
var _progress_bar: ProgressBar
var _percent_label: Label
var _tip_label: Label
var _count_label: Label

func _ready() -> void:
	_arena = get_parent()
	run_context = RUN.get_run_context()
	_gifts = get_node_or_null(^"../GiftManager")
	_player = get_node_or_null(^"../CharacterBody2D")
	_build_audio()
	_build_ui()
	_set_player_locked(true)
	if _gifts != null:
		_gifts.connect("all_gifts_collected", _on_normal_gifts_collected)
	_collapse = COLLAPSE_SCRIPT.new()
	_collapse.name = "CollapseManager"
	_collapse.set("arena", _arena)
	_collapse.set("gifts", _gifts)
	add_child(_collapse)
	_play_entry_flash()
	# Дети готовятся раньше родителя, а арена строится в её _ready - ждём её.
	if not _arena.is_node_ready():
		await _arena.ready
	_begin_preparation()

func _begin_preparation() -> void:
	_structures.clear()
	for structure in _arena.buildable_structures:
		_structures.append(structure)
	# Появление идёт от центра наружу; ветки растут одновременно.
	_structures.sort_custom(func(a: Node2D, b: Node2D) -> bool:
		return a.position.length_squared() < b.position.length_squared())
	for structure in _structures:
		structure.visible = false

	# Маяк создаётся здесь: родитель-арена к этому моменту уже закончил _ready.
	_beacon = BEACON_SCRIPT.new()
	_beacon.name = "GoldenBeacon"
	_beacon.set("player", _player)
	_arena.add_child(_beacon)
	_beacon.connect("touched", _on_beacon_touched)
	_spawn_enemies()

	_begin_camera_preview()
	var round_number: int = clampi(int(_arena.round_number), 1, FINAL_ROUND)
	_round_label_setup(round_number)
	_show_tip()
	_prep_started = true

## Пока арена создаётся, камера показывает её целиком.
func _begin_camera_preview() -> void:
	if _player == null or not _player.has_method("begin_camera_preview"):
		return
	var bounds := Rect2()
	var first := true
	for rect in _arena.placed_rects:
		bounds = rect if first else bounds.merge(rect)
		first = false
	bounds = bounds.grow(PREVIEW_MARGIN)
	var viewport_size := get_viewport().get_visible_rect().size
	var usable := Vector2(viewport_size.x, maxf(200.0, viewport_size.y - PREVIEW_UI_RESERVE))
	var fit := minf(usable.x / bounds.size.x, usable.y / bounds.size.y)
	var offset: Vector2 = _arena.to_global(bounds.get_center()) - _player.global_position
	# Арена чуть выше центра экрана: снизу панель подготовки выше, чем баннер сверху.
	offset.y += 40.0 / fit
	_player.call("begin_camera_preview", fit, offset)

func _process(delta: float) -> void:
	if not _prep_started:
		return
	_update_banner(delta)
	match phase:
		Phase.PREPARING:
			_process_preparing(delta)
			_update_progress_bar(delta)
		Phase.ZOOMING:
			_zoom_timer += delta
			if _zoom_timer >= zoom_in_time:
				_start_countdown()
		Phase.COUNTDOWN:
			_process_countdown(delta)

# ---------------------------------------------------------------- подготовка

func _process_preparing(delta: float) -> void:
	_tip_timer += delta
	if _tip_timer >= tip_interval:
		_tip_timer = 0.0
		_show_tip()

	if _revealed < _structures.size():
		_reveal_timer += delta
		while _reveal_timer >= structure_interval and _revealed < _structures.size():
			_reveal_timer -= structure_interval
			_reveal_structure(_structures[_revealed])
			_revealed += 1
		return

	if not _gifts_spawned:
		_gifts_spawned = true
		if _gifts != null:
			_gifts.call("spawn_gifts")
		return

	if _gift_progress() >= 1.0:
		_hold_timer += delta
		if _hold_timer >= post_gift_hold and _display_progress >= 0.999:
			_start_zoom_in()

func _reveal_structure(structure: Node2D) -> void:
	structure.visible = true
	structure.modulate.a = 0.0
	structure.scale = Vector2(0.9, 0.9)
	var tween := create_tween().set_parallel(true)
	tween.tween_property(structure, "modulate:a", 1.0, 0.25)
	tween.tween_property(structure, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _gift_progress() -> float:
	if _gifts == null:
		return 1.0
	return float(_gifts.call("get_spawn_progress"))

## Фактический прогресс: появившиеся структуры + доля появившихся подарков (один шаг на подарки).
func _actual_progress() -> float:
	if not _prep_started:
		return 0.0
	var total := float(_structures.size() + 1)
	var done := float(_revealed)
	if _gifts_spawned:
		done += _gift_progress()
	return clampf(done / total, 0.0, 1.0)

func _update_progress_bar(delta: float) -> void:
	_display_progress = minf(_actual_progress(), _display_progress + PROGRESS_SPEED * delta)
	_progress_bar.value = _display_progress * 100.0
	_percent_label.text = "%d%%" % roundi(_display_progress * 100.0)

# ---------------------------------------------------------------- советы

func _pick_tip() -> Dictionary:
	var enemies: Array = run_context.get("enemies", [])
	var curses: Array = run_context.get("curses", [])
	var specific: Array = []
	var general: Array = []
	for tip in TIPS:
		if tip.has("class"):
			if run_context.get("class", "normal") == tip["class"]:
				specific.append(tip)
		elif tip.has("enemy"):
			if enemies.has(tip["enemy"]):
				specific.append(tip)
		elif tip.has("curse"):
			if curses.has(tip["curse"]):
				specific.append(tip)
		else:
			general.append(tip)

	# Есть подходящие специальные советы - показываем только их, иначе общие.
	var pool: Array = specific if not specific.is_empty() else general
	var last: String = String(Engine.get_meta("last_prep_tip", ""))
	var alternatives := pool.filter(func(t: Dictionary) -> bool: return t["id"] != last)
	if not alternatives.is_empty():
		pool = alternatives
	var chosen: Dictionary = pool[randi() % pool.size()]
	Engine.set_meta("last_prep_tip", chosen["id"])
	return chosen

func _show_tip() -> void:
	var tip := _pick_tip()
	_tip_label.text = "СОВЕТ\n" + String(tip["text"])
	_tip_label.modulate.a = 0.0
	create_tween().tween_property(_tip_label, "modulate:a", 1.0, 0.3)

# ---------------------------------------------------------------- отсчёт

## Арена готова: панель подготовки уходит, камера приближается к игроку.
func _start_zoom_in() -> void:
	phase = Phase.ZOOMING
	_zoom_timer = 0.0
	var fade := create_tween()
	fade.tween_property(_prep_panel, "modulate:a", 0.0, 0.3)
	fade.tween_callback(func() -> void: _prep_panel.visible = false)
	preparation_finished.emit()
	if _player != null and _player.has_method("end_camera_preview"):
		_player.call("end_camera_preview", zoom_in_time)

func _start_countdown() -> void:
	phase = Phase.COUNTDOWN
	_count_value = 3
	_count_timer = 0.0
	_show_count(_count_value)

func _process_countdown(delta: float) -> void:
	_count_timer += delta
	if _count_timer < countdown_step:
		return
	_count_timer -= countdown_step
	_count_value -= 1
	if _count_value > 0:
		_show_count(_count_value)
	else:
		_go()

func _show_count(value: int) -> void:
	_count_label.text = str(value)
	_count_label.add_theme_color_override("font_color", Color("f4e4ff"))
	_flash_count_label(0.45)
	_play_sfx(str(value))

func _go() -> void:
	phase = Phase.PLAYING
	round_active = true
	_set_player_locked(false)
	_count_label.text = "НАЧАЛИ!"
	_count_label.add_theme_color_override("font_color", Color("f1d98a"))
	_flash_count_label(0.9)
	_play_sfx("go")
	round_started.emit()
	for enemy in _enemies:
		enemy.call("start")

# ---------------------------------------------------------------- золотые подарки, маяк, конец раунда (21.12)

## Все обычные подарки собраны: они становятся золотыми, появляется маяк, через 5 секунд обрушение.
func _on_normal_gifts_collected() -> void:
	if phase != Phase.PLAYING:
		return
	_gifts.call("convert_all_to_golden")
	_beacon.call("activate")
	_play_sfx("gold")
	_collapse.call("start")

## Касание маяка немедленно завершает раунд. Оставшиеся золотые подарки теряются,
## засчитываются только собранные. Затем загружается лобби следующего раунда.
func _on_beacon_touched() -> void:
	if phase != Phase.PLAYING:
		return
	phase = Phase.FINISHED
	round_active = false
	_collapse.call("stop")
	for enemy in _enemies:
		enemy.call("stop")
	_play_sfx("beacon")
	var golden_collected := 0
	var golden_total := 0
	if _gifts != null:
		golden_collected = int(_gifts.get("golden_collected"))
		golden_total = int(_gifts.get("golden_total"))
	# Собранные золотые подарки идут в баланс забега. License, Jackpot и Trip Coins добавит 21.15.
	RUN.add_golden_gifts(golden_collected)
	round_finished.emit(golden_collected, golden_total)

	_set_player_locked(true)
	_flash_rect.color.a = 0.0
	var tween := create_tween()
	tween.tween_property(_flash_rect, "color:a", 1.0, 0.25)
	tween.tween_callback(_load_next_round)

## Враги создаются по выбору в лобби (RunState) и стартуют вместе с раундом, по "НАЧАЛИ!".
func _spawn_enemies() -> void:
	_enemies.clear()
	if RUN.enemy_count("slash") > 0:
		var slash: Node2D = SLASH_SCRIPT.new()
		slash.name = "SlashEnemy"
		slash.set("arena", _arena)
		slash.set("player", _player)
		_arena.add_child(slash)
		_enemies.append(slash)

func _load_next_round() -> void:
	var next_round: int = int(_arena.round_number) + 1
	if next_round > FINAL_ROUND:
		# Экран победы появится в 21.16, пока возвращаем в главное меню.
		Engine.set_meta("nullscape_round", 1)
		get_tree().change_scene_to_file("res://menu/menu.tscn")
		return
	# Новое лобби начинается с золотой вспышки; заряды Second Chance восстанавливаются в RunState.
	Engine.set_meta("nullscape_gold_flash", true)
	RUN.enter_round_lobby(next_round)
	get_tree().change_scene_to_file(LOBBY_SCENE)

## Вспышка при входе в сцену раунда (остаётся на случай запуска арены сразу после золотого перехода).
func _play_entry_flash() -> void:
	if not Engine.has_meta("nullscape_gold_flash"):
		return
	Engine.remove_meta("nullscape_gold_flash")
	_flash_rect.color.a = 1.0
	create_tween().tween_property(_flash_rect, "color:a", 0.0, 0.6)

func _flash_count_label(duration: float) -> void:
	_count_label.visible = true
	_count_label.modulate.a = 1.0
	_count_label.pivot_offset = _count_label.size * 0.5
	_count_label.scale = Vector2(1.7, 1.7)
	var tween := create_tween().set_parallel(true)
	tween.tween_property(_count_label, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(_count_label, "modulate:a", 0.0, duration).set_delay(maxf(0.0, duration - 0.25))

func _set_player_locked(locked: bool) -> void:
	if _player != null and _player.has_method("set_controls_locked"):
		_player.call("set_controls_locked", locked)

# ---------------------------------------------------------------- звук

func _build_audio() -> void:
	for key in SFX_PATHS:
		var path: String = SFX_PATHS[key]
		if not ResourceLoader.exists(path):
			continue
		var player := AudioStreamPlayer.new()
		player.name = "Sfx_" + String(key)
		player.stream = load(path)
		player.volume_db = -4.0
		add_child(player)
		_sfx[key] = player

func _play_sfx(key: String) -> void:
	if _sfx.has(key):
		(_sfx[key] as AudioStreamPlayer).play()

# ---------------------------------------------------------------- интерфейс

func _make_label(font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.9))
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 2)
	return label

func _build_ui() -> void:
	_canvas = CanvasLayer.new()
	_canvas.name = "RoundUI"
	_canvas.layer = 60  # ниже счётчика подарков (90) и предупреждения о падении (100)
	add_child(_canvas)

	# Баннер «РАУНД n / 16» и тип этапа.
	_banner_root = Control.new()
	_banner_root.name = "RoundBanner"
	_banner_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas.add_child(_banner_root)

	var round_label := _make_label(56, Color("f4e4ff"))
	round_label.name = "RoundLabel"
	round_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	round_label.offset_top = 44.0
	round_label.offset_bottom = 120.0
	_banner_root.add_child(round_label)

	var stage_label := _make_label(26, Color("b8a1d0"))
	stage_label.name = "StageLabel"
	stage_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	stage_label.offset_top = 122.0
	stage_label.offset_bottom = 162.0
	_banner_root.add_child(stage_label)

	# Панель подготовки: заголовок, полоса прогресса, совет.
	_prep_panel = PanelContainer.new()
	_prep_panel.name = "PreparationPanel"
	_prep_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.03, 0.06, 0.08, 0.82)
	panel_style.border_color = Color("5b4a78")
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(6)
	panel_style.content_margin_left = 22.0
	panel_style.content_margin_right = 22.0
	panel_style.content_margin_top = 14.0
	panel_style.content_margin_bottom = 14.0
	_prep_panel.add_theme_stylebox_override("panel", panel_style)
	_prep_panel.anchor_left = 0.5
	_prep_panel.anchor_right = 0.5
	_prep_panel.anchor_top = 1.0
	_prep_panel.anchor_bottom = 1.0
	_prep_panel.offset_left = -380.0
	_prep_panel.offset_right = 380.0
	_prep_panel.offset_top = -216.0
	_prep_panel.offset_bottom = -30.0
	_prep_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_canvas.add_child(_prep_panel)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 10)
	_prep_panel.add_child(box)

	var header := HBoxContainer.new()
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(header)

	var title := Label.new()
	title.text = "ПОДГОТОВКА АРЕНЫ"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color("f1d98a"))
	header.add_child(title)

	_percent_label = Label.new()
	_percent_label.text = "0%"
	_percent_label.add_theme_font_size_override("font_size", 22)
	_percent_label.add_theme_color_override("font_color", Color("f4e4ff"))
	header.add_child(_percent_label)

	_progress_bar = ProgressBar.new()
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = 100.0
	_progress_bar.value = 0.0
	_progress_bar.show_percentage = false
	_progress_bar.custom_minimum_size = Vector2(0.0, 16.0)
	var bar_bg := StyleBoxFlat.new()
	bar_bg.bg_color = Color("11151d")
	bar_bg.set_corner_radius_all(4)
	var bar_fill := StyleBoxFlat.new()
	bar_fill.bg_color = Color("b8a1d0")
	bar_fill.set_corner_radius_all(4)
	_progress_bar.add_theme_stylebox_override("background", bar_bg)
	_progress_bar.add_theme_stylebox_override("fill", bar_fill)
	box.add_child(_progress_bar)

	_tip_label = Label.new()
	_tip_label.name = "TipLabel"
	_tip_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tip_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tip_label.custom_minimum_size = Vector2(0.0, 70.0)
	_tip_label.add_theme_font_size_override("font_size", 18)
	_tip_label.add_theme_color_override("font_color", Color("d9cbe6"))
	box.add_child(_tip_label)

	# Золотая вспышка перехода между раундами (поверх всего, не перехватывает мышь).
	var flash_canvas := CanvasLayer.new()
	flash_canvas.name = "TransitionFlash"
	flash_canvas.layer = 120
	add_child(flash_canvas)
	_flash_rect = ColorRect.new()
	_flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash_rect.color = Color(1.0, 0.85, 0.3, 0.0)
	_flash_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	flash_canvas.add_child(_flash_rect)

	# Отсчёт по центру экрана.
	_count_label = _make_label(150, Color("f4e4ff"))
	_count_label.name = "CountdownLabel"
	_count_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_count_label.visible = false
	_canvas.add_child(_count_label)

func _round_label_setup(round_number: int) -> void:
	var round_label := _banner_root.get_node("RoundLabel") as Label
	var stage_label := _banner_root.get_node("StageLabel") as Label
	round_label.text = "РАУНД %d / %d" % [round_number, FINAL_ROUND]
	stage_label.text = _stage_type(round_number) if (show_stage_type or round_number == FINAL_ROUND) else ""
	_banner_time = 0.0
	_banner_root.modulate.a = 1.0
	_banner_root.visible = true

func _stage_type(round_number: int) -> String:
	return RUN.stage_name(round_number)

func _update_banner(delta: float) -> void:
	if not _banner_root.visible:
		return
	_banner_time += delta
	if _banner_time >= banner_hold_time:
		_banner_root.modulate.a = clampf(1.0 - (_banner_time - banner_hold_time) / 0.5, 0.0, 1.0)
		if _banner_root.modulate.a <= 0.0:
			_banner_root.visible = false
