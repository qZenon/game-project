extends Node2D

## Пункт 21.14: враг Slash (дизайн-документ, п. 13.1).
##
## Не физический враг: разрез-линия через всю арену под случайным углом проходит через текущую
## позицию игрока. 1 секунда на уклонение, затем удар: кто остался на линии, тот гибнет
## (если не спасает Second Chance). Предупреждающая линия мигает все 1,0 с и исчезает при ударе:
## окно реакции не сокращается. Каждый разрез серии получает новый угол и новую позицию игрока.
##
## Серия: 2 разреза (+1 за каждый Deep Cuts, максимум 2). Интервал между сериями: 15, 13, 11, 9 с
## по числу выборов Slash (RunState.slash_interval).
## Запускает и останавливает RoundController: start() по "НАЧАЛИ!", stop() после касания маяка.
##
## Не определено в документе (взято как допущение, меняется экспортами): первая серия начинается
## через first_series_delay, а интервал считается от удара последнего разреза серии до начала
## предупреждения первого разреза следующей; пауза между разрезами внутри серии - cut_gap.

const RUN := preload("res://game/run_state.gd")

const WARN_TIME := 1.0                    # п. 13.1: на уклонение даётся 1 секунда
const HIT_HALF_WIDTH := 12.0              # половина ширины смертельной полосы = полоса, которую видит игрок
const BODY_OFFSET := Vector2(0.0, -12.0)  # центр тела персонажа выше его опорной точки (как у коллизии)
const STRIKE_LIFE := 1.0                  # сколько живёт светящийся след после удара
const CANCEL_TIME := 0.25                 # как быстро гаснет предупреждение, если раунд закончился
const SPARK_RANGE := 700.0                # искры разлетаются только рядом с игроком (дальше не видно)

const VIOLET := Color("a45cff")
const VIOLET_LIGHT := Color("d6b8ff")
const VIOLET_DEEP := Color("6d28d9")
const PINK := Color("ff6bd6")
const WHITE_CORE := Color("f6ecff")
const SHIELD := Color("4fd1c5")
const SHIELD_LIGHT := Color("b8fff4")

const SFX_PATHS := {
	"warn": "res://audio/sfx/slash_warn.wav",
	"cut": "res://audio/sfx/slash_cut.wav",
	"hit": "res://audio/sfx/slash_hit.wav",
	"saved": "res://audio/sfx/slash_saved.wav",
}

## Половинка спрайта игрока по одну сторону от линии разреза: у шейдера "раздвигаются" две копии.
const SLICE_SHADER_CODE := """
shader_type canvas_item;
uniform vec2 line_point = vec2(0.0);
uniform vec2 line_normal = vec2(0.0, 1.0);
uniform float keep_side = 1.0;
uniform vec4 tint : source_color = vec4(0.75, 0.55, 1.0, 1.0);
varying vec2 world_pos;
void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}
void fragment() {
	if (dot(world_pos - line_point, line_normal) * keep_side < 0.0) {
		discard;
	}
	COLOR.rgb = mix(COLOR.rgb, tint.rgb, 0.45);
}
"""

## Первая серия начинается через столько секунд после "НАЧАЛИ!".
@export_range(0.0, 15.0, 0.5) var first_series_delay: float = 5.0
## Пауза между ударом разреза и началом предупреждения следующего разреза той же серии.
@export_range(0.0, 3.0, 0.05) var cut_gap: float = 0.5

var arena: Node2D
var player: Node2D
var running: bool = false

var _gap_timer: float = 0.0
var _series_left: int = 0
var _time: float = 0.0
var _reach: float = 2000.0

# Разрез: {"point": Vector2, "dir": Vector2, "age": float, "struck": bool, "strike_age": float, "cancel": float, "seed": float}
var _cuts: Array[Dictionary] = []
# Искра: {"pos": Vector2, "vel": Vector2, "life": float, "max": float, "color": Color, "width": float, "drag": float}
var _particles: Array[Dictionary] = []
# Волна/вспышка: {"pos", "age", "life", "r0", "r1", "color", "width", "kind", "dir"}
var _rings: Array[Dictionary] = []

var _warn_canvas: Node2D
var _fx_canvas: Node2D
var _flash_rect: ColorRect
var _flash_tween: Tween
var _sfx: Dictionary = {}
var _slice_shader: Shader

func _ready() -> void:
	# Аддитивное смешивание даёт свечение: линии и искры светятся поверх платформ.
	var additive := CanvasItemMaterial.new()
	additive.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD

	_warn_canvas = Node2D.new()
	_warn_canvas.name = "SlashWarnings"
	_warn_canvas.z_index = 20  # выше платформ и подарков (10), ниже персонажа (100)
	_warn_canvas.material = additive
	add_child(_warn_canvas)
	_warn_canvas.draw.connect(_draw_warnings)

	_fx_canvas = Node2D.new()
	_fx_canvas.name = "SlashEffects"
	_fx_canvas.z_index = 110  # удар и искры поверх персонажа
	_fx_canvas.material = additive
	add_child(_fx_canvas)
	_fx_canvas.draw.connect(_draw_effects)

	var layer := CanvasLayer.new()
	layer.name = "SlashScreenFx"
	layer.layer = 95  # ниже предупреждения о падении (100)
	add_child(layer)
	_flash_rect = ColorRect.new()
	_flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash_rect.color = Color(VIOLET, 0.0)
	_flash_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_flash_rect)

	_build_audio()

## Раунд начался: через first_series_delay пойдёт первая серия.
func start() -> void:
	var bounds := Rect2()
	var first := true
	var rects: Array = arena.get("placed_rects") if arena != null else []
	for rect in rects:
		bounds = rect if first else bounds.merge(rect)
		first = false
	_reach = (bounds.size.length() if not first else 2400.0) + 400.0
	_series_left = 0
	_gap_timer = first_series_delay
	running = true

## Раунд закончился: новые разрезы не начинаются, непоражённые предупреждения гаснут.
func stop() -> void:
	running = false
	for cut in _cuts:
		if not bool(cut["struck"]) and float(cut["cancel"]) < 0.0:
			cut["cancel"] = 0.0

func _player_dead() -> bool:
	return player == null or not is_instance_valid(player) or player.get("is_dead") == true

func _process(delta: float) -> void:
	_time += delta
	if running:
		if _player_dead():
			stop()
		else:
			_gap_timer -= delta
			if _gap_timer <= 0.0:
				_launch_cut()
	_update_cuts(delta)
	_update_particles(delta)
	_update_rings(delta)
	_warn_canvas.queue_redraw()
	_fx_canvas.queue_redraw()

# ---------------------------------------------------------------- расписание разрезов

## Начинает предупреждение: линия проходит через ТЕКУЩУЮ позицию игрока под новым случайным углом.
func _launch_cut() -> void:
	if _series_left <= 0:
		_series_left = RUN.slash_series_count()
	_series_left -= 1
	var point := to_local(player.global_position + BODY_OFFSET)
	var direction := Vector2.from_angle(randf() * PI)
	_cuts.append({
		"point": point,
		"dir": direction,
		"age": 0.0,
		"struck": false,
		"strike_age": 0.0,
		"cancel": -1.0,
		"seed": randf() * 100.0,
	})
	_play("warn")
	# Следующий разрез серии - после удара этого и паузы; следующая серия - после интервала.
	if _series_left > 0:
		_gap_timer = WARN_TIME + cut_gap
	else:
		_gap_timer = WARN_TIME + RUN.slash_interval()

func _update_cuts(delta: float) -> void:
	for i in range(_cuts.size() - 1, -1, -1):
		var cut: Dictionary = _cuts[i]
		if float(cut["cancel"]) >= 0.0:
			cut["cancel"] = float(cut["cancel"]) + delta
			if float(cut["cancel"]) >= CANCEL_TIME:
				_cuts.remove_at(i)
			continue
		cut["age"] = float(cut["age"]) + delta
		if not bool(cut["struck"]) and float(cut["age"]) >= WARN_TIME:
			_strike(cut)
		if bool(cut["struck"]):
			cut["strike_age"] = float(cut["strike_age"]) + delta
			if float(cut["strike_age"]) >= STRIKE_LIFE:
				_cuts.remove_at(i)

## Удар: линия вспыхивает, летят искры; игрок на линии гибнет (или тратит заряд Second Chance).
func _strike(cut: Dictionary) -> void:
	cut["struck"] = true
	cut["strike_age"] = 0.0
	var point: Vector2 = cut["point"]
	var direction: Vector2 = cut["dir"]
	_play("cut")
	_spawn_line_sparks(point, direction)
	if _player_dead():
		return
	var body := to_local(player.global_position + BODY_OFFSET)
	var normal := Vector2(-direction.y, direction.x)
	if absf((body - point).dot(normal)) > HIT_HALF_WIDTH:
		return
	var died := true
	if player.has_method("take_lethal_hit"):
		died = bool(player.call("take_lethal_hit", "slash"))
	_impact_effects(body, direction, died)

# ---------------------------------------------------------------- эффекты попадания

## Разрез настиг игрока: died - погиб; иначе удар поглотил Second Chance.
func _impact_effects(body: Vector2, direction: Vector2, died: bool) -> void:
	var normal := Vector2(-direction.y, direction.x)
	if died:
		_play("hit")
		_add_ring(body, 0.30, 0.0, 80.0, VIOLET_LIGHT, 0.0, "fill", direction)
		_add_ring(body, 0.45, 8.0, 130.0, WHITE_CORE, 6.0, "ring", direction)
		_add_ring(body, 0.65, 6.0, 190.0, VIOLET_LIGHT, 3.0, "ring", direction)
		_add_ring(body, 0.85, 4.0, 260.0, PINK, 2.0, "ring", direction)
		_add_ring(body, 0.40, 40.0, 300.0, WHITE_CORE, 3.0, "cross", direction)
		# радиальный взрыв и осколки вдоль линии разреза
		for i in range(64):
			var angle := randf() * TAU
			var speed := randf_range(140.0, 480.0)
			_spawn_particle(body, Vector2.from_angle(angle) * speed, randf_range(0.4, 0.9), _pick_color(), randf_range(2.0, 4.0), 2.2)
		for i in range(36):
			var along := direction * (1.0 if randf() < 0.5 else -1.0)
			_spawn_particle(body, along * randf_range(300.0, 760.0) + normal * randf_range(-40.0, 40.0), randf_range(0.3, 0.7), WHITE_CORE, randf_range(1.5, 3.0), 3.0)
		if player.has_method("shake_camera"):
			player.call("shake_camera", 9.0, 0.5)
		_screen_flash(VIOLET, 0.5, 0.6)
		_slice_player(body, direction)
	else:
		_play("saved")
		_add_ring(body, 0.35, 0.0, 70.0, SHIELD_LIGHT, 0.0, "fill", direction)
		_add_ring(body, 0.55, 14.0, 80.0, SHIELD, 3.0, "hex", direction)
		_add_ring(body, 0.75, 10.0, 120.0, SHIELD_LIGHT, 2.0, "ring", direction)
		for i in range(40):
			_spawn_particle(body, Vector2.from_angle(randf() * TAU) * randf_range(100.0, 340.0), randf_range(0.4, 0.8), SHIELD_LIGHT if randf() < 0.5 else SHIELD, randf_range(1.5, 3.0), 2.4)
		if player.has_method("shake_camera"):
			player.call("shake_camera", 4.0, 0.3)
		_screen_flash(SHIELD, 0.22, 0.4)

## Игрока рассекает: два полупрозрачных куска спрайта по обе стороны линии медленно расходятся.
func _slice_player(body: Vector2, direction: Vector2) -> void:
	var sprite := player.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	if sprite == null:
		return
	if _slice_shader == null:
		_slice_shader = Shader.new()
		_slice_shader.code = SLICE_SHADER_CODE
	var normal := Vector2(-direction.y, direction.x)
	var origin := to_global(body)
	var base := sprite.global_position
	for side in [-1.0, 1.0]:
		var half := sprite.duplicate() as AnimatedSprite2D
		var slice_material := ShaderMaterial.new()
		slice_material.shader = _slice_shader
		slice_material.set_shader_parameter("line_normal", normal)
		slice_material.set_shader_parameter("keep_side", side)
		half.material = slice_material
		half.modulate = Color.WHITE
		player.add_child(half)
		half.global_position = base
		# bind добавляет аргументы после progress: _update_slice(progress, half, material, ...)
		var tween := create_tween()
		tween.tween_method(_update_slice.bind(half, slice_material, base, origin, normal, float(side)), 0.0, 1.0, 1.3)
	sprite.visible = false

## Кадр расхождения половинок: смещение вдоль нормали, граница среза едет вместе с половинкой.
func _update_slice(progress: float, half: AnimatedSprite2D, slice_material: ShaderMaterial, base: Vector2, origin: Vector2, normal: Vector2, side: float) -> void:
	if not is_instance_valid(half):
		return
	var shift := normal * side * (1.0 - pow(1.0 - progress, 3.0)) * 14.0
	half.global_position = base + shift
	slice_material.set_shader_parameter("line_point", origin + shift)
	half.modulate.a = 1.0 - clampf((progress - 0.55) / 0.45, 0.0, 1.0)

func _screen_flash(color: Color, alpha: float, duration: float) -> void:
	_flash_rect.color = Color(color, alpha)
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	_flash_tween = create_tween()
	_flash_tween.tween_property(_flash_rect, "color:a", 0.0, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

# ---------------------------------------------------------------- частицы и волны

func _pick_color() -> Color:
	var roll := randf()
	if roll < 0.4:
		return VIOLET_LIGHT
	if roll < 0.7:
		return VIOLET
	if roll < 0.88:
		return PINK
	return WHITE_CORE

func _spawn_particle(pos: Vector2, vel: Vector2, life: float, color: Color, width: float, drag: float) -> void:
	_particles.append({"pos": pos, "vel": vel, "life": life, "max": life, "color": color, "width": width, "drag": drag})

func _add_ring(pos: Vector2, life: float, r0: float, r1: float, color: Color, width: float, kind: String, direction: Vector2) -> void:
	_rings.append({"pos": pos, "age": 0.0, "life": life, "r0": r0, "r1": r1, "color": color, "width": width, "kind": kind, "dir": direction})

## Искры вдоль всей видимой части линии: вылетают в стороны от разреза.
func _spawn_line_sparks(point: Vector2, direction: Vector2) -> void:
	var normal := Vector2(-direction.y, direction.x)
	var t := -SPARK_RANGE
	while t <= SPARK_RANGE:
		if randf() < 0.7:
			var pos := point + direction * t + normal * randf_range(-5.0, 5.0)
			var side := -1.0 if randf() < 0.5 else 1.0
			var vel := normal * side * randf_range(60.0, 300.0) + direction * randf_range(-80.0, 80.0)
			_spawn_particle(pos, vel, randf_range(0.3, 0.8), _pick_color(), randf_range(1.5, 3.2), 2.6)
		t += 20.0

func _update_particles(delta: float) -> void:
	for i in range(_particles.size() - 1, -1, -1):
		var particle: Dictionary = _particles[i]
		particle["life"] = float(particle["life"]) - delta
		if float(particle["life"]) <= 0.0:
			_particles.remove_at(i)
			continue
		var vel: Vector2 = particle["vel"]
		particle["pos"] = Vector2(particle["pos"]) + vel * delta
		particle["vel"] = vel * maxf(0.0, 1.0 - float(particle["drag"]) * delta)

func _update_rings(delta: float) -> void:
	for i in range(_rings.size() - 1, -1, -1):
		var ring: Dictionary = _rings[i]
		ring["age"] = float(ring["age"]) + delta
		if float(ring["age"]) >= float(ring["life"]):
			_rings.remove_at(i)

# ---------------------------------------------------------------- отрисовка

## Предупреждение: мигающая фиолетовая полоса ровно той ширины, где удар смертелен.
func _draw_warnings() -> void:
	var c := _warn_canvas
	for cut in _cuts:
		if bool(cut["struck"]):
			continue
		var fade := 1.0
		if float(cut["cancel"]) >= 0.0:
			fade = 1.0 - float(cut["cancel"]) / CANCEL_TIME
		var t := clampf(float(cut["age"]) / WARN_TIME, 0.0, 1.0)
		var point: Vector2 = cut["point"]
		var direction: Vector2 = cut["dir"]
		var normal := Vector2(-direction.y, direction.x)
		var a := point - direction * _reach
		var b := point + direction * _reach
		# мигание ускоряется к моменту удара, но линия остаётся видимой: окно реакции не скрывается
		var blink := 0.5 + 0.5 * sin(TAU * (t * 5.0 + t * t * 9.0))
		var visible_amount := lerpf(0.3, 1.0, blink) * fade

		c.draw_line(a, b, Color(VIOLET, (0.10 + 0.16 * t) * visible_amount), HIT_HALF_WIDTH * 2.0)
		for side in [-1.0, 1.0]:
			var offset: Vector2 = normal * float(side) * HIT_HALF_WIDTH
			c.draw_line(a + offset, b + offset, Color(VIOLET, 0.6 * visible_amount), 1.5)
		c.draw_line(a, b, Color(VIOLET_LIGHT, (0.5 + 0.5 * t) * visible_amount), 2.0)

		# энергия разбегается от точки удара в обе стороны
		var seed_value := float(cut["seed"])
		for k in range(7):
			var u := fposmod(_time * 1.5 + float(k) / 7.0 + seed_value, 1.0)
			var distance := u * 640.0
			for side in [-1.0, 1.0]:
				var start: Vector2 = point + direction * float(side) * distance
				c.draw_line(start, start + direction * float(side) * 26.0, Color(PINK, (1.0 - u) * 0.85 * fade), 2.5)

		# кольцо сжимается вокруг игрока
		var ring_radius := lerpf(70.0, HIT_HALF_WIDTH + 2.0, 1.0 - pow(1.0 - t, 2.0))
		c.draw_arc(point, ring_radius, 0.0, TAU, 48, Color(VIOLET_LIGHT, (0.3 + 0.6 * t) * fade), 1.5)
		c.draw_arc(point, ring_radius * 0.55, 0.0, TAU, 32, Color(PINK, 0.35 * t * fade), 1.0)

## Удар: широкая вспышка, остывающий след-трещина, расходящиеся волны, искры, кольца.
func _draw_effects() -> void:
	var c := _fx_canvas
	for cut in _cuts:
		if not bool(cut["struck"]):
			continue
		var age := float(cut["strike_age"])
		var point: Vector2 = cut["point"]
		var direction: Vector2 = cut["dir"]
		var normal := Vector2(-direction.y, direction.x)
		var a := point - direction * _reach
		var b := point + direction * _reach
		var k := clampf(age / 0.45, 0.0, 1.0)
		var inv := 1.0 - k
		var core_width := 6.0 + 40.0 * pow(inv, 2.0)

		c.draw_line(a, b, Color(VIOLET, 0.30 * inv), core_width * 3.0)
		c.draw_line(a, b, Color(VIOLET_LIGHT, 0.55 * inv), core_width * 1.3)
		c.draw_line(a, b, Color(WHITE_CORE, 0.95 * inv), maxf(2.0, core_width * 0.45))

		# остывающий след: тонкая розово-фиолетовая трещина с мерцанием
		var crack := clampf(1.0 - age / STRIKE_LIFE, 0.0, 1.0)
		var flicker := 0.75 + 0.25 * sin(_time * 60.0 + float(cut["seed"]))
		c.draw_line(a, b, Color(VIOLET, 0.35 * crack), 7.0)
		c.draw_line(a, b, Color(PINK, 0.7 * crack * flicker), 2.0)

		# две волны расходятся от линии в стороны
		var wave_offset := HIT_HALF_WIDTH + age * 620.0
		var wave_alpha := 0.5 * pow(inv, 1.5)
		for side in [-1.0, 1.0]:
			var offset: Vector2 = normal * float(side) * wave_offset
			c.draw_line(a + offset, b + offset, Color(VIOLET_LIGHT, wave_alpha), 2.0)

	for particle in _particles:
		var life_fraction := float(particle["life"]) / float(particle["max"])
		var pos: Vector2 = particle["pos"]
		var vel: Vector2 = particle["vel"]
		var color: Color = particle["color"]
		c.draw_line(pos, pos - vel * 0.03, Color(color, life_fraction), float(particle["width"]) * (0.5 + 0.5 * life_fraction))

	for ring in _rings:
		var progress := clampf(float(ring["age"]) / float(ring["life"]), 0.0, 1.0)
		var eased := 1.0 - pow(1.0 - progress, 3.0)
		var radius := lerpf(float(ring["r0"]), float(ring["r1"]), eased)
		var alpha := 1.0 - progress
		var pos: Vector2 = ring["pos"]
		var color: Color = ring["color"]
		var width := float(ring["width"])
		match String(ring["kind"]):
			"fill":
				c.draw_circle(pos, radius, Color(color, 0.55 * alpha * alpha))
			"hex":
				var points := PackedVector2Array()
				for i in range(7):
					var angle := TAU * float(i) / 6.0 + 0.5
					points.append(pos + Vector2(cos(angle), sin(angle)) * radius)
				c.draw_polyline(points, Color(color, alpha), width)
			"cross":
				var dir: Vector2 = ring["dir"]
				var perpendicular := Vector2(-dir.y, dir.x)
				c.draw_line(pos - dir * radius, pos + dir * radius, Color(color, alpha), width)
				c.draw_line(pos - perpendicular * radius * 0.45, pos + perpendicular * radius * 0.45, Color(color, alpha * 0.7), width)
			_:
				c.draw_arc(pos, radius, 0.0, TAU, 48, Color(color, alpha), width)

# ---------------------------------------------------------------- звук

func _build_audio() -> void:
	for key in SFX_PATHS:
		var path: String = SFX_PATHS[key]
		if not ResourceLoader.exists(path):
			continue
		var audio := AudioStreamPlayer.new()
		audio.name = "Sfx_" + String(key)
		audio.stream = load(path)
		audio.volume_db = -5.0
		add_child(audio)
		_sfx[key] = audio

func _play(key: String) -> void:
	if _sfx.has(key):
		(_sfx[key] as AudioStreamPlayer).play()
