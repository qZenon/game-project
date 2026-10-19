extends CanvasLayer

@onready var screamer_texture: TextureRect = $ScreamerTexture

@export var display_time: float = 1   # Время показа скримера (в секундах)
@export var cooldown_time: float = 3.0  # Общая перезарядка действия

var is_cooldown: bool = false

func _unhandled_input(event: InputEvent) -> void:
	# Проверяем нажатие клавиши Z и отсутствие перезарядки
	if event.is_action_pressed("z") and not is_cooldown:
		show_screamer()

func show_screamer() -> void:
	is_cooldown = true
	screamer_texture.visible = true
	
	# Добавляем небольшой визуальный эффект резкого увеличения
	screamer_texture.scale = Vector2(1.2, 1.2)
	screamer_texture.pivot_offset = screamer_texture.size / 2
	
	var tween = create_tween()
	tween.tween_property(screamer_texture, "scale", Vector2(1.0, 1.0), 0.1).set_trans(Tween.TRANS_BOUNCE)
	
	# Ждем время показа скримера
	await get_tree().create_timer(display_time).timeout
	screamer_texture.visible = false
	
	# Ждем оставшееся время перезарядки
	await get_tree().create_timer(cooldown_time - display_time).timeout
	is_cooldown = false
