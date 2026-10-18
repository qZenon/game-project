extends Control

# Путь к вашей сцене игры
const GAME_SCENE_PATH = "res://game/lobby.tscn"

# Путь к вашей сцене настроек (скорректируйте, если файл лежит в другом месте)
const OPTIONS_MENU_PATH = "res://options_menu.tscn"

# Ссылки на узлы интерфейса
@onready var game_title: Label = $CenterContainer/VBoxContainer/GameTitle
@onready var main_vbox: VBoxContainer = $CenterContainer/VBoxContainer

# Ссылки на кнопки для программного подключения сигналов
@onready var play_button: Button = $CenterContainer/VBoxContainer/PlayButton
@onready var stats_button: Button = $CenterContainer/VBoxContainer/StatsButton
@onready var settings_button: Button = $CenterContainer/VBoxContainer/SettingsButton
@onready var exit_button: Button = $CenterContainer/VBoxContainer/ExitButton

func _ready() -> void:
	# Фокус на первой кнопке для удобства управления (например, с геймпада или клавиатуры)
	play_button.grab_focus()
	
	# Программное подключение сигналов ко всем кнопкам
	play_button.pressed.connect(_on_play_button_pressed)
	stats_button.pressed.connect(_on_stats_button_pressed)
	settings_button.pressed.connect(_on_settings_button_pressed)
	exit_button.pressed.connect(_on_exit_button_pressed)
	
	# Запускаем пульсацию цвета названия
	start_title_pulsation()

# Функция, создающая бесконечную пульсацию
func start_title_pulsation() -> void:
	if not game_title:
		return
		
	# Создаем новый Tween-аниматор
	var tween = create_tween()
	
	# Зацикливаем анимацию навсегда
	tween.set_loops()
	
	# Шаг 1: Плавно делаем текст чуть темнее/прозрачнее за 2 секунды
	tween.tween_property(game_title, "modulate", Color(1, 1, 1, 0.5), 2)\
		.set_trans(Tween.TRANS_SINE)\
		.set_ease(Tween.EASE_IN_OUT)
		
	# Шаг 2: Плавно возвращаем полную яркость (100%) за те же 2 секунды
	tween.tween_property(game_title, "modulate", Color(1, 1, 1, 1.0), 2)\
		.set_trans(Tween.TRANS_SINE)\
		.set_ease(Tween.EASE_IN_OUT)

# --- Обработка сигналов кнопок ---

func _on_play_button_pressed() -> void:
	var error = get_tree().change_scene_to_file(GAME_SCENE_PATH)
	if error != OK:
		print("Ошибка загрузки сцены игры: ", error)

func _on_stats_button_pressed() -> void:
	print("Открываем статистику")
	# Сюда в будущем можно добавить аналогичную логику открытия сцены статистики

func _on_settings_button_pressed() -> void:
	# Проверяем, существует ли файл сцены настроек по указанному пути
	if ResourceLoader.exists(OPTIONS_MENU_PATH):
		# Скрываем контейнер главного меню
		main_vbox.hide()
		
		# Загружаем сцену настроек, создаем её экземпляр и добавляем как дочерний узел
		var options_scene = load(OPTIONS_MENU_PATH)
		var options_instance = options_scene.instantiate()
		add_child(options_instance)
	else:
		print("Ошибка: Не удалось найти сцену настроек по пути: ", OPTIONS_MENU_PATH)

func _on_exit_button_pressed() -> void:
	get_tree().quit()
