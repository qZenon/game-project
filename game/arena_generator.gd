extends Node2D

## Первый этап генерации арены: центральная платформа и соединённые структуры.
## Геометрия создаётся из заранее заданных типов сегментов, а не из отдельных тайлов.

@export var arena_seed: int = 0
@export_range(3, 6, 1) var branches: int = 4
## Номер раунда: от него зависит число подарков и размеры платформ (см. _pick_size_tier).
@export_range(1, 16, 1) var round_number: int = 1

const TILE_SIZE := 42.0

# Все размеры заданы в ТАЙЛАХ (x = вдоль направления ветки, y = поперёк).
# Так края платформ всегда попадают ровно на сетку и стыкуются без щелей.
# Поперечные размеры нечётные, чтобы мост в 3 тайла стоял строго по центру.
const CENTER_TILES := Vector2i(9, 7)   # центральная платформа (ширина x высота)
const BRIDGE_TILES := Vector2i(4, 3)   # мост: длина x ширина
const ISLAND_TILES := Vector2i(5, 5)   # остров (размер уровня 0 = эталонная геометрия)
const FAR_TILES := Vector2i(5, 7)      # дальняя площадка (размер уровня 0)
const MAX_SIZE_TIER := 6               # на каждый уровень остров/площадка растут на +1 вдоль и +2 поперёк

# Подарки: базовое количество по раундам (дизайн-документ, п. 11.3).
const GIFTS_PER_ROUND: Array[int] = [60, 66, 73, 80, 88, 97, 106, 117, 128, 141, 155, 171, 188, 207, 228, 251]
# Подарки лежат на прямых линиях вдоль ветки: внутри линии - каждый тайл (равный шаг),
# соседние линии разнесены на GIFT_LINE_SPACING_TILES тайлов.
const GIFT_LINE_SPACING_TILES := 2
const SIDE_ISLAND_CHANCE := 0.55
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
var placed_rects: Array[Rect2] = []  # занятые области, чтобы платформы не накладывались
var gift_zones: Array[Dictionary] = []  # {"rect": Rect2, "direction": Vector2}: структуры для подарков (без центра)
var gift_points: Array[Vector2] = []    # итоговые точки подарков текущего раунда (локальные координаты)
var size_tier: int = 0                  # текущий уровень размеров платформ

func _ready() -> void:
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
    gift_zones.clear()
    gift_points.clear()

    var center_size := Vector2(CENTER_TILES) * TILE_SIZE
    _add_platform(Vector2.ZERO, center_size, PLATFORM_COLOR, "Центральная платформа")
    placed_rects.append(Rect2(-center_size * 0.5, center_size))
    _add_center_mark()

    var directions: Array[Vector2] = [Vector2.UP, Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT]
    # Перемешиваем порядок ветвей, чтобы варианты арены отличались друг от друга.
    for i in range(directions.size() - 1, 0, -1):
        var j := rng.randi_range(0, i)
        var swap := directions[i]
        directions[i] = directions[j]
        directions[j] = swap

    # Сначала ВСЕ основные ветки, и только потом боковые - иначе боковой
    # остров может занять место, нужное основной ветке.
    var islands: Array[Rect2] = []
    var branch_count := clampi(branches, 3, 4)
    size_tier = _pick_size_tier(GIFTS_PER_ROUND[clampi(round_number, 1, GIFTS_PER_ROUND.size()) - 1], branch_count)
    for i in range(branch_count):
        islands.append(_create_main_branch(directions[i]))

    for i in range(branch_count):
        if rng.randf() < SIDE_ISLAND_CHANCE:
            _try_create_side_branch(directions[i], islands[i])

    _layout_gifts(GIFTS_PER_ROUND[clampi(round_number, 1, GIFTS_PER_ROUND.size()) - 1])

## Размер в пикселях с учётом направления: "вдоль" ветки это x для горизонтали и y для вертикали.
func _oriented_size(tiles: Vector2i, direction: Vector2) -> Vector2:
    var along := float(tiles.x) * TILE_SIZE
    var across := float(tiles.y) * TILE_SIZE
    if absf(direction.x) > 0.5:
        return Vector2(along, across)
    return Vector2(across, along)

## Половина размера прямоугольника вдоль направления (расстояние от центра до края).
func _half_extent(size: Vector2, direction: Vector2) -> float:
    return (absf(direction.x) * size.x + absf(direction.y) * size.y) * 0.5

## Считает прямоугольники цепочки сегментов, каждый начинается ровно там, где закончился предыдущий.
func _plan_chain(start_edge: Vector2, direction: Vector2, chain: Array) -> Array[Rect2]:
    var rects: Array[Rect2] = []
    var edge := start_edge
    for segment in chain:
        var size := _oriented_size(segment["tiles"], direction)
        var center := edge + direction * _half_extent(size, direction)
        rects.append(Rect2(center - size * 0.5, size))
        edge = center + direction * _half_extent(size, direction)
    return rects

func _chain_fits(rects: Array[Rect2]) -> bool:
    for rect in rects:
        # grow(-1) - чтобы платформы, которые просто касаются краями, не считались наложением.
        var inner := rect.grow(-1.0)
        for placed in placed_rects:
            if inner.intersects(placed):
                return false
    return true

func _commit_chain(rects: Array[Rect2], chain: Array, direction: Vector2) -> void:
    for i in range(rects.size()):
        var rect := rects[i]
        var segment: Dictionary = chain[i]
        if segment["bridge"]:
            _add_bridge(rect.get_center(), rect.size)
        else:
            _add_platform(rect.get_center(), rect.size, PLATFORM_COLOR, segment["name"])
        placed_rects.append(rect)
        gift_zones.append({"rect": rect, "direction": direction})

## Основная ветка: мост -> остров -> мост -> дальняя площадка. Возвращает прямоугольник острова.
func _create_main_branch(direction: Vector2) -> Rect2:
    var center_size := Vector2(CENTER_TILES) * TILE_SIZE
    var start_edge := direction * _half_extent(center_size, direction)
    var chain := [
        {"tiles": BRIDGE_TILES, "bridge": true},
        {"tiles": _island_tiles(), "bridge": false, "name": "Остров"},
        {"tiles": BRIDGE_TILES, "bridge": true},
        {"tiles": _far_tiles(), "bridge": false, "name": "Дальняя площадка"},
    ]
    var rects := _plan_chain(start_edge, direction, chain)
    _commit_chain(rects, chain, direction)
    return rects[1]

## Боковое ответвление от острова под прямым углом. Если место занято - просто не создаётся.
func _try_create_side_branch(direction: Vector2, island_rect: Rect2) -> void:
    var perpendicular := Vector2(-direction.y, direction.x)
    if rng.randf() < 0.5:
        perpendicular = -perpendicular

    var start_edge := island_rect.get_center() + perpendicular * _half_extent(island_rect.size, perpendicular)
    var chain := [
        {"tiles": BRIDGE_TILES, "bridge": true},
        {"tiles": _island_tiles(), "bridge": false, "name": "Боковой остров"},
    ]
    var rects := _plan_chain(start_edge, perpendicular, chain)
    if _chain_fits(rects):
        _commit_chain(rects, chain, perpendicular)

## Возвращает true, если точка персонажа находится на любой платформе или мосту.
## Координаты проверяются в локальном пространстве генератора, поэтому метод работает
## и в случае, если вся арена позже будет смещена.
func is_position_supported(world_position: Vector2) -> bool:
    var local_position := to_local(world_position)
    for rect in placed_rects:
        if rect.has_point(local_position):
            return true
    return false

## ---------------------------------------------------------------- подарки

func _island_tiles() -> Vector2i:
    return ISLAND_TILES + Vector2i(size_tier, 2 * size_tier)

func _far_tiles() -> Vector2i:
    return FAR_TILES + Vector2i(size_tier, 2 * size_tier)

## Сколько линий подарков помещается поперёк структуры (центральная + пары через шаг линий).
func _line_count(across_tiles: int) -> int:
    var half := (across_tiles - 1) / 2
    return 1 + 2 * (half / GIFT_LINE_SPACING_TILES)

func _zone_capacity(along_tiles: int, across_tiles: int) -> int:
    return _line_count(across_tiles) * along_tiles

## Вместимость одной основной ветки (2 моста + остров + дальняя площадка) для уровня размеров.
func _main_branch_capacity(tier: int) -> int:
    var island := ISLAND_TILES + Vector2i(tier, 2 * tier)
    var far := FAR_TILES + Vector2i(tier, 2 * tier)
    return 2 * _zone_capacity(BRIDGE_TILES.x, BRIDGE_TILES.y) \
        + _zone_capacity(island.x, island.y) + _zone_capacity(far.x, far.y)

## Самый маленький уровень размеров, при котором основные ветки вмещают все подарки раунда.
## Уровень 0 - эталонная геометрия; боковые острова дают дополнительную вместимость сверх этого.
func _pick_size_tier(gift_count: int, branch_count: int) -> int:
    for tier in range(MAX_SIZE_TIER + 1):
        if _main_branch_capacity(tier) * branch_count >= gift_count:
            return tier
    return MAX_SIZE_TIER

## Точки одной структуры: линии идут вдоль ветки от её начала к концу, сначала центральная
## линия, затем соседние через равные промежутки. Шаг внутри линии - ровно один тайл.
func _zone_gift_points(zone: Dictionary) -> Array[Vector2]:
    var rect: Rect2 = zone["rect"]
    var direction: Vector2 = zone["direction"]
    var perpendicular := Vector2(-direction.y, direction.x)
    var along_tiles := roundi(_half_extent(rect.size, direction) * 2.0 / TILE_SIZE)
    var across_tiles := roundi(_half_extent(rect.size, perpendicular) * 2.0 / TILE_SIZE)
    var half_lines := _line_count(across_tiles) / 2
    var offsets: Array[int] = [0]
    for k in range(1, half_lines + 1):
        offsets.append(k * GIFT_LINE_SPACING_TILES)
        offsets.append(-k * GIFT_LINE_SPACING_TILES)

    var points: Array[Vector2] = []
    var center := rect.get_center()
    for offset in offsets:
        for i in range(along_tiles):
            var along := (float(i) - float(along_tiles - 1) * 0.5) * TILE_SIZE
            points.append(center + direction * along + perpendicular * float(offset) * TILE_SIZE)
    return points

## Раскладывает ровно gift_count подарков по структурам пропорционально их вместимости.
## Так подарки равномерно распределены по арене, а каждая линия остаётся прямой и с равным шагом.
func _layout_gifts(gift_count: int) -> void:
    var zone_points: Array = []
    var total_capacity := 0
    for zone in gift_zones:
        var points := _zone_gift_points(zone)
        zone_points.append(points)
        total_capacity += points.size()

    var target := mini(gift_count, total_capacity)
    var quotas: Array[int] = []
    var remainders: Array[float] = []
    var assigned := 0
    for points in zone_points:
        var exact := float(target) * float(points.size()) / float(total_capacity)
        var quota := mini(int(floor(exact)), points.size())
        quotas.append(quota)
        remainders.append(exact - float(quota))
        assigned += quota

    # Недостающие подарки (из-за округления вниз) отдаём структурам с наибольшим остатком.
    while assigned < target:
        var best := -1
        for i in range(quotas.size()):
            if quotas[i] >= zone_points[i].size():
                continue
            if best == -1 or remainders[i] > remainders[best]:
                best = i
        if best == -1:
            break
        quotas[best] += 1
        remainders[best] = -1.0
        assigned += 1

    for i in range(zone_points.size()):
        for j in range(quotas[i]):
            gift_points.append(zone_points[i][j])

## Точки подарков текущего раунда (локальные координаты арены).
func get_gift_points() -> Array[Vector2]:
    return gift_points

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
