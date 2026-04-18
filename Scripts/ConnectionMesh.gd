extends MeshInstance3D

@export var connection_radius: float = 25.0
@export var line_color: Color = Color(0.0, 1.0, 1.0, 0.4) 

var mesh_instance: ImmediateMesh

func _ready():
	mesh_instance = ImmediateMesh.new()
	self.mesh = mesh_instance
	
	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	self.material_override = mat

func _process(_delta):
	var main = get_parent()
	
	# NEW: Check if ML safety is enabled. If not, clear the lines and stop.
	if main.has_method("is_safety_active"):
		if not main.is_safety_active():
			mesh_instance.clear_surfaces()
			return

	if not main.has_method("get_cars"): return

	var cars = main.get_cars()
	mesh_instance.clear_surfaces()
	mesh_instance.surface_begin(Mesh.PRIMITIVE_LINES)

	for i in range(cars.size()):
		for j in range(i + 1, cars.size()):
			var car_a = cars[i]
			var car_b = cars[j]
			
			var dist_sq = car_a.global_position.distance_squared_to(car_b.global_position)
			
			if dist_sq < (connection_radius * connection_radius):
				var dist = sqrt(dist_sq)
				var alpha = clamp(1.0 - (dist / connection_radius), 0.0, 1.0)
				var current_color = line_color
				current_color.a *= alpha
				
				mesh_instance.surface_set_color(current_color)
				mesh_instance.surface_add_vertex(car_a.global_position + Vector3(0, 0.5, 0))
				mesh_instance.surface_set_color(current_color)
				mesh_instance.surface_add_vertex(car_b.global_position + Vector3(0, 0.5, 0))

	mesh_instance.surface_end()
