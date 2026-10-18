extends Node

# Путь к файлу сохранения на устройстве
const SAVE_PATH = "user://settings.cfg"

# Свойства (переменные), к которым ваш UI обращается напрямую
var music_volume: float = 0.8
var sfx_volume: float = 1.0
var is_fullscreen: bool = true

func _ready() -> void:
	load_settings()

# Загрузка настроек при запуске игры
func load_settings() -> void:
	var config = ConfigFile.new()
	var error = config.load(SAVE_PATH)
	
	if error == OK:
		# Читаем данные из файла. Если их там нет, остаются значения по умолчанию
		music_volume = config.get_value("audio", "music_volume", music_volume)
		sfx_volume = config.get_value("audio", "sfx_volume", sfx_volume)
		is_fullscreen = config.get_value("video", "is_fullscreen", is_fullscreen)
	
	# Применяем всё при старте игры
	apply_audio_settings()
	apply_video_settings()

# Сохранение текущих значений на диск (вызывается при нажатии кнопки Back)
func save_settings() -> void:
	var config = ConfigFile.new()
	
	config.set_value("audio", "music_volume", music_volume)
	config.set_value("audio", "sfx_volume", sfx_volume)
	config.set_value("video", "is_fullscreen", is_fullscreen)
	
	var error = config.save(SAVE_PATH)
	if error != OK:
		print("Ошибка сохранения конфигурации: ", error)

# Применение настроек звука
func apply_audio_settings() -> void:
	_update_bus_volume("Music", music_volume)
	_update_bus_volume("SFX", sfx_volume)

# Применение настроек видео
func apply_video_settings() -> void:
	if is_fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)

# Вспомогательная внутренняя функция для изменения громкости в AudioServer
func _update_bus_volume(bus_name: String, volume_linear: float) -> void:
	var bus_index = AudioServer.get_bus_index(bus_name)
	if bus_index != -1:
		# Переводим ползунок (0.0 - 1.0) в децибелы движка
		AudioServer.set_bus_volume_db(bus_index, linear_to_db(volume_linear))
		# Полностью выключаем звук (Mute), если ползунок в нуле
		AudioServer.set_bus_mute(bus_index, volume_linear <= 0.0)
