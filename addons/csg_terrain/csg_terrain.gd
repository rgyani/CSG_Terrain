# Main manager of CSG Terrain. This is what will call the other classes.
@tool
@icon("csg_terrain.svg")
class_name CSGTerrain
extends CSGMesh3D

signal terrain_need_update

# Constants for terrain limits
const MIN_TERRAIN_SIZE = 0.001
const MAX_TERRAIN_SIZE = 1024.0
const MIN_SUBDIVISIONS = 1
const MAX_SUBDIVISIONS = 128

## Width of the terrain along the X axis.
@export var size_x: float = 500:
	set(value):
		if value < MIN_TERRAIN_SIZE:
			value = MIN_TERRAIN_SIZE
		if value > MAX_TERRAIN_SIZE:
			value = MAX_TERRAIN_SIZE
		
		var old_value = size_x
		size_x = value
		_size_x_changed(old_value)

## Height of the terrain along the Z axis.
@export var size_z: float = 500:
	set(value):
		if value < MIN_TERRAIN_SIZE:
			value = MIN_TERRAIN_SIZE
		if value > MAX_TERRAIN_SIZE:
			value = MAX_TERRAIN_SIZE
		
		var old_value = size_z
		size_z = value
		_size_z_changed(old_value)

## Number of subdivisions along the width (X axis).
@export_range(1, 128) var div_x: int = 50:
	set(value):
		var old_value = div_x
		div_x = value
		_div_x_changed(old_value)

## Number of subdivisions along the height (Z axis).
@export_range(1, 128) var div_z: int = 50:
	set(value):
		var old_value = div_z
		div_z = value
		_div_z_changed(old_value)

## Resolution of the mask applied to paths. Change if the path texture doesn't merge accordingly.
@export_range(8, 1024) var path_mask_resolution: int = 512:
	set(value):
		var old_value = path_mask_resolution
		path_mask_resolution = value
		_resolution_changed(old_value)

## Create an optimized MeshInstance3D without the bottom cube.[br][br]
## Good topology is not guaranteed. You may need to edit it manually in 3D software.
@export_tool_button("Bake Terrain Mesh", "MeshInstance3D") var bake_button = _bake_terrain

## Create an GLTF file without the bottom cube.
@export_tool_button("Export Terrain File", "File") var export_button = _export_terrain

# CSG Terrain classes.
var terrain_mesh = CSGTerrainMesh.new()
var textures = CSGTerrainTextures.new()
var bake_export = CSGTerrainBake.new()
var path_list: Array[CSGTerrainPath] = []

var is_updating: bool = false


func _ready() -> void:
	# Skip if is not in editor.
	if not Engine.is_editor_hint():
		return
	
	# Instantiate material if it's empty.
	if not is_instance_valid(material):
		material = load("res://addons/csg_terrain/csg_terrain_material.tres").duplicate(true)
		material.shader = load("res://addons/csg_terrain/csg_terrain_shader.gdshader")
	
	# If there's no mesh, make a new one and also the first curve.
	if not is_instance_valid(mesh):
		mesh = ArrayMesh.new()
		var path: CSGTerrainPath = CSGTerrainPath.new()
		path.name = "Path3D"
		var curve: Curve3D = Curve3D.new()
		curve.add_point(Vector3(0, 0, 0))
		curve.add_point(Vector3(0, 35, -40))
		curve.set_point_in(1 , Vector3(0, 0, 15))
		curve.set_point_out(1 , Vector3(0, 0, -15))
		path.curve = curve
		add_child(path, true)
		path.set_owner(get_tree().edited_scene_root)
	
	# Populate path list.
	path_list.clear()
	for child in get_children():
		_child_entered(child)
	
	# Signals.
	child_entered_tree.connect(_child_entered)
	child_exiting_tree.connect(_child_exit)
	child_order_changed.connect(_child_order_changed)
	terrain_need_update.connect(_update_terrain)
	
	terrain_need_update.emit()


## When a Path3D enters, add the script CSGTerrainPath.
func _child_entered(child) -> void:
	if child is Path3D:
		child = child as Path3D
		
		if not is_instance_of(child, CSGTerrainPath):
			child.set_script(CSGTerrainPath)
			child.curve.bake_interval = min(size_x, size_z) / min(div_x, div_z)
		
		if not child.curve_changed.is_connected(_update_terrain):
			child.curve_changed.connect(_update_terrain)
		
		path_list.append(child)


func _child_exit(child) -> void:
	if child is Path3D:
		var index: int = path_list.find(child)
		path_list.remove_at(index)
		
		if child.curve_changed.is_connected(_update_terrain):
			child.curve_changed.disconnect(_update_terrain)
		
		# Check if the current editor tab is the CSG Terrain scene. Fix bug when changing tabs.
		if Engine.get_singleton(&"EditorInterface").get_edited_scene_root() == get_tree().edited_scene_root:
			terrain_need_update.emit()


func _child_order_changed() -> void:
	path_list.clear()
	for child in get_children():
		if child is CSGTerrainPath:
			path_list.append(child)


func _size_x_changed(old_x: float) -> void:
	for path in path_list:
		var new_width = path.width * old_x / size_x
		path.width = int(new_width)
	
	terrain_need_update.emit()


func _size_z_changed(old_z: float) -> void:
	for path in path_list:
		var new_texture_width = path.paint_width * old_z / size_z
		path.paint_width = int(new_texture_width)
	
	terrain_need_update.emit()


func _div_x_changed(old_div_x: int) -> void:
	for path in path_list:
		var new_x: float = path.size_x * float(div_x) / old_div_x
		path.size_x = int(new_x)
	
	terrain_need_update.emit()


func _div_z_changed(old_div_z: int) -> void:
	for path in path_list:
		var new_texture_z = path.paint_x * float(div_z) / old_div_z
		path.paint_x = int(new_texture_z)
	
	terrain_need_update.emit()


func _resolution_changed(old_resolution) -> void:
	for path in path_list:
		var new_texture_width = path.paint_width * path_mask_resolution / old_resolution
		path.paint_width = int(new_texture_width)
	
	terrain_need_update.emit()


## Never call _update_terrain directly. Emit the signal terrain_need_update instead.
func _update_terrain():
	# Block if alredy received an update request on the current frame.
	if is_updating == true:
		return
	is_updating = true
	# Wait until next frame to recieve more update requests.
	await get_tree().process_frame
	
	# CSG Terrain update methods.
	terrain_mesh.update_mesh(mesh, path_list, div_x, div_z, size_x, size_z)
	textures.apply_textures(material, path_list, path_mask_resolution, size_x, size_z)
	
	is_updating = false


## Create an optimized MeshInstance3D without the bottom cube[br][br].
## Good topology is not guaranteed. You may need to edit it manually in 3D software.
func _bake_terrain() -> void:
	await get_tree().process_frame
	var new_mesh: MeshInstance3D = bake_export.create_mesh(self, size_x, size_z, div_x, div_z)
	add_sibling(new_mesh, true)
	new_mesh.owner = owner


## Export terrain dialog box
func _export_terrain():
	await get_tree().process_frame
	bake_export.export_terrain(self, size_x, size_z, div_x, div_z)
