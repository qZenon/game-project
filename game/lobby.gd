extends Node2D

## Пункт 21.13: лобби между раундами, пьедесталы и последовательность раундов.
##
## Забег: меню -> лобби 1 -> раунд 1 (арена) -> маяк -> лобби 2 -> раунд 2 -> ... -> раунд 16.
## Тип лобби задаёт номер раунда (RunState.stage_of): враг, проклятие, улучшения или финал.
## Игрок свободно ходит по платформе. Рядом с пьедесталом автоматически показывается его описание,
## ближайший пьедестал подсвечивается тонким контуром, F выбирает / покупает / продолжает.
##
## Враги, проклятия и улучшения здесь только записываются в RunState; их эффекты - 21.14 и 21.15.
## Арену загружает game.tscn: номер раунда ей передаётся через Engine meta "nullscape_round",
## потому что исправленный arena_generator.gd менять нельзя.

const RUN := preload("res://game/run_state.gd")
const PEDESTAL := preload("res://game/pedestal.gd")
const GAME_SCENE := "res://game/game.tscn"

const TILE_SIZE := 42.0
const COLS := 15
const ROWS := 9
const PEDESTAL_ROW_Y := -2.0 * TILE_SIZE
const SPAWN_POSITION := Vector2(0.0, TILE_SIZE)
## Пьедестал считается ближайшим только в этом радиусе: здесь показывается информация и работает F.
const ACTIVATION_RADIUS := 56.0
const FADE_TIME := 0.3

const PLATFORM_COLOR := Color("11151d")
const OUTLINE_COLOR := Color("343447")
const RIM_COLOR := Color("080b11")
const TILE_GAP := 1.5
const TILE_LIGHT_VARIATION := [Color("c1acd7"), Color("a994c2"), Color("b5a0ca"), Color("a18db8")]
const TILE_DARK := Color("11121a")

const ENEMY_COLOR := Color("d65db1")
const CURSE_COLOR := Color("9b6bff")
const UPGRADE_COLOR := Color("4fd1c5")
const GOLD := Color("ffd84a")
const TEXT_COLOR := Color("f4e4ff")
const ERROR_COLOR := Color("ff6b7a")

## Пауза между выбором врага/проклятия и началом раунда: успеть прочитать уведомление.
@export_range(0.3, 4.0, 0.1) var advance_delay: float = 1.5
@export_range(0.5, 6.0, 0.1) var banner_hold_time: float = 2.5
@export_range(1.0, 6.0, 0.1) var toast_time: float = 2.6

## Опора под ногами (как у арены): по ней персонаж определяет падение в Пустоту.
var placed_rects: Array[Rect2] = []

var _player: Node2D
var _pedestals: Array = []
var _nearest = null
var _leaving: bool = false

var _banner_root: Control
var _round_label: Label
var _stage_label: Label
var _banner_time: float = 0.0
var _hud_round: Label
var _hud_gold: Label
var _info_panel: PanelContainer
var _info_title: Label
var _info_desc: Label
var _info_detail: Label
var _info_prompt: Label
var _toast_label: Label
var _toast_tween: Tween
var _fade_rect: ColorRect
var _flash_rect: ColorRect

func _ready() -> void:
    RUN.ensure_input_actions()
    var half := Vector2(float(COLS), float(ROWS)) * TILE_SIZE * 0.5
    placed_rects.append(Rect2(-half, half * 2.0))
    _create_background()
    _player = get_node_or_null("CharacterBody2D") as Node2D
    if _player != null:
        _player.position = SPAWN_POSITION
    _build_pedestals()
    _build_ui()
    _show_banner()
    _update_hud()
    _play_entry_flash()
    queue_redraw()

## Совпадает с методом арены: персонаж спрашивает у родителя, есть ли под ним опора.
func is_position_supported(world_position: Vector2) -> bool:
    var local_position := to_local(world_position)
    for rect in placed_rects:
        if rect.has_point(local_position):
            return true
    return false

# ---------------------------------------------------------------- платформа

func _create_background() -> void:
    var background := ColorRect.new()
    background.name = "LobbyVoidBackground"
    background.color = Color("061719")
    background.position = Vector2(-5000.0, -5000.0)
    background.size = Vector2(10000.0, 10000.0)
    background.z_index = -100
    add_child(background)

## Платформа лобби в стиле арены: шахматка из тёмных и лиловых клеток, тёмная окантовка.
func _draw() -> void:
    if placed_rects.is_empty():
        return
    var rect: Rect2 = placed_rects[0]
    draw_rect(rect, PLATFORM_COLOR)
    var hx := COLS / 2
    var hy := ROWS / 2
    var tile_size := Vector2(TILE_SIZE - TILE_GAP, TILE_SIZE - TILE_GAP)
    for y in range(-hy, hy + 1):
        for x in range(-hx, hx + 1):
            var color := TILE_DARK
            if (x + y) % 2 == 0:
                color = TILE_LIGHT_VARIATION[posmod(x * 7 + y * 13, TILE_LIGHT_VARIATION.size())]
            draw_rect(Rect2(Vector2(float(x), float(y)) * TILE_SIZE - tile_size * 0.5, tile_size), color)
    draw_rect(rect, RIM_COLOR, false, 10.0)
    draw_rect(rect.grow(-3.0), OUTLINE_COLOR, false, 2.0)

# ---------------------------------------------------------------- пьедесталы

func _build_pedestals() -> void:
    var round_no: int = RUN.round_number
    var stage: int = RUN.stage_of(round_no)
    if stage == RUN.Stage.ENEMY:
        _add_choice_row(RUN.ENEMY_IDS, "enemy", 4.0, ENEMY_COLOR)
    elif stage == RUN.Stage.CURSE:
        _add_choice_row(RUN.CURSE_IDS, "curse", 3.0, CURSE_COLOR)
    elif stage == RUN.Stage.UPGRADE:
        _add_upgrade_pedestals(round_no)
    else:
        _add_continue_pedestal(Vector2(0.0, PEDESTAL_ROW_Y), round_no)

func _make_pedestal(kind: String, id: String, at: Vector2, accent: Color):
    var pedestal = PEDESTAL.new()
    pedestal.kind = kind
    pedestal.id = id
    pedestal.accent = accent
    pedestal.position = at
    add_child(pedestal)
    _pedestals.append(pedestal)
    return pedestal

## Ряд пьедесталов выбора (враги или проклятия), равномерно по центру платформы.
func _add_choice_row(ids: Array, kind: String, spacing_cells: float, accent: Color) -> void:
    var count := ids.size()
    for i in range(count):
        var id: String = ids[i]
        var info: Dictionary = RUN.choice_info(kind, id)
        var x := (float(i) - float(count - 1) * 0.5) * spacing_cells * TILE_SIZE
        var pedestal = _make_pedestal(kind, id, Vector2(x, PEDESTAL_ROW_Y), accent)
        pedestal.title = info["title"]
        pedestal.description = info["desc"]
        pedestal.detail = info["detail"]
        pedestal.icon = info["icon"]
        pedestal.prompt = "Нажмите F, чтобы выбрать"
        if not bool(info["available"]):
            # Недоступный вариант остаётся видимым и объясняет причину (например, «Максимум достигнут»).
            pedestal.state = PEDESTAL.State.UNAVAILABLE
            pedestal.reason = info["reason"]

## Два боковых пьедестала улучшений и «Продолжить» в центре.
func _add_upgrade_pedestals(round_no: int) -> void:
    var offers: Array[String] = RUN.roll_upgrade_offers(round_no)
    var side_x := 4.0 * TILE_SIZE
    for i in range(2):
        var at := Vector2(-side_x if i == 0 else side_x, PEDESTAL_ROW_Y)
        if i < offers.size():
            var id: String = offers[i]
            var info: Dictionary = RUN.upgrade_info(id, round_no)
            var pedestal = _make_pedestal("upgrade", id, at, UPGRADE_COLOR)
            pedestal.title = info["title"]
            pedestal.description = info["desc"]
            pedestal.detail = info["detail"]
            pedestal.icon = info["icon"]
            pedestal.prompt = "Нажмите F, чтобы купить"
        else:
            # Подходящих улучшений меньше двух. Что показывать здесь - открытый вопрос дизайна (п. 22).
            var empty = _make_pedestal("empty", "", at, UPGRADE_COLOR)
            empty.title = "Нет улучшения"
            empty.description = "На этом пьедестале сейчас нечего купить."
            empty.state = PEDESTAL.State.UNAVAILABLE
            empty.reason = "Нет доступных улучшений"
    _add_continue_pedestal(Vector2(0.0, PEDESTAL_ROW_Y), round_no)

func _add_continue_pedestal(at: Vector2, round_no: int) -> void:
    var pedestal = _make_pedestal("continue", "continue", at, GOLD)
    pedestal.title = "Продолжить"
    pedestal.icon = "continue"
    pedestal.prompt = "Нажмите F, чтобы продолжить"
    if round_no >= RUN.FINAL_ROUND:
        pedestal.description = "Последний раунд забега. Дойдите до маяка, чтобы победить."
    else:
        pedestal.description = "Начать раунд %d. Покупки сохраняются до конца забега." % round_no

# ---------------------------------------------------------------- ближайший пьедестал и ввод

func _process(delta: float) -> void:
    _update_banner(delta)
    _update_nearest()

## Информация и подсветка - только у ближайшего пьедестала в радиусе взаимодействия.
func _update_nearest() -> void:
    if _player == null:
        return
    var best = null
    var best_distance := ACTIVATION_RADIUS
    for pedestal in _pedestals:
        var distance: float = pedestal.global_position.distance_to(_player.global_position)
        if distance <= best_distance:
            best_distance = distance
            best = pedestal
    if best == _nearest:
        return
    if _nearest != null:
        _nearest.highlighted = false
    _nearest = best
    if _nearest != null:
        _nearest.highlighted = true
    _refresh_info()

func _unhandled_input(event: InputEvent) -> void:
    if _leaving or _nearest == null:
        return
    if event.is_action_pressed("interact"):
        get_viewport().set_input_as_handled()
        _activate(_nearest)

func _activate(pedestal) -> void:
    if pedestal.state == PEDESTAL.State.DONE:
        _toast(String(pedestal.reason), Color("b8a1d0"))
        return
    if pedestal.state == PEDESTAL.State.UNAVAILABLE:
        _toast(String(pedestal.reason), ERROR_COLOR)
        return
    match String(pedestal.kind):
        "enemy", "curse":
            _choose(pedestal)
        "upgrade":
            _buy(pedestal)
        "continue":
            _go_to_arena(0.0)

## Выбор врага или проклятия: записывается в забег, остальные пьедесталы блокируются, раунд начинается.
func _choose(pedestal) -> void:
    var info: Dictionary = RUN.choice_info(pedestal.kind, pedestal.id)
    var result: Dictionary = RUN.pick(pedestal.kind, pedestal.id)
    if not bool(result["ok"]):
        pedestal.state = PEDESTAL.State.UNAVAILABLE
        pedestal.reason = result["reason"]
        _refresh_info()
        _toast(String(result["reason"]), ERROR_COLOR)
        return
    var effect: String = info["effect"]
    var body: String = effect if effect != "" else String(info["desc"])
    _toast("%s\n%s" % [result["message"], body], TEXT_COLOR)
    pedestal.state = PEDESTAL.State.DONE
    pedestal.reason = "Выбрано"
    for other in _pedestals:
        if other != pedestal and other.state == PEDESTAL.State.AVAILABLE:
            other.state = PEDESTAL.State.UNAVAILABLE
            other.reason = "Выбор уже сделан"
    _refresh_info()
    _go_to_arena(advance_delay)

## Покупка улучшения за золотые подарки: мгновенная, без подтверждения.
func _buy(pedestal) -> void:
    var info: Dictionary = RUN.upgrade_info(pedestal.id, RUN.round_number)
    var result: Dictionary = RUN.buy_upgrade(pedestal.id, RUN.round_number)
    if not bool(result["ok"]):
        _toast(String(result["reason"]), ERROR_COLOR)
        return
    _toast("%s\n%s" % [result["message"], info["effect"]], GOLD)
    pedestal.state = PEDESTAL.State.DONE
    pedestal.reason = "Куплено"
    # У второго пьедестала в описании цены указан баланс: он изменился.
    for other in _pedestals:
        if other.kind == "upgrade" and other.state == PEDESTAL.State.AVAILABLE:
            var other_info: Dictionary = RUN.upgrade_info(other.id, RUN.round_number)
            other.detail = other_info["detail"]
    _update_hud()
    _refresh_info()

## Уход из лобби: персонаж замирает, экран темнеет, загружается арена этого раунда.
func _go_to_arena(delay: float) -> void:
    if _leaving:
        return
    _leaving = true
    if _player != null and _player.has_method("set_controls_locked"):
        _player.call("set_controls_locked", true)
    Engine.set_meta("nullscape_round", RUN.round_number)
    var tween := create_tween()
    if delay > 0.0:
        tween.tween_interval(delay)
    tween.tween_property(_fade_rect, "color:a", 1.0, FADE_TIME)
    tween.tween_callback(func() -> void: get_tree().change_scene_to_file(GAME_SCENE))

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

func _make_panel_style() -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = Color(0.03, 0.06, 0.08, 0.82)
    style.border_color = Color("5b4a78")
    style.set_border_width_all(2)
    style.set_corner_radius_all(6)
    style.content_margin_left = 22.0
    style.content_margin_right = 22.0
    style.content_margin_top = 14.0
    style.content_margin_bottom = 14.0
    return style

func _build_ui() -> void:
    var canvas := CanvasLayer.new()
    canvas.name = "LobbyUI"
    canvas.layer = 60
    add_child(canvas)

    # Баннер «РАУНД n / 16» и тип этапа: показывается кратко при входе в лобби.
    _banner_root = Control.new()
    _banner_root.name = "RoundBanner"
    _banner_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _banner_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    canvas.add_child(_banner_root)
    _round_label = _make_label(56, TEXT_COLOR)
    _round_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
    _round_label.offset_top = 44.0
    _round_label.offset_bottom = 120.0
    _banner_root.add_child(_round_label)
    _stage_label = _make_label(26, Color("b8a1d0"))
    _stage_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
    _stage_label.offset_top = 122.0
    _stage_label.offset_bottom = 162.0
    _banner_root.add_child(_stage_label)

    # Постоянная панель: раунд и баланс золотых подарков (нужен для покупок).
    var hud_panel := PanelContainer.new()
    hud_panel.name = "RunStatus"
    hud_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    var hud_style := _make_panel_style()
    hud_style.content_margin_left = 16.0
    hud_style.content_margin_right = 16.0
    hud_style.content_margin_top = 8.0
    hud_style.content_margin_bottom = 8.0
    hud_panel.add_theme_stylebox_override("panel", hud_style)
    hud_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT, Control.PRESET_MODE_MINSIZE, 24)
    canvas.add_child(hud_panel)
    var hud_box := VBoxContainer.new()
    hud_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
    hud_panel.add_child(hud_box)
    _hud_round = Label.new()
    _hud_round.add_theme_font_size_override("font_size", 22)
    _hud_round.add_theme_color_override("font_color", Color("b8a1d0"))
    hud_box.add_child(_hud_round)
    _hud_gold = Label.new()
    _hud_gold.add_theme_font_size_override("font_size", 26)
    _hud_gold.add_theme_color_override("font_color", Color("f1d98a"))
    hud_box.add_child(_hud_gold)

    # Панель информации о ближайшем пьедестале.
    _info_panel = PanelContainer.new()
    _info_panel.name = "PedestalInfo"
    _info_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _info_panel.add_theme_stylebox_override("panel", _make_panel_style())
    _info_panel.anchor_left = 0.5
    _info_panel.anchor_right = 0.5
    _info_panel.anchor_top = 1.0
    _info_panel.anchor_bottom = 1.0
    _info_panel.offset_left = -380.0
    _info_panel.offset_right = 380.0
    _info_panel.offset_top = -30.0
    _info_panel.offset_bottom = -30.0
    _info_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
    _info_panel.visible = false
    canvas.add_child(_info_panel)
    var info_box := VBoxContainer.new()
    info_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
    info_box.add_theme_constant_override("separation", 8)
    _info_panel.add_child(info_box)
    _info_title = Label.new()
    _info_title.add_theme_font_size_override("font_size", 30)
    _info_title.add_theme_color_override("font_color", TEXT_COLOR)
    info_box.add_child(_info_title)
    _info_desc = Label.new()
    _info_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _info_desc.add_theme_font_size_override("font_size", 20)
    _info_desc.add_theme_color_override("font_color", Color("d9cbe6"))
    info_box.add_child(_info_desc)
    _info_detail = Label.new()
    _info_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _info_detail.add_theme_font_size_override("font_size", 19)
    _info_detail.add_theme_color_override("font_color", Color("b8a1d0"))
    info_box.add_child(_info_detail)
    _info_prompt = Label.new()
    _info_prompt.add_theme_font_size_override("font_size", 22)
    info_box.add_child(_info_prompt)

    # Короткое уведомление о выборе, покупке или причине отказа.
    _toast_label = _make_label(28, TEXT_COLOR)
    _toast_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
    _toast_label.offset_top = 190.0
    _toast_label.offset_bottom = 290.0
    _toast_label.visible = false
    canvas.add_child(_toast_label)

    # Затемнение при уходе в арену и золотая вспышка при входе из арены (поверх всего, мышь не перехватывают).
    var fade_canvas := CanvasLayer.new()
    fade_canvas.name = "TransitionFade"
    fade_canvas.layer = 110
    add_child(fade_canvas)
    _fade_rect = ColorRect.new()
    _fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _fade_rect.color = Color(0.01, 0.02, 0.03, 0.0)
    _fade_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    fade_canvas.add_child(_fade_rect)
    var flash_canvas := CanvasLayer.new()
    flash_canvas.name = "TransitionFlash"
    flash_canvas.layer = 120
    add_child(flash_canvas)
    _flash_rect = ColorRect.new()
    _flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _flash_rect.color = Color(1.0, 0.85, 0.3, 0.0)
    _flash_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    flash_canvas.add_child(_flash_rect)

func _show_banner() -> void:
    var round_no: int = RUN.round_number
    _round_label.text = "РАУНД %d / %d" % [round_no, RUN.FINAL_ROUND]
    _stage_label.text = RUN.stage_name(round_no)
    _banner_time = 0.0
    _banner_root.modulate.a = 1.0
    _banner_root.visible = true

func _update_banner(delta: float) -> void:
    if not _banner_root.visible:
        return
    _banner_time += delta
    if _banner_time >= banner_hold_time:
        _banner_root.modulate.a = clampf(1.0 - (_banner_time - banner_hold_time) / 0.5, 0.0, 1.0)
        if _banner_root.modulate.a <= 0.0:
            _banner_root.visible = false

func _update_hud() -> void:
    _hud_round.text = "РАУНД %d / %d" % [RUN.round_number, RUN.FINAL_ROUND]
    _hud_gold.text = "ЗОЛОТЫЕ ПОДАРКИ  %d" % RUN.golden_gifts

func _refresh_info() -> void:
    if _nearest == null:
        _info_panel.visible = false
        return
    var pedestal = _nearest
    _info_title.text = pedestal.title
    _info_desc.text = pedestal.description
    _info_detail.text = pedestal.detail
    _info_detail.visible = pedestal.detail != ""
    if pedestal.state == PEDESTAL.State.AVAILABLE:
        _info_prompt.text = pedestal.prompt
        _info_prompt.add_theme_color_override("font_color", GOLD)
    elif pedestal.state == PEDESTAL.State.UNAVAILABLE:
        _info_prompt.text = pedestal.reason
        _info_prompt.add_theme_color_override("font_color", ERROR_COLOR)
    else:
        _info_prompt.text = pedestal.reason
        _info_prompt.add_theme_color_override("font_color", Color("b8a1d0"))
    if not _info_panel.visible:
        _info_panel.visible = true
        _info_panel.modulate.a = 0.0
        create_tween().tween_property(_info_panel, "modulate:a", 1.0, 0.12)

func _toast(text: String, color: Color) -> void:
    _toast_label.text = text
    _toast_label.add_theme_color_override("font_color", color)
    _toast_label.visible = true
    _toast_label.modulate.a = 1.0
    if _toast_tween != null and _toast_tween.is_valid():
        _toast_tween.kill()
    _toast_tween = create_tween()
    _toast_tween.tween_interval(toast_time)
    _toast_tween.tween_property(_toast_label, "modulate:a", 0.0, 0.4)

## После маяка новое лобби начинается с золотой вспышки: она гаснет и не мешает управлению.
func _play_entry_flash() -> void:
    if not Engine.has_meta("nullscape_gold_flash"):
        return
    Engine.remove_meta("nullscape_gold_flash")
    _flash_rect.color.a = 1.0
    create_tween().tween_property(_flash_rect, "color:a", 0.0, 0.6)
