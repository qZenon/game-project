extends Node2D

## Пьедестал лобби (21.13): круглая плита с символом. Хранит данные для панели информации и
## своё состояние. Тонкий светящийся контур включается, когда пьедестал - ближайший к игроку.
## Лобби (lobby.gd) выбирает ближайший, показывает информацию и обрабатывает нажатие F.

enum State { AVAILABLE, UNAVAILABLE, DONE }

const RADIUS := 17.0
const BASE_DARK := Color("0b0e14")
const PLATE := Color("1a1626")
const GOLD := Color("ffd84a")
const MUTED := Color("5a5666")
const BLOCKED := Color("8a4a55")

## "enemy", "curse", "upgrade" или "continue".
var kind: String = "enemy"
var id: String = ""
var title: String = ""
var description: String = ""
var detail: String = ""
var prompt: String = "Нажмите F, чтобы выбрать"
## Почему вариант недоступен (UNAVAILABLE) или что с ним уже сделано (DONE).
var reason: String = ""
var state: State = State.AVAILABLE
var icon: String = ""
var accent: Color = Color("b8a1d0")
## Ставит лобби: true только у ближайшего пьедестала в зоне взаимодействия.
var highlighted: bool = false

var _time: float = 0.0
var _glow: float = 0.0

func _ready() -> void:
    z_index = 2  # выше плитки платформы, ниже персонажа (z_index = 100)

func _process(delta: float) -> void:
    _time += delta
    _glow = move_toward(_glow, 1.0 if highlighted else 0.0, delta * 6.0)
    queue_redraw()

func _draw() -> void:
    var color := MUTED if state == State.UNAVAILABLE else accent

    # плита: тёмное основание, цветное кольцо, тёмная середина
    draw_circle(Vector2(0.0, 3.0), RADIUS + 3.0, Color(0.0, 0.0, 0.0, 0.35))
    draw_circle(Vector2.ZERO, RADIUS, BASE_DARK)
    draw_arc(Vector2.ZERO, RADIUS - 1.0, 0.0, TAU, 40, Color(color, 0.6), 2.0)
    draw_circle(Vector2.ZERO, RADIUS - 5.0, PLATE)

    if state == State.DONE:
        draw_arc(Vector2.ZERO, RADIUS - 1.0, 0.0, TAU, 40, Color(GOLD, 0.9), 2.0)
        draw_polyline(PackedVector2Array([Vector2(-6.0, 0.0), Vector2(-1.5, 5.0), Vector2(7.0, -6.0)]), GOLD, 2.5)
    else:
        _draw_icon(color)
        if state == State.UNAVAILABLE:
            draw_line(Vector2(-9.0, -9.0), Vector2(9.0, 9.0), BLOCKED, 2.0)
            draw_line(Vector2(-9.0, 9.0), Vector2(9.0, -9.0), BLOCKED, 2.0)

    if _glow > 0.01:
        var lit := color.lightened(0.45)
        var pulse := 0.5 + 0.5 * sin(_time * 4.0)
        draw_arc(Vector2.ZERO, RADIUS + 5.0 + pulse * 1.5, 0.0, TAU, 48, Color(lit, 0.22 * _glow), 6.0)
        draw_arc(Vector2.ZERO, RADIUS + 4.0, 0.0, TAU, 48, Color(lit, _glow), 1.5)

func _draw_icon(c: Color) -> void:
    match icon:
        "slash":
            draw_line(Vector2(-8.0, 8.0), Vector2(8.0, -8.0), c, 2.5)
            draw_line(Vector2(-8.0, 2.0), Vector2(2.0, -8.0), Color(c, 0.6), 1.5)
        "mimic":
            draw_rect(Rect2(Vector2(-8.0, -8.0), Vector2(10.0, 10.0)), Color(c, 0.55), false, 1.5)
            draw_rect(Rect2(Vector2(-2.0, -2.0), Vector2(10.0, 10.0)), c, false, 2.0)
        "operator":
            draw_arc(Vector2.ZERO, 8.0, 0.0, TAU, 24, c, 2.0)
            draw_circle(Vector2.ZERO, 2.5, c)
        "displacement":
            for direction in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
                draw_line(direction * 3.0, direction * 9.0, c, 2.0)
        "no_time_to_think":
            draw_arc(Vector2.ZERO, 8.0, 0.0, TAU, 24, c, 2.0)
            draw_line(Vector2.ZERO, Vector2(0.0, -5.0), c, 2.0)
            draw_line(Vector2.ZERO, Vector2(4.0, 2.0), c, 2.0)
        "closing_gap":
            draw_colored_polygon(PackedVector2Array([Vector2(-9.0, -6.0), Vector2(-9.0, 6.0), Vector2(-2.0, 0.0)]), c)
            draw_colored_polygon(PackedVector2Array([Vector2(9.0, -6.0), Vector2(9.0, 6.0), Vector2(2.0, 0.0)]), c)
        "deep_cuts":
            for offset in [-5.0, 0.0, 5.0]:
                draw_line(Vector2(-7.0 + offset, 8.0), Vector2(3.0 + offset, -8.0), c, 2.0)
        "jackpot":
            draw_rect(Rect2(Vector2(-7.0, -7.0), Vector2(14.0, 14.0)), c, false, 2.0)
            draw_circle(Vector2(-3.0, -3.0), 1.6, c)
            draw_circle(Vector2(3.0, 3.0), 1.6, c)
            draw_circle(Vector2.ZERO, 1.6, c)
        "overdrive":
            for shift in [-5.0, 1.0]:
                draw_polyline(PackedVector2Array([Vector2(shift - 3.0, -6.0), Vector2(shift + 3.0, 0.0), Vector2(shift - 3.0, 6.0)]), c, 2.5)
        "license":
            draw_arc(Vector2.ZERO, 8.0, 0.0, TAU, 24, c, 2.0)
            draw_polyline(PackedVector2Array([Vector2(-3.0, -4.0), Vector2(-3.0, 4.0), Vector2(4.0, 4.0)]), c, 2.0)
        "second_chance":
            draw_polyline(PackedVector2Array([Vector2(-7.0, -7.0), Vector2(7.0, -7.0), Vector2(7.0, 1.0), Vector2(0.0, 9.0), Vector2(-7.0, 1.0), Vector2(-7.0, -7.0)]), c, 2.0)
        "gift_radar":
            draw_circle(Vector2.ZERO, 2.5, c)
            draw_arc(Vector2.ZERO, 6.0, -0.8, 0.8, 10, c, 1.5)
            draw_arc(Vector2.ZERO, 10.0, -0.8, 0.8, 10, c, 1.5)
        "rapid_recalibration":
            draw_arc(Vector2.ZERO, 8.0, 0.6, TAU - 0.6, 24, c, 2.0)
            draw_colored_polygon(PackedVector2Array([Vector2(5.0, -9.0), Vector2(11.0, -4.0), Vector2(4.0, -3.0)]), c)
        "continue":
            draw_line(Vector2(-8.0, 0.0), Vector2(6.0, 0.0), c, 3.0)
            draw_polyline(PackedVector2Array([Vector2(1.0, -6.0), Vector2(8.0, 0.0), Vector2(1.0, 6.0)]), c, 3.0)
        _:
            draw_colored_polygon(PackedVector2Array([Vector2(0.0, -8.0), Vector2(8.0, 0.0), Vector2(0.0, 8.0), Vector2(-8.0, 0.0)]), c)
