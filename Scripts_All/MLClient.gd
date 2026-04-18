extends Node
class_name MLClient

signal prediction_received(prediction_data: Dictionary, car_index: int)
signal connection_established()
signal connection_lost()

var connected: bool = false

func _ready() -> void:
	pass  # no server = no connection, cars use built-in logic only

func ping() -> void:
	pass

func predict_lane_change(_features: Dictionary, _car_index: int) -> void:
	pass  # stub: no prediction sent, car will handle via fallback logic

func batch_predict(_model: String, _states: Array) -> void:
	pass
