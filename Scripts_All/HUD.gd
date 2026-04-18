extends CanvasLayer
class_name HUD

# Stub HUD — all UI is handled by GameUI.
# Keep this file so Main.gd preload doesn't fail.

func register_car(_idx: int) -> void:
	pass

func update_car(_idx: int, _lane: int, _decision: String,
				_confidence: float, _speed: float) -> void:
	pass

func set_ml_connected(_connected: bool) -> void:
	pass
