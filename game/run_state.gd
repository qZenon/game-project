extends RefCounted

## Пункт 21.13: состояние забега, общее для лобби, арены и будущих систем.
##
## Скрипт хранит данные только в статических переменных (они живут между сценами) и ни разу
## не создаётся как объект. Подключение: const RUN := preload("res://game/run_state.gd").
##
## Здесь же правила последовательности раундов (дизайн, п. 3), выбор врагов и проклятий
## с лимитами (п. 13, 14), доступность и цены улучшений (п. 15) и тексты для пьедесталов.
## Сами эффекты врагов, проклятий и улучшений подключаются в 21.14 и 21.15: пока они
## только записываются в состояние забега.

enum Stage { ENEMY, CURSE, UPGRADE, FINAL }

const FINAL_ROUND := 16
const ENEMY_PICK_LIMIT := 4
const PRICE_GROWTH := 1.05  # п. 15.1: P = ceil(P0 * 1,05^(n-1)), n - раунд покупки

const ENEMY_IDS: Array[String] = ["slash", "mimic", "operator"]
const CURSE_IDS: Array[String] = ["displacement", "no_time_to_think", "closing_gap", "deep_cuts", "jackpot"]
const UPGRADE_IDS: Array[String] = ["overdrive", "license", "second_chance", "gift_radar", "rapid_recalibration"]

## Лимиты выборов проклятий. -1 - лимит не определён (открытый вопрос п. 22: Displacement, Jackpot).
const CURSE_LIMITS := {
    "displacement": -1,
    "no_time_to_think": 2,
    "closing_gap": 3,
    "deep_cuts": 2,
    "jackpot": -1,
}

# Значения эффектов по числу выборов (п. 13, 14). Нужны для подсказок на пьедесталах.
const SLASH_INTERVALS: Array[int] = [15, 13, 11, 9]      # секунд между сериями при 1-4 выборах
const OPERATOR_INTERVALS: Array[int] = [25, 20, 15, 10]  # секунд между появлениями при 1-4 выборах
const OPERATOR_REACTION: Array[float] = [3.0, 1.5, 0.75]  # No Time to Think: 0, 1, 2 проклятия
const MIMIC_DELAY: Array[float] = [2.0, 1.5, 1.0, 0.5]    # Closing Gap: 0-3 проклятия
const SLASH_BASE_COUNT := 2

const ENEMIES := {
    "slash": {
        "name": "Slash",
        "desc": "Разрез-линия через всю арену проходит через вашу позицию. На уклонение даётся 1 секунда.",
    },
    "mimic": {
        "name": "Mimic",
        "desc": "Чёрная копия повторяет ваш путь с задержкой. Столкновение с ней смертельно.",
    },
    "operator": {
        "name": "Operator",
        "desc": "Индикатор идёт от зелёного к красному. Полностью остановитесь вовремя, иначе — гибель.",
    },
}

const CURSES := {
    "displacement": {
        "name": "Displacement",
        "desc": "В начале раунда вы появляетесь в случайной точке платформы. Рядом может оказаться враг, защиты нет.",
    },
    "no_time_to_think": {
        "name": "No Time to Think",
        "desc": "Вдвое сокращает время реакции на Operator.",
    },
    "closing_gap": {
        "name": "Closing Gap",
        "desc": "Сокращает задержку, с которой Mimic повторяет ваш путь.",
    },
    "deep_cuts": {
        "name": "Deep Cuts",
        "desc": "В каждую серию Slash добавляется ещё один разрез.",
    },
    "jackpot": {
        "name": "Jackpot",
        "desc": "Каждый раунд: 50% — награда обнуляется, 50% — удваивается (после License).",
    },
}

## min_round - с какого раунда улучшение появляется в лобби; prices - базовые цены уровней (P0);
## levels - что даёт каждый уровень.
const UPGRADES := {
    "overdrive": {
        "name": "Overdrive",
        "desc": "Увеличивает скорость передвижения.",
        "min_round": 3,
        "prices": [10, 15, 25],
        "levels": ["Скорость x1,5", "Скорость x2", "Скорость x2,5"],
    },
    "license": {
        "name": "License",
        "desc": "Увеличивает награду за раунд.",
        "min_round": 3,
        "prices": [15, 25, 40],
        "levels": ["Награда x1,5", "Награда x2", "Награда x2,5"],
    },
    "second_chance": {
        "name": "Second Chance",
        "desc": "Предотвращает смертельный удар Slash, Mimic или Operator. От Void Death не защищает. Заряды восстанавливаются в начале каждого раунда.",
        "min_round": 6,
        "prices": [20, 20],
        "levels": ["Зарядов: 1", "Зарядов: 2"],
    },
    "gift_radar": {
        "name": "Gift Radar",
        "desc": "Золотая стрелка у персонажа указывает на ближайший подарок. Покупается один раз за забег.",
        "min_round": 9,
        "prices": [10],
        "levels": ["Стрелка к ближайшему подарку"],
    },
    "rapid_recalibration": {
        "name": "Rapid Recalibration",
        "desc": "Только для Телепортера: сокращает перезарядку телепортации.",
        "min_round": 9,
        "teleporter_only": true,
        "prices": [15, 25],
        "levels": ["Перезарядка 10 с", "Перезарядка 5 с"],
    },
}

const ROMAN: Array[String] = ["", "I", "II", "III", "IV", "V"]

# ---------------------------------------------------------------- состояние забега

static var round_number: int = 1
## "normal" или "teleporter". Выбор класса появится в 21.15.
static var player_class: String = "normal"
static var enemy_picks: Dictionary = {}     # id врага -> сколько раз выбран
static var curse_picks: Dictionary = {}     # id проклятия -> сколько раз выбрано
static var upgrade_levels: Dictionary = {}  # id улучшения -> текущий уровень
## Золотые подарки забега: валюта для улучшений, теряется вместе с забегом.
static var golden_gifts: int = 0
static var second_chance_charges: int = 0

## Новый забег: всё состояние забега сбрасывается (п. 23: смерть сбрасывает забег).
static func start_run(selected_class: String = "normal") -> void:
    round_number = 1
    player_class = selected_class
    enemy_picks.clear()
    curse_picks.clear()
    upgrade_levels.clear()
    golden_gifts = 0
    second_chance_charges = 0
    # Золотая вспышка перехода не должна переходить в новый забег из прошлого.
    if Engine.has_meta("nullscape_gold_flash"):
        Engine.remove_meta("nullscape_gold_flash")

## Игрок переходит в лобби раунда n: восстанавливается то, что даёт каждое лобби (п. 9).
static func enter_round_lobby(n: int) -> void:
    round_number = clampi(n, 1, FINAL_ROUND)
    # Second Chance восстанавливает заряды до купленного максимума.
    # Кулдаун Телепортера (21.15) сбрасывается здесь же.
    second_chance_charges = upgrade_level("second_chance")

## Награда раунда попадает в баланс забега. Пока без множителей: License, Jackpot и
## Trip Coins (п. 11.2) подключит 21.15 именно в этом месте.
static func add_golden_gifts(amount: int) -> void:
    golden_gifts += maxi(0, amount)

## Second Chance: тратит один заряд и возвращает true, если удар удалось предотвратить (п. 15, 16).
static func consume_second_chance() -> bool:
    if second_chance_charges <= 0:
        return false
    second_chance_charges -= 1
    return true

## Интервал между сериями Slash при текущем числе выборов: 15, 13, 11, 9 секунд (п. 13.1).
static func slash_interval() -> float:
    var index := clampi(enemy_count("slash") - 1, 0, SLASH_INTERVALS.size() - 1)
    return float(SLASH_INTERVALS[index])

## Разрезов в серии Slash: 2, плюс по одному за каждый Deep Cuts (максимум два).
static func slash_series_count() -> int:
    return SLASH_BASE_COUNT + mini(curse_count("deep_cuts"), 2)

## Контекст для советов во время подготовки арены (RoundController.run_context).
static func get_run_context() -> Dictionary:
    var enemies: Array[String] = []
    for id in ENEMY_IDS:
        if enemy_count(id) > 0:
            enemies.append(id)
    var curses: Array[String] = []
    for id in CURSE_IDS:
        if curse_count(id) > 0:
            curses.append(id)
    return {"class": player_class, "enemies": enemies, "curses": curses}

# ---------------------------------------------------------------- последовательность раундов

## 1,4,7,10,13 - враг; 2,5,8,11,14 - проклятие; 3,6,9,12,15 - улучшения; 16 - финал.
static func stage_of(round_no: int) -> Stage:
    if round_no >= FINAL_ROUND:
        return Stage.FINAL
    match round_no % 3:
        1:
            return Stage.ENEMY
        2:
            return Stage.CURSE
    return Stage.UPGRADE

static func stage_name(round_no: int) -> String:
    var stage := stage_of(round_no)
    if stage == Stage.FINAL:
        return "ФИНАЛЬНЫЙ РАУНД"
    if stage == Stage.ENEMY:
        return "Выбор врага"
    if stage == Stage.CURSE:
        return "Выбор проклятия"
    return "Улучшения"

# ---------------------------------------------------------------- враги и проклятия

static func enemy_count(id: String) -> int:
    return int(enemy_picks.get(id, 0))

static func curse_count(id: String) -> int:
    return int(curse_picks.get(id, 0))

## Лимит выбора: у каждого типа врага 4 раза за забег (п. 3), у проклятий - свой (п. 14).
static func pick_limit(kind: String, id: String) -> int:
    if kind == "enemy":
        return ENEMY_PICK_LIMIT
    return int(CURSE_LIMITS.get(id, -1))

static func pick_count(kind: String, id: String) -> int:
    return enemy_count(id) if kind == "enemy" else curse_count(id)

static func can_pick(kind: String, id: String) -> bool:
    var limit := pick_limit(kind, id)
    return limit < 0 or pick_count(kind, id) < limit

## Записывает выбор. Возвращает {"ok": bool, "reason": String, "message": String}.
static func pick(kind: String, id: String) -> Dictionary:
    if not can_pick(kind, id):
        return {"ok": false, "reason": "Максимум достигнут", "message": ""}
    var definitions: Dictionary = ENEMIES if kind == "enemy" else CURSES
    var entry: Dictionary = definitions[id]
    if kind == "enemy":
        enemy_picks[id] = enemy_count(id) + 1
    else:
        curse_picks[id] = curse_count(id) + 1
    var label := "Враг" if kind == "enemy" else "Проклятие"
    return {"ok": true, "reason": "", "message": "%s: %s" % [label, entry["name"]]}

## Данные пьедестала выбора: название, описание, строка деталей, доступность.
static func choice_info(kind: String, id: String) -> Dictionary:
    var definitions: Dictionary = ENEMIES if kind == "enemy" else CURSES
    var entry: Dictionary = definitions[id]
    var count := pick_count(kind, id)
    var limit := pick_limit(kind, id)
    var lines: Array[String] = []
    var effect := _choice_effect(id, count, limit)
    if effect != "":
        lines.append(effect)
    if limit >= 0:
        lines.append("Выбрано: %d из %d" % [count, limit])
    else:
        lines.append("Выбрано: %d" % count)
    var available := can_pick(kind, id)
    return {
        "title": entry["name"],
        "desc": entry["desc"],
        "effect": effect,
        "detail": "\n".join(lines),
        "available": available,
        "reason": "" if available else "Максимум достигнут",
        "icon": id,
    }

## Что изменится после очередного выбора. count - сколько раз уже выбрано.
static func _choice_effect(id: String, count: int, limit: int) -> String:
    var at_limit := limit >= 0 and count >= limit
    match id:
        "slash":
            if at_limit:
                return ""
            var series := SLASH_BASE_COUNT + curse_count("deep_cuts")
            return "Серия из %d разрезов каждые %d с" % [series, SLASH_INTERVALS[mini(count, SLASH_INTERVALS.size() - 1)]]
        "mimic":
            var delay: float = MIMIC_DELAY[mini(curse_count("closing_gap"), MIMIC_DELAY.size() - 1)]
            return "Задержка копии: %s с" % fmt_num(delay)
        "operator":
            if at_limit:
                return ""
            var reaction: float = OPERATOR_REACTION[mini(curse_count("no_time_to_think"), OPERATOR_REACTION.size() - 1)]
            return "Появляется каждые %d с, время реакции %s с" % [OPERATOR_INTERVALS[mini(count, OPERATOR_INTERVALS.size() - 1)], fmt_num(reaction)]
        "no_time_to_think":
            if at_limit:
                return ""
            var now: float = OPERATOR_REACTION[mini(count, OPERATOR_REACTION.size() - 1)]
            var next: float = OPERATOR_REACTION[mini(count + 1, OPERATOR_REACTION.size() - 1)]
            return "Время реакции на Operator: %s → %s с" % [fmt_num(now), fmt_num(next)]
        "closing_gap":
            if at_limit:
                return ""
            var now_delay: float = MIMIC_DELAY[mini(count, MIMIC_DELAY.size() - 1)]
            var next_delay: float = MIMIC_DELAY[mini(count + 1, MIMIC_DELAY.size() - 1)]
            return "Задержка Mimic: %s → %s с" % [fmt_num(now_delay), fmt_num(next_delay)]
        "deep_cuts":
            if at_limit:
                return ""
            return "Разрезов в серии: %d → %d" % [SLASH_BASE_COUNT + count, SLASH_BASE_COUNT + count + 1]
    return ""

# ---------------------------------------------------------------- улучшения

static func upgrade_level(id: String) -> int:
    return int(upgrade_levels.get(id, 0))

static func upgrade_max_level(id: String) -> int:
    var entry: Dictionary = UPGRADES[id]
    var prices: Array = entry["prices"]
    return prices.size()

## Улучшение может попасть в выбор: раунд достаточный, класс подходит, максимум не достигнут (п. 15).
static func is_upgrade_offered(id: String, round_no: int) -> bool:
    var entry: Dictionary = UPGRADES[id]
    if round_no < int(entry["min_round"]):
        return false
    if bool(entry.get("teleporter_only", false)) and player_class != "teleporter":
        return false
    return upgrade_level(id) < upgrade_max_level(id)

## Выбор для боковых пьедесталов: больше двух - два разных случайных, два или меньше - все.
static func roll_upgrade_offers(round_no: int) -> Array[String]:
    var pool: Array[String] = []
    for id in UPGRADE_IDS:
        if is_upgrade_offered(id, round_no):
            pool.append(id)
    if pool.size() > 2:
        pool.shuffle()
        pool.resize(2)
    return pool

## Цена следующего уровня при покупке в раунде round_no: ceil(P0 * 1,05^(n-1)).
static func upgrade_price(id: String, round_no: int) -> int:
    var entry: Dictionary = UPGRADES[id]
    var prices: Array = entry["prices"]
    var base := float(prices[mini(upgrade_level(id), prices.size() - 1)])
    return int(ceil(base * pow(PRICE_GROWTH, float(round_no - 1)) - 0.000001))

## Покупка за золотые подарки: мгновенная, без подтверждения (п. 15).
## Возвращает {"ok": bool, "reason": String, "message": String}.
static func buy_upgrade(id: String, round_no: int) -> Dictionary:
    if not is_upgrade_offered(id, round_no):
        return {"ok": false, "reason": "Улучшение недоступно", "message": ""}
    var price := upgrade_price(id, round_no)
    if golden_gifts < price:
        return {
            "ok": false,
            "reason": "Недостаточно золотых подарков: нужно %d, у вас %d" % [price, golden_gifts],
            "message": "",
        }
    golden_gifts -= price
    var level := upgrade_level(id) + 1
    upgrade_levels[id] = level
    if id == "second_chance":
        second_chance_charges = level
    var entry: Dictionary = UPGRADES[id]
    var title: String = entry["name"]
    if upgrade_max_level(id) > 1:
        title += " " + ROMAN[level]
    return {"ok": true, "reason": "", "message": "Куплено: %s" % title}

## Данные пьедестала улучшения: что даст следующий уровень и сколько он стоит.
static func upgrade_info(id: String, round_no: int) -> Dictionary:
    var entry: Dictionary = UPGRADES[id]
    var next_level := upgrade_level(id) + 1
    var levels: Array = entry["levels"]
    var title: String = entry["name"]
    if upgrade_max_level(id) > 1:
        title += " " + ROMAN[next_level]
    var price := upgrade_price(id, round_no)
    return {
        "title": title,
        "desc": entry["desc"],
        "effect": levels[next_level - 1],
        "detail": "%s\nЦена: %d (у вас: %d)" % [levels[next_level - 1], price, golden_gifts],
        "price": price,
        "icon": id,
    }

# ---------------------------------------------------------------- вспомогательное

## Число в русской записи: 1,5 вместо 1.5 и 2 вместо 2.0.
static func fmt_num(value: float) -> String:
    if is_equal_approx(value, roundf(value)):
        return str(int(value))
    return str(value).replace(".", ",")

## Клавиша F для взаимодействия. Основное место - Project Settings > Input Map (действие "interact");
## если его там нет, оно создаётся при запуске, чтобы лобби не зависело от project.godot.
static func ensure_input_actions() -> void:
    if InputMap.has_action("interact"):
        return
    InputMap.add_action("interact")
    var key := InputEventKey.new()
    key.physical_keycode = KEY_F
    InputMap.action_add_event("interact", key)
