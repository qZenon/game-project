extends Node2D

## Генерация арены: центральная платформа и случайное дерево структур вокруг неё.
## Структуры - мосты и платформы разных форм (прямоугольники разных размеров, "плюсы"), заранее
## заданных типов, а не случайная укладка каждой клетки. Всё лежит на сетке тайлов.
##
## ПРАВИЛА ПОДАРКОВ (дизайн, п. 7, 9, 11.3):
##  - на центральной платформе подарков нет никогда;
##  - у каждой платформы и каждого моста есть прямая СПЛОШНАЯ линия подарков (по одному на тайл),
##    линии соседних структур стыкуются, поэтому на путях нет пробелов;
##  - у "плюса" сплошные обе оси, у прямоугольника - ось по длине и линии к боковым ответвлениям;
##  - остальные подарки раунда идут на дополнительные параллельные линии широких платформ;
##  - всего размещается ровно столько подарков, сколько указано для раунда: арена строится под это число.

@export var arena_seed: int = 0
@export_range(3, 6, 1) var branches: int = 4
## Номер раунда: от него зависит число подарков (а значит, размер и разветвлённость арены).
@export_range(1, 16, 1) var round_number: int = 1

const TILE_SIZE := 42.0

const CENTER_CELLS := Vector2i(9, 7)   # центральная платформа (ширина x высота)
const BRIDGE_LEN := 4                  # длина моста в тайлах (ширина всегда 3)
# Размеры прямоугольных платформ в тайлах - только нечётные: ось и мосты всегда по центру клеток.
# Значения повторяются намеренно: так средние размеры выпадают чаще крайних.
const RECT_ALONG: Array[int] = [3, 5, 5, 7, 7, 9]    # длина вдоль направления входа
const RECT_ACROSS: Array[int] = [3, 3, 5, 5, 7, 9]   # ширина поперёк
const PLUS_ARMS: Array[int] = [1, 2, 2, 3]           # длина луча "плюса" за центральным квадратом 3x3
const PLUS_CHANCE := 0.35
const MAX_ATTEMPTS := 80
const MAX_EXTENT := Vector2i(34, 24)   # арена не выходит за эти границы (в тайлах от центра)
const GIFT_LINE_SPACING := 2           # параллельные линии подарков через клетку

# Подарки: базовое количество по раундам (дизайн-документ, п. 11.3).
const GIFTS_PER_ROUND: Array[int] = [60, 66, 73, 80, 88, 97, 106, 117, 128, 141, 155, 171, 188, 207, 228, 251]
const PLATFORM_COLOR := Color("11151d")
const BRIDGE_COLOR := Color("11151d")
const OUTLINE_COLOR := Color("343447")
const ACCENT_COLOR := Color("d5b65c")
const TILE_GAP := 1.5
const TILE_LIGHT := Color("b8a1d0")
const TILE_DARK := Color("11121a")
const TILE_VARIATION := [Color("c1acd7"), Color("a994c2"), Color("b5a0ca"), Color("a18db8")]

var rng := RandomNumberGenerator.new()
var generated_structures: Array[Node2D] = []
var placed_rects: Array[Rect2] = []  # занятые области (опора под ногами), по прямоугольнику на кусок структуры
var structure_rects: Dictionary = {}    # узел структуры -> массив её прямоугольников (нужен обрушению)
var gift_points: Array[Vector2] = []    # итоговые точки подарков текущего раунда (локальные координаты)
var buildable_structures: Array[Node2D] = []  # мосты и платформы вокруг центра: они появляются при подготовке арены

# План арены в клетках. Запись: {"kind": "center"/"bridge"/"rect"/"plus", "cells": Array[Vector2i],
# "rects": Array[Rect2], "anchors": Array[Dictionary], "axis": Array[Vector2i], "extras": Array, "center": Vector2i}
var _plan: Array[Dictionary] = []
var _occupied: Dictionary = {}   # Vector2i -> индекс структуры в плане
var _skeleton: Dictionary = {}   # Vector2i -> true: клетки обязательных сплошных линий подарков

func _ready() -> void:
	# Номер раунда может прийти из предыдущего раунда (пока вместо лобби перезагружается сцена).
	if Engine.has_meta("nullscape_round"):
		round_number = clampi(int(Engine.get_meta("nullscape_round")), 1, GIFTS_PER_ROUND.size())
	if arena_seed == 0:
		rng.randomize()
	else:
		rng.seed = arena_seed
	_create_background()
	generate_arena()

func generate_arena() -> void:
	for structure in generated_structures:
		if is_instance_valid(structure):
			structure.queue_free()
	generated_structures.clear()
	placed_rects.clear()
	structure_rects.clear()
	gift_points.clear()
	buildable_structures.clear()

	var gift_count: int = GIFTS_PER_ROUND[clampi(round_number, 1, GIFTS_PER_ROUND.size()) - 1]
	# Арена строится под число подарков: если очередной вариант не получился, пробуем снова.
	for attempt in range(MAX_ATTEMPTS):
		if _plan_arena(gift_count):
			break
	_build_arena()
	_layout_gifts(gift_count)

# ---------------------------------------------------------------- планирование (в клетках)

func _shuffled(items: Array) -> Array:
	var result := items.duplicate()
	for i in range(result.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp: Variant = result[i]
		result[i] = result[j]
		result[j] = tmp
	return result

func _pick(items: Array[int]) -> int:
	return items[rng.randi_range(0, items.size() - 1)]

func _perp(d: Vector2i) -> Vector2i:
	return Vector2i(-d.y, d.x)

## Прямоугольник в пикселях (локальные координаты арены) по границам набора клеток.
func _cells_bounds(cells: Array) -> Rect2:
	var lo := Vector2i(1 << 20, 1 << 20)
	var hi := Vector2i(-(1 << 20), -(1 << 20))
	for item in cells:
		var cell: Vector2i = item
		lo = Vector2i(mini(lo.x, cell.x), mini(lo.y, cell.y))
		hi = Vector2i(maxi(hi.x, cell.x), maxi(hi.y, cell.y))
	return Rect2((Vector2(lo) - Vector2(0.5, 0.5)) * TILE_SIZE, Vector2(hi - lo + Vector2i.ONE) * TILE_SIZE)

func _rect_cells(first: Vector2i, along: int, across: int, d: Vector2i) -> Array[Vector2i]:
	var p := _perp(d)
	var half := (across - 1) / 2
	var cells: Array[Vector2i] = []
	for i in range(along):
		for j in range(-half, half + 1):
			cells.append(first + d * i + p * j)
	return cells

## Прямоугольная платформа. entry - первая клетка оси, d - направление входа.
## Выходы: вперёд, и вбок в середине каждой длинной стороны (для бокового выхода подарки идут от оси к краю).
func _make_rect(entry: Vector2i, d: Vector2i, along: int, across: int) -> Dictionary:
	var p := _perp(d)
	var half := (across - 1) / 2
	var mid := (along - 1) / 2
	var cells := _rect_cells(entry, along, across, d)
	var axis: Array[Vector2i] = []
	for i in range(along):
		axis.append(entry + d * i)
	var anchors: Array[Dictionary] = []
	anchors.append({"cell": entry + d * (along - 1), "dir": d, "connector": [] as Array[Vector2i], "used": false})
	for sgn in [1, -1]:
		var connector: Array[Vector2i] = []
		for k in range(1, half + 1):
			connector.append(entry + d * mid + p * sgn * k)
		anchors.append({"cell": entry + d * mid + p * sgn * half, "dir": p * sgn, "connector": connector, "used": false})
	# Дополнительные линии: параллельно оси, через GIFT_LINE_SPACING клеток.
	var extras: Array = []
	var offset := GIFT_LINE_SPACING
	while offset <= half:
		for sgn in [1, -1]:
			var line: Array[Vector2i] = []
			for i in range(along):
				line.append(entry + d * i + p * sgn * offset)
			extras.append(line)
		offset += GIFT_LINE_SPACING
	return {"kind": "rect", "cells": cells, "rects": [_cells_bounds(cells)] as Array[Rect2], "anchors": anchors,
		"axis": axis, "extras": extras, "center": entry + d * mid}

## Платформа-"плюс": квадрат 3x3 и четыре луча шириной 3. Обе оси целиком заполнены подарками.
## Выходы: концы трёх лучей, кроме того, откуда пришли.
func _make_plus(entry: Vector2i, d: Vector2i, arm: int) -> Dictionary:
	var p := _perp(d)
	var center := entry + d * (arm + 1)
	var reach := arm + 1
	var bar_a: Array[Vector2i] = []   # луч вдоль направления входа
	var bar_b: Array[Vector2i] = []   # поперечный луч
	for i in range(-reach, reach + 1):
		for j in range(-1, 2):
			bar_a.append(center + d * i + p * j)
			bar_b.append(center + d * j + p * i)
	var union: Dictionary = {}
	for cell in bar_a:
		union[cell] = true
	for cell in bar_b:
		union[cell] = true
	var cells: Array[Vector2i] = []
	for key in union.keys():
		cells.append(key)
	var axis: Array[Vector2i] = []
	for i in range(-reach, reach + 1):
		axis.append(center + d * i)
	for i in range(-reach, reach + 1):
		if i != 0:
			axis.append(center + p * i)
	var anchors: Array[Dictionary] = []
	anchors.append({"cell": center + d * reach, "dir": d, "connector": [] as Array[Vector2i], "used": false})
	anchors.append({"cell": center + p * reach, "dir": p, "connector": [] as Array[Vector2i], "used": false})
	anchors.append({"cell": center - p * reach, "dir": -p, "connector": [] as Array[Vector2i], "used": false})
	return {"kind": "plus", "cells": cells, "rects": [_cells_bounds(bar_a), _cells_bounds(bar_b)] as Array[Rect2],
		"anchors": anchors, "axis": axis, "extras": [], "center": center}

func _random_platform(entry: Vector2i, d: Vector2i) -> Dictionary:
	if rng.randf() < PLUS_CHANCE:
		return _make_plus(entry, d, _pick(PLUS_ARMS))
	return _make_rect(entry, d, _pick(RECT_ALONG), _pick(RECT_ACROSS))

func _bridge_cells(edge_cell: Vector2i, d: Vector2i) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for k in range(1, BRIDGE_LEN + 1):
		for j in range(-1, 2):
			cells.append(edge_cell + d * k + _perp(d) * j)
	return cells

## Клетки может занимать только новая структура; чужие структуры должны быть минимум в клетке от неё
## (исключение - родитель моста). Так контуры никогда не накладываются и не слипаются.
func _cells_free(cells: Array, allowed_owner: int) -> bool:
	for item in cells:
		var cell: Vector2i = item
		if absi(cell.x) > MAX_EXTENT.x or absi(cell.y) > MAX_EXTENT.y:
			return false
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				var occupant: int = int(_occupied.get(cell + Vector2i(dx, dy), -1))
				if occupant != -1 and occupant != allowed_owner:
					return false
	return true

func _register(structure: Dictionary) -> int:
	var index := _plan.size()
	_plan.append(structure)
	for cell in structure["cells"]:
		_occupied[cell] = index
	return index

## Строит один раунд плана. Возвращает true, если арены хватает на все подарки раунда.
func _plan_arena(gift_count: int) -> bool:
	_plan.clear()
	_occupied.clear()
	_skeleton.clear()

	var center_cells: Array[Vector2i] = []
	var hx := CENTER_CELLS.x / 2
	var hy := CENTER_CELLS.y / 2
	for y in range(-hy, hy + 1):
		for x in range(-hx, hx + 1):
			center_cells.append(Vector2i(x, y))
	var center_anchors: Array[Dictionary] = []
	for d in [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]:
		var reach := hy if d.x == 0 else hx
		center_anchors.append({"cell": d * reach, "dir": d, "connector": [] as Array[Vector2i], "used": false})
	_register({"kind": "center", "cells": center_cells, "rects": [_cells_bounds(center_cells)] as Array[Rect2],
		"anchors": center_anchors, "axis": [] as Array[Vector2i], "extras": [], "center": Vector2i.ZERO})

	# Основные ветки от сторон центральной платформы. Каждой достаётся честная доля подарков.
	var order := _shuffled([0, 1, 2, 3])
	var branch_count := clampi(branches, 3, 4)
	var made := 0
	for i in range(branch_count):
		var share := (gift_count - _skeleton.size()) / (branch_count - i)
		if _try_attach(0, int(order[i]), share):
			made += 1
	if made < 3:
		return false

	# Дальше арена растёт из случайных свободных выходов, пока обязательные линии вместе с
	# дополнительными не вместят все подарки раунда.
	while _skeleton.size() + _extra_capacity() < gift_count:
		var candidates: Array = []
		for pi in range(_plan.size()):
			if _plan[pi]["kind"] == "bridge":
				continue
			var anchors: Array = _plan[pi]["anchors"]
			for ai in range(anchors.size()):
				if not anchors[ai]["used"]:
					candidates.append([pi, ai])
		var grown := false
		for candidate in _shuffled(candidates):
			if _try_attach(int(candidate[0]), int(candidate[1]), gift_count - _skeleton.size()):
				grown = true
				break
		if not grown:
			return false
	return true

## Пробует присоединить к выходу мост и случайную платформу. budget - сколько подарков можно потратить
## на их обязательные линии. Возвращает true, если присоединено.
func _try_attach(parent: int, anchor_index: int, budget: int) -> bool:
	var anchors: Array = _plan[parent]["anchors"]
	var anchor: Dictionary = anchors[anchor_index]
	if anchor["used"]:
		return false
	var d: Vector2i = anchor["dir"]
	var edge: Vector2i = anchor["cell"]
	var connector: Array = anchor["connector"]
	var bridge_cells := _bridge_cells(edge, d)
	if not _cells_free(bridge_cells, parent):
		return false
	var entry := edge + d * (BRIDGE_LEN + 1)
	for attempt in range(14):
		var platform := _random_platform(entry, d)
		var axis: Array = platform["axis"]
		var cost := connector.size() + BRIDGE_LEN + axis.size()
		if cost > budget:
			continue
		if not _cells_free(platform["cells"], -2):
			continue
		# Мост и платформа не должны касаться друг друга иначе, чем по стыку.
		var bridge := {"kind": "bridge", "cells": bridge_cells, "rects": [_cells_bounds(bridge_cells)] as Array[Rect2],
			"anchors": [] as Array[Dictionary], "axis": [] as Array[Vector2i], "extras": [], "center": edge}
		_register(bridge)
		_register(platform)
		anchor["used"] = true
		for cell in connector:
			_skeleton[cell] = true
		for k in range(1, BRIDGE_LEN + 1):
			_skeleton[edge + d * k] = true
		for cell in axis:
			_skeleton[cell] = true
		# Вход платформы - это и есть конец моста: этот выход занят.
		return true
	return false

## Линии дополнительных подарков (без клеток обязательных линий и без повторов).
func _extra_lines() -> Array:
	var seen: Dictionary = {}
	var lines: Array = []
	for structure in _plan:
		for raw_line in structure["extras"]:
			var line: Array[Vector2i] = []
			for cell in raw_line:
				if not _skeleton.has(cell) and not seen.has(cell):
					seen[cell] = true
					line.append(cell)
			if not line.is_empty():
				lines.append(line)
	return lines

func _extra_capacity() -> int:
	var total := 0
	for line in _extra_lines():
		total += line.size()
	return total

# ---------------------------------------------------------------- построение узлов

func _build_arena() -> void:
	var center_size := Vector2(CENTER_CELLS) * TILE_SIZE
	_add_platform(Vector2.ZERO, center_size, PLATFORM_COLOR, "Центральная платформа")
	placed_rects.append(Rect2(-center_size * 0.5, center_size))
	_add_center_mark()

	for index in range(1, _plan.size()):
		var structure: Dictionary = _plan[index]
		var rects: Array = structure["rects"]
		var node: Node2D
		match String(structure["kind"]):
			"bridge":
				var bridge_rect: Rect2 = rects[0]
				_add_bridge(bridge_rect.get_center(), bridge_rect.size)
				node = generated_structures.back()
			"plus":
				node = _add_plus(structure["center"], structure["cells"], rects)
			_:
				var platform_rect: Rect2 = rects[0]
				_add_platform(platform_rect.get_center(), platform_rect.size, PLATFORM_COLOR, "Платформа")
				node = generated_structures.back()
		for piece in rects:
			placed_rects.append(piece)
		buildable_structures.append(node)
		structure_rects[node] = rects

## Раскладывает ровно gift_count подарков (меньше - только если арена не смогла вместить столько):
## обязательные линии целиком, остаток - дополнительные линии: заполняются целиком, неполной может
## быть только последняя.
func _layout_gifts(gift_count: int) -> void:
	var cells: Array[Vector2i] = []
	for key in _skeleton.keys():
		cells.append(key)
	var left := gift_count - cells.size()
	if left > 0:
		for line in _shuffled(_extra_lines()):
			if left <= 0:
				break
			var take := mini(left, line.size())
			for k in range(take):
				cells.append(line[k])
			left -= take
	for cell in cells:
		gift_points.append(Vector2(cell) * TILE_SIZE)

## Точки подарков текущего раунда (локальные координаты арены).
func get_gift_points() -> Array[Vector2]:
	return gift_points

## Возвращает true, если точка персонажа находится на любой платформе или мосту.
## Координаты проверяются в локальном пространстве генератора, поэтому метод работает
## и в случае, если вся арена позже будет смещена.
func is_position_supported(world_position: Vector2) -> bool:
	var local_position := to_local(world_position)
	for rect in placed_rects:
		if rect.has_point(local_position):
			return true
	return false

## Структура обрушилась: она перестаёт быть опорой. Возвращает её прямоугольники (локальные
## координаты), чтобы убрать подарки, лежавшие на ней. Визуальное падение делает вызывающий.
func remove_structure_support(structure: Node2D) -> Array[Rect2]:
	var removed: Array[Rect2] = []
	if not structure_rects.has(structure):
		return removed
	for rect in structure_rects[structure]:
		removed.append(rect)
		placed_rects.erase(rect)
	structure_rects.erase(structure)
	buildable_structures.erase(structure)
	return removed

## Платформа-"плюс": тайлы и контур строятся по набору клеток, а не по прямоугольнику.
func _add_plus(center_cell: Vector2i, cells: Array, rects: Array) -> Node2D:
	var structure := Node2D.new()
	structure.name = "Платформа-плюс"
	structure.position = Vector2(center_cell) * TILE_SIZE
	add_child(structure)
	generated_structures.append(structure)

	for rect in rects:
		var base := Polygon2D.new()
		base.name = "SurfaceBase"
		base.color = PLATFORM_COLOR
		base.polygon = _rectangle_points(rect.size)
		base.position = rect.get_center() - structure.position
		base.z_index = 0
		structure.add_child(base)

	for item in cells:
		var cell: Vector2i = item
		var tile := Polygon2D.new()
		tile.name = "CheckerTile"
		tile.position = Vector2(cell - center_cell) * TILE_SIZE
		tile.polygon = _rectangle_points(Vector2(TILE_SIZE - TILE_GAP, TILE_SIZE - TILE_GAP))
		# Чётность по мировой сетке: шахматка продолжается через стыки с мостами.
		var is_light := (cell.x + cell.y) % 2 == 0
		tile.color = TILE_VARIATION[rng.randi_range(0, TILE_VARIATION.size() - 1)] if is_light else TILE_DARK
		tile.z_index = 1
		structure.add_child(tile)
		if is_light and (cell.x + cell.y * 3) % 11 == 0:
			var stain := Polygon2D.new()
			stain.name = "SurfaceStain"
			stain.color = Color("776c89", 0.28)
			stain.position = tile.position + Vector2(rng.randf_range(-7.0, 7.0), rng.randf_range(-7.0, 7.0))
			stain.polygon = _rectangle_points(Vector2(rng.randf_range(5.0, 13.0), rng.randf_range(3.0, 8.0)))
			stain.rotation = rng.randf_range(-0.6, 0.6)
			stain.z_index = 2
			structure.add_child(stain)

	_add_cells_outline(structure, cells, center_cell)
	return structure

## Тёмная окантовка по внешней границе набора клеток: подряд идущие граничные стороны сливаются в одну линию.
func _add_cells_outline(parent: Node2D, cells: Array, center_cell: Vector2i) -> void:
	var cell_set: Dictionary = {}
	for cell in cells:
		cell_set[cell] = true
	var runs: Dictionary = {}  # ключ "направление/линия" -> {"dir": Vector2i, "line": int, "vals": Array[int]}
	for item in cells:
		var cell: Vector2i = item
		for d in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
			if cell_set.has(cell + d):
				continue
			var horizontal: bool = d.y != 0
			var line_coord: int = cell.y if horizontal else cell.x
			var along: int = cell.x if horizontal else cell.y
			var key := "%d_%d_%d" % [d.x, d.y, line_coord]
			if not runs.has(key):
				runs[key] = {"dir": d, "line": line_coord, "vals": []}
			runs[key]["vals"].append(along)

	for key in runs.keys():
		var run: Dictionary = runs[key]
		var d: Vector2i = run["dir"]
		var horizontal: bool = d.y != 0
		var vals: Array = run["vals"]
		vals.sort()
		var group_start := 0
		for i in range(1, vals.size() + 1):
			if i < vals.size() and int(vals[i]) == int(vals[i - 1]) + 1:
				continue
			var first := float(int(vals[group_start]) - (center_cell.x if horizontal else center_cell.y)) - 0.5
			var last := float(int(vals[i - 1]) - (center_cell.x if horizontal else center_cell.y)) + 0.5
			var fixed := (float(int(run["line"]) - (center_cell.y if horizontal else center_cell.x)) + 0.5 * float(d.y if horizontal else d.x)) * TILE_SIZE
			var inward := -1.5 * float(d.y if horizontal else d.x)
			_add_outline_line(parent, horizontal, first * TILE_SIZE, last * TILE_SIZE, fixed, 10.0, Color("080b11"), 3, 0.0)
			_add_outline_line(parent, horizontal, first * TILE_SIZE + 1.5, last * TILE_SIZE - 1.5, fixed, 2.0, OUTLINE_COLOR, 4, inward)
			group_start = i

func _add_outline_line(parent: Node2D, horizontal: bool, from_along: float, to_along: float, fixed: float,
		width: float, color: Color, z: int, shift: float) -> void:
	var line := Line2D.new()
	line.name = "PlusRim"
	line.width = width
	line.default_color = color
	line.begin_cap_mode = Line2D.LINE_CAP_BOX
	line.end_cap_mode = Line2D.LINE_CAP_BOX
	if horizontal:
		line.points = PackedVector2Array([Vector2(from_along, fixed + shift), Vector2(to_along, fixed + shift)])
	else:
		line.points = PackedVector2Array([Vector2(fixed + shift, from_along), Vector2(fixed + shift, to_along)])
	line.z_index = z
	parent.add_child(line)

func _create_background() -> void:
	var background := ColorRect.new()
	background.name = "ArenaVoidBackground"
	background.color = Color("061719")
	background.position = Vector2(-5000.0, -5000.0)
	background.size = Vector2(10000.0, 10000.0)
	background.z_index = -100
	add_child(background)

func _add_platform(center: Vector2, size: Vector2, color: Color, structure_name: String) -> void:
	var structure := Node2D.new()
	structure.name = structure_name
	structure.position = center
	add_child(structure)
	generated_structures.append(structure)

	_add_checker_surface(structure, size, color)
	_add_outline(structure, size)

func _add_bridge(center: Vector2, size: Vector2) -> void:
	var structure := Node2D.new()
	structure.name = "Мост"
	structure.position = center
	add_child(structure)
	generated_structures.append(structure)

	_add_checker_surface(structure, size, BRIDGE_COLOR)
	_add_bridge_rim(structure, size)

func _add_checker_surface(parent: Node2D, size: Vector2, base_color: Color) -> void:
	# Dark base under the checkerboard keeps narrow gaps between tiles readable.
	var base := Polygon2D.new()
	base.name = "SurfaceBase"
	base.color = base_color
	base.polygon = _rectangle_points(size)
	base.z_index = 0
	parent.add_child(base)

	var columns := roundi(size.x / TILE_SIZE)
	var rows := roundi(size.y / TILE_SIZE)
	var start_x := -float(columns) * TILE_SIZE * 0.5
	var start_y := -float(rows) * TILE_SIZE * 0.5

	for y in range(rows):
		for x in range(columns):
			var tile_size := Vector2(TILE_SIZE - TILE_GAP, TILE_SIZE - TILE_GAP)
			var tile := Polygon2D.new()
			tile.name = "CheckerTile"
			tile.position = Vector2(start_x + (float(x) + 0.5) * TILE_SIZE, start_y + (float(y) + 0.5) * TILE_SIZE)
			tile.polygon = _rectangle_points(tile_size)
			# Чётность считаем по мировой сетке, чтобы шахматка продолжалась через стыки.
			var world_pos := parent.position + tile.position
			var gx := floori((world_pos.x + TILE_SIZE * 0.5) / TILE_SIZE + 0.001)
			var gy := floori((world_pos.y + TILE_SIZE * 0.5) / TILE_SIZE + 0.001)
			var is_light := (gx + gy) % 2 == 0
			if is_light:
				tile.color = TILE_VARIATION[rng.randi_range(0, TILE_VARIATION.size() - 1)]
			else:
				tile.color = TILE_DARK
			tile.z_index = 1
			parent.add_child(tile)

			# Occasional muted stains make the surface less sterile without obscuring the grid.
			if (x + y * 3 + int(parent.position.x)) % 11 == 0 and is_light:
				var stain := Polygon2D.new()
				stain.name = "SurfaceStain"
				stain.color = Color("776c89", 0.28)
				stain.position = tile.position + Vector2(rng.randf_range(-7.0, 7.0), rng.randf_range(-7.0, 7.0))
				stain.polygon = _rectangle_points(Vector2(rng.randf_range(5.0, 13.0), rng.randf_range(3.0, 8.0)))
				stain.rotation = rng.randf_range(-0.6, 0.6)
				stain.z_index = 2
				parent.add_child(stain)

func _add_outline(parent: Node2D, size: Vector2) -> void:
	# Thick dark rim hints at the original 3D platforms, while keeping the camera strictly top-down.
	var rim := Line2D.new()
	rim.name = "DarkRim"
	rim.width = 10.0
	rim.default_color = Color("080b11")
	rim.closed = true
	rim.points = _rectangle_points(size)
	rim.z_index = 3
	parent.add_child(rim)

	var outline := Line2D.new()
	outline.name = "Outline"
	outline.width = 2.0
	outline.default_color = OUTLINE_COLOR
	outline.closed = true
	outline.points = _rectangle_points(size - Vector2(3.0, 3.0))
	outline.z_index = 4
	parent.add_child(outline)

func _add_bridge_rim(parent: Node2D, size: Vector2) -> void:
	# Рисуем только длинные стороны моста, торцы не рисуем - иначе на стыке с платформой двойная рамка.
	var half_x := size.x * 0.5
	var half_y := size.y * 0.5
	var horizontal := size.x >= size.y
	for side in [-1.0, 1.0]:
		var rim := Line2D.new()
		rim.name = "DarkRimSide"
		rim.width = 7.0
		rim.default_color = Color("080b11")
		if horizontal:
			rim.points = PackedVector2Array([Vector2(-half_x, half_y * side), Vector2(half_x, half_y * side)])
		else:
			rim.points = PackedVector2Array([Vector2(half_x * side, -half_y), Vector2(half_x * side, half_y)])
		rim.z_index = 3
		parent.add_child(rim)

func _add_center_mark() -> void:
	var mark := Polygon2D.new()
	mark.name = "CenterBeaconMarker"
	mark.color = Color(ACCENT_COLOR, 0.75)
	mark.polygon = _regular_polygon(10, 20.0)
	mark.position = Vector2.ZERO
	mark.z_index = 2
	add_child(mark)
	generated_structures.append(mark)

func _rectangle_points(size: Vector2) -> PackedVector2Array:
	var half := size * 0.5
	return PackedVector2Array([
		Vector2(-half.x, -half.y),
		Vector2(half.x, -half.y),
		Vector2(half.x, half.y),
		Vector2(-half.x, half.y)
	])

func _regular_polygon(sides: int, radius: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in range(sides):
		var angle := TAU * float(i) / float(sides)
		points.append(Vector2(cos(angle), sin(angle)) * radius)
	return points
