extends RefCounted
class_name RoadGraph

# =============================================================================
#  RoadGraph — builds a directed graph of every intersection node in the
#  inner grid and runs A* to return a list of world-space waypoints.
#
#  Nodes  : every grid intersection (ix, iz) inside the map.
#  Edges  : axis-aligned road segments connecting adjacent intersections.
#           Each edge is one-directional (we model both dirs as two edges).
#  Output : Array of Vector3 waypoints from start to goal intersection,
#           including sub-waypoints for smooth cornering guidance.
# =============================================================================

var _map_half   : float = 200.0
var _block_size : float = 100.0

# Node key: "ix,iz" (grid integers)
# Value: { "world": Vector2(x,z), "edges": [{ "to": key, "axis":int, "dir":float, "cost":float }] }
var _nodes : Dictionary = {}

func setup(map_half: float, block_size: float) -> void:
	_map_half   = map_half
	_block_size = block_size
	_build_graph()

# ── Build ─────────────────────────────────────────────────────────────────────
func _build_graph() -> void:
	_nodes.clear()
	var steps : int = int(_map_half / _block_size)

	# Create all intersection nodes
	for gx in range(-steps, steps + 1):
		for gz in range(-steps, steps + 1):
			var wx : float = gx * _block_size
			var wz : float = gz * _block_size
			if abs(wx) > _map_half or abs(wz) > _map_half:
				continue
			var key = _key(gx, gz)
			_nodes[key] = { "world": Vector2(wx, wz), "edges": [], "gx": gx, "gz": gz }

	# Add directed edges (both directions on every road segment)
	for key in _nodes.keys():
		var n   = _nodes[key]
		var gx  = n["gx"]
		var gz  = n["gz"]
		# E-W neighbours (axis=1, travel along X)
		for dx in [-1, 1]:
			var nkey = _key(gx + dx, gz)
			if _nodes.has(nkey):
				n["edges"].append({ "to": nkey, "axis": 1,
					"dir": float(dx), "cost": _block_size })
		# N-S neighbours (axis=0, travel along Z)
		for dz in [-1, 1]:
			var nkey = _key(gx, gz + dz)
			if _nodes.has(nkey):
				n["edges"].append({ "to": nkey, "axis": 0,
					"dir": float(dz), "cost": _block_size })

# ── Key helpers ───────────────────────────────────────────────────────────────
func _key(gx: int, gz: int) -> String:
	return "%d,%d" % [gx, gz]

func world_to_key(wx: float, wz: float) -> String:
	var gx = int(round(wx / _block_size))
	var gz = int(round(wz / _block_size))
	return _key(gx, gz)

func key_to_world(key: String) -> Vector2:
	if _nodes.has(key):
		return _nodes[key]["world"]
	return Vector2.ZERO

# ── A* ────────────────────────────────────────────────────────────────────────
# Returns Array of Vector3 (y=0) waypoints, empty if no path found.
func find_path(start_world: Vector2, goal_world: Vector2) -> Array:
	var start_key = world_to_key(start_world.x, start_world.y)
	var goal_key  = world_to_key(goal_world.x,  goal_world.y)

	if not _nodes.has(start_key) or not _nodes.has(goal_key):
		return []
	if start_key == goal_key:
		var p = _nodes[start_key]["world"]
		return [Vector3(p.x, 0, p.y)]

	# open set: priority queue as sorted Array of [f, key]
	var open_set   : Array      = []
	var came_from  : Dictionary = {}
	var g_score    : Dictionary = { start_key: 0.0 }
	var f_score    : Dictionary = {}
	var goal_world3 = _nodes[goal_key]["world"]

	f_score[start_key] = _heuristic(start_key, goal_world3)
	open_set.append([f_score[start_key], start_key])

	while not open_set.is_empty():
		# Pop lowest f
		open_set.sort_custom(func(a, b): return a[0] < b[0])
		var current_key : String = open_set.pop_front()[1]

		if current_key == goal_key:
			return _reconstruct(came_from, current_key)

		var current_node = _nodes[current_key]
		for edge in current_node["edges"]:
			var nb_key  : String = edge["to"]
			var tentative_g : float = g_score.get(current_key, INF) + edge["cost"]
			if tentative_g < g_score.get(nb_key, INF):
				came_from[nb_key] = current_key
				g_score[nb_key]   = tentative_g
				var nb_world = _nodes[nb_key]["world"]
				f_score[nb_key] = tentative_g + _heuristic(nb_key, goal_world3)
				# Add to open set if not already there
				var already = false
				for item in open_set:
					if item[1] == nb_key:
						item[0] = f_score[nb_key]
						already = true
						break
				if not already:
					open_set.append([f_score[nb_key], nb_key])

	return []   # No path

func _heuristic(key: String, goal_world: Vector2) -> float:
	if not _nodes.has(key): return INF
	var w = _nodes[key]["world"]
	return abs(w.x - goal_world.x) + abs(w.y - goal_world.y)

func _reconstruct(came_from: Dictionary, current: String) -> Array:
	var path : Array = [current]
	while came_from.has(current):
		current = came_from[current]
		path.push_front(current)

	var result : Array = []
	for key in path:
		var w = _nodes[key]["world"]
		result.append(Vector3(w.x, 0.0, w.y))
	return result
