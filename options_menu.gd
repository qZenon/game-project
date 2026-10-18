extends Control

@onready var music_slider: HSlider = $VBoxContainer/HBoxContainer_Music/MusicSlider
@onready var sfx_slider: HSlider = $VBoxContainer/HBoxContainer_SFX/SFXSlider
@onready var fullscreen_check: CheckButton = $VBoxContainer/HBoxContainer_Display/FullscreenCheck

func _ready() -> void:
	# Синхронизируем UI с текущими сохраненными значениями из менеджера
	music_slider.value = SettingsManager.music_volume
	sfx_slider.value = SettingsManager.sfx_volume
	fullscreen_check.button_pressed = SettingsManager.is_fullscreen
	
	# Подключаем сигналы программно или сделайте это через вкладку "Узлы" (Node) справа
	music_slider.value_changed.connect(_on_music_slider_value_changed)
	sfx_slider.value_changed.connect(_on_sfx_slider_value_changed)
	fullscreen_check.toggled.connect(_on_fullscreen_toggled)
	$VBoxContainer/BackButton.pressed.connect(_on_back_button_pressed)

func _on_music_slider_value_changed(value: float) -> void:
	SettingsManager.music_volume = value
	SettingsManager.apply_audio_settings()

func _on_sfx_slider_value_changed(value: float) -> void:
	SettingsManager.sfx_volume = value
	SettingsManager.apply_audio_settings()

func _on_fullscreen_toggled(toggled_on: bool) -> void:
	SettingsManager.is_fullscreen = toggled_on
	SettingsManager.apply_video_settings()

func _on_back_button_pressed() -> void:
	# При выходе из меню сохраняем конфигурацию на диск
	SettingsManager.save_settings()
	
	# Находим узел главного меню (это родительский узел для этой панели)
	# и снова показываем его VBoxContainer
	var main_menu = get_parent()
	if main_menu and main_menu.has_node("CenterContainer/VBoxContainer"):
		main_menu.get_node("CenterContainer/VBoxContainer").show()
	
	# Удаляем панель настроек с экрана
	queue_free()
