extends CanvasLayer

# Ссылка на CenterContainer, чтобы скрывать/показывать весь интерфейс сразу
@onready var container = $CenterContainer

func _ready():
	# При старте игры обязательно скрываем меню паузы
	container.hide()

func _input(event):
	# Проверяем нажатие клавиши Esc (ui_cancel в Godot настроена на Esc по умолчанию)
	if event.is_action_pressed("ui_cancel"):
		toggle_pause()

# Функция, которая переключает состояние паузы и видимость меню
func toggle_pause():
	# Инвертируем текущее состояние паузы всей игры (true становится false, и наоборот)
	var new_pause_state = !get_tree().paused
	get_tree().paused = new_pause_state
	
	# Управляем видимостью интерфейса на основе состояния паузы
	container.visible = new_pause_state

# Функция для кнопки "Продолжить" (ResumeButton

# Функция для кнопки "Выйти" (ExitButton)

func _on_button_pressed() -> void:
	toggle_pause()


func _on_button_2_pressed() -> void:
	get_tree().paused = false
	
	# Переходим на сцену главного меню (замените путь "res://menu.tscn" на ваш настоящий)
	get_tree().change_scene_to_file("res://menu/menu.tscn")
