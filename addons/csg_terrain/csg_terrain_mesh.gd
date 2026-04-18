## Class responsible to deal with the mesh itself.
## This is what makes the terrain bend with the curves.
class_name CSGTerrainMesh

# Vertex grid in [x][z] plane.
var vertex_grid: Array = []

var uvs: PackedVector2Array = []
var indices: PackedInt32Array = []


## Main mesh manager. This is what external classes should call.
func update_mesh(mesh: ArrayMesh, path_list: Array[CSGTerrainPath], div_x: int, div_z: int, size_x: float, size_z: float) -> void:
	# Recrieate all mesh arrays. Seems expensive but is the last of our problems.
	_create_mesh_arrays(div_x, div_z, size_x, size_z)
	
	# Make the mesh follow each path, in tree order. 90% of the time is spent here.
	for path in path_list:
		if path.curve.bake_interval != (min(size_x, size_z) / min(div_x, div_z)):
			path.curve.bake_interval = (min(size_x, size_z) / min(div_x, div_z))
		
		if path.width > 0:
			_follow_curve(path, div_x, div_z, size_x, size_z)
	
	# Organize all the mesh at once. Again, seems expensive but is not an issue.
	_commit_mesh(size_x, size_z, div_x, div_z, mesh)


## Create the terrain mesh according the vertex grid.
func _create_mesh_arrays(div_x: int, div_z: int, size_x: float, size_z: float) -> void:
	# Vertex Grid follow the pattern [x][z]. The y axis is what will follow the curves.
	vertex_grid.clear()
	vertex_grid.resize(div_x + 1)
	
	# Apply scale.
	var step_x: float = size_x / div_x
	var step_z: float = size_z / div_z
	var center: Vector3 = Vector3(0.5 * size_x, 0, 0.5 * size_z)
	for x in range(div_x + 1):
		var vertices_z: PackedVector3Array = []
		vertices_z.resize(div_z + 1)
		for z in range(div_z + 1):
			vertices_z[z] = Vector3(x * step_x, 0, z * step_z) - center
		vertex_grid[x] = vertices_z
	
	# Make uvs.
	uvs.clear()
	uvs.resize((div_x + 1) * (div_z + 1))
	var uv_step_x: float = 1.0 / div_x
	var uv_step_z: float = 1.0 / div_z
	var index: int = 0
	for x in range(div_x + 1):
		for z in range(div_z + 1):
			uvs[index] = Vector2(x * uv_step_x, z * uv_step_z)
			index += 1
	
	# Make quads with two triangles.
	indices.clear()
	indices.resize(div_x * div_z * 6)
	var row: int = 0
	var next_row: int = 0
	index = 0
	for x in range(div_x):
		row = next_row
		next_row += div_z + 1
		
		# Making the two triangles. Ways to make it more readable are welcomed.
		for z in range(div_z):
			# First triangle vertices.
			indices[index] = z + row
			indices[index + 1] = z + next_row + 1
			indices[index + 2] = z + row + 1
			
			# Second triangle vertices.
			indices[index + 3] = z + row
			indices[index + 4] = z + next_row
			indices[index + 5] = z + next_row + 1
			
			index += 6


## Finalize the mesh and aplly to the CSGMesh3D node.
func _commit_mesh(size_x: float, size_z: float, div_x: int, div_z: int, mesh: ArrayMesh) -> void:
	# Mesh in ArrayMesh format.
	var surface_array: Array = []
	surface_array.resize(Mesh.ARRAY_MAX)
	surface_array[Mesh.ARRAY_TEX_UV] = uvs
	surface_array[Mesh.ARRAY_TEX_UV2] = uvs
	surface_array[Mesh.ARRAY_INDEX] = indices
	
	# Organize vertex matrix in format PackedVector3Array.
	var vert_list: PackedVector3Array = []
	for array in vertex_grid:
		vert_list.append_array(array)
	
	surface_array[Mesh.ARRAY_VERTEX] = vert_list
	
	# Make normals according Clever Normalization of a Mesh: https://iquilezles.org/articles/normals
	# Making manually because using surfacetool was 3-5 times slower.
	var normals: PackedVector3Array = []
	normals.resize((div_x + 1) * (div_z + 1))
	
	for index in range(0, indices.size(), 3):
		# Vertices of the triangle.
		var a: Vector3 = vert_list[indices[index]]
		var b: Vector3 = vert_list[indices[index + 1]]
		var c: Vector3 = vert_list[indices[index + 2]]
		
		# Creating normal from edges.
		var edge1: Vector3 = b - a
		var edge2: Vector3 = c - a
		var normal: Vector3 = edge1.cross(edge2)
		
		# Adding normal to each vertex.
		normals[indices[index]] += normal
		normals[indices[index + 1]] += normal
		normals[indices[index + 2]] += normal
	
	# Normalize and apply.
	for i in range(normals.size()):
		normals[i] = normals[i].normalized()
	
	surface_array[Mesh.ARRAY_NORMAL] = normals
	
	# Closing the shape because Godot 4.4 need this.
	_close_shape(size_x, size_z, div_x, div_z, surface_array)
	
	# Commit to the main mash.
	mesh.clear_surfaces()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)


## Bend the terrain size_z to follow the curve.
func _follow_curve(path: CSGTerrainPath, div_x: int, div_z: int, size_x: float, size_z: float) -> void:
	var path_width: int = path.paint_width
	var smoothness: float = path.smoothness
	
	var pos: Vector3 = path.position
	var center: Vector3 = Vector3(0.5 * size_x, 0, 0.5 * size_z)
	var curve: Curve3D = path.curve
	var baked3D: PackedVector3Array = curve.get_baked_points()
	
	if baked3D.size() < 2: return
	
	# Project the curve baked points in the [x][z] plane.
	var baked2D: PackedVector2Array = []
	baked2D.resize(baked3D.size())
	for i in range(baked3D.size()):
		var point: Vector3 = baked3D[i]
		baked2D[i] = Vector2(point.x, point.z)
	
	# Dictionary with all vertices at "size_x" distance from the curve.
	var curve_vertices = {}
	for point in baked3D:
		var local_point: Vector3 = point + pos + center
		
		# Point in the vertex_grid.
		var grid_point: Vector3 = local_point * Vector3(div_x / size_x, 1, div_z / size_z)
		var grid_index: Vector2i = Vector2i(int(grid_point.x), int(grid_point.z))
		
		# Exprore the region around the point. Cut out points outside the grid.
		var range_min_x: int = -path_width + 1 + grid_index.x
		range_min_x = clampi(range_min_x, 0, div_x + 1)
		var range_max_x: int = path_width + 2 + grid_index.x
		range_max_x = clampi(range_max_x, 0, div_x + 1)
		var range_min_y: int = -path_width + 1 + grid_index.y
		range_min_y = clampi(range_min_y, 0, div_z + 1)
		var range_max_y: int = path_width + 2 + grid_index.y
		range_max_y = clampi(range_max_y, 0, div_z + 1)
		
		for i in range(range_min_x, range_max_x):
			for j in range(range_min_y, range_max_y):
				curve_vertices[Vector2i(i, j)] = true
	
	# Interpolate the size_z of the vertices.
	for grid_idx in curve_vertices:
		var vertex: Vector3 = vertex_grid[grid_idx.x][grid_idx.y]
		var old_vertex: Vector3 = vertex
		
		# Vertex in path space.
		var path_vertex: Vector3 = vertex - pos
		
		# Get the closest point on the 3D curve without considering the size_z.
		var closest: Vector3 = _get_closest_point_in_xz_plane(baked2D, baked3D, path_vertex)
		
		# Back to local space.
		closest += pos
		
		# Distance relative to path witdh.
		vertex.y = closest.y
		var dist = vertex.distance_to(closest)
		if path_width == 0: path_width = 1
		var dist_relative: float = (dist * min(div_x, div_z)) / (path_width * min(size_x, size_z))
		
		# Quadratic smooth.
		var lerp_weight: float = dist_relative * dist_relative * smoothness
		lerp_weight = clampf(lerp_weight, 0, 1)
		var new_height: float = lerpf(closest.y, old_vertex.y, lerp_weight)
		vertex.y = new_height
		
		vertex_grid[grid_idx.x][grid_idx.y] = vertex
	
	# Update indices on affected vertices.
	for grid_idx in curve_vertices:
		_update_quad_indices(grid_idx, div_x, div_z)


## Get the closest point on the 2D curve and project on the 3D curve.
## Expensive, takes 50% of all time!
func _get_closest_point_in_xz_plane(
		baked_2D: PackedVector2Array,
		baked_3D: PackedVector3Array,
		vertex3D: Vector3) -> Vector3:
	
	var vertex2D = Vector2(vertex3D.x, vertex3D.z)
	
	# Get the closest baked point in xz plane.
	var idx: int = 0
	var dist: float = INF
	var old_dist: float = INF
	for i in range(1, baked_2D.size() - 1):
		dist = vertex2D.distance_squared_to(baked_2D[i])
		if dist < old_dist:
			old_dist = dist
			idx = i
	
	# Check next segment.
	var next_seg: Vector2 = Geometry2D.get_closest_point_to_segment(
		vertex2D, baked_2D[idx], baked_2D[idx + 1]) 
	var next_dist: float = vertex2D.distance_squared_to(next_seg)
	
	# Check previews segment.
	var prev_seg: Vector2 = Geometry2D.get_closest_point_to_segment(
		vertex2D, baked_2D[idx], baked_2D[idx - 1])
	var prev_dist: float = vertex2D.distance_squared_to(prev_seg)
	
	 # Project the closest 2D segment on the 3D curve.
	var closest_point: Vector3 = Vector3.ZERO
	if next_dist < prev_dist:
		closest_point = Geometry3D.get_closest_points_between_segments(
		baked_3D[idx], baked_3D[idx + 1],
		# Vertical axis that cross the curve.
		Vector3(next_seg.x, -65536, next_seg.y), Vector3(next_seg.x, 65536, next_seg.y))[0]
	else:
		closest_point = Geometry3D.get_closest_points_between_segments(
		baked_3D[idx], baked_3D[idx - 1],
		# Vertical axis that cross the curve.
		Vector3(prev_seg.x, -65536, prev_seg.y), Vector3(prev_seg.x, 65536, prev_seg.y))[0]
	
	return closest_point


## There are two ways to triangularize a quad. To better follow the path, convex in y will be used.
func _update_quad_indices(idx: Vector2i, div_x: int, div_z: int) -> void:
	var x: int = idx.x
	if (x + 1) > div_x: return
	var z: int = idx.y
	if (z + 1) > div_z: return
	# Make faces with two triangles.
	var row: int = x * (div_z + 1)
	var next_row: int = row + div_z + 1
	var index: int = 6 * (x * div_z + z)
	 
	# There are two ways to triangularize a quad. Each one with one diagonal.
	# Getting the middle point of each diagonal.
	var diagonal_1: Vector3 = 0.5 * (vertex_grid[x][z] + vertex_grid[x + 1][z + 1])
	var diagonal_2: Vector3 = 0.5 * (vertex_grid[x + 1][z] + vertex_grid[x][z + 1])
	
	# The diagonal with the upper middle point will be convex in y.
	if diagonal_1.y >= diagonal_2.y:
		# First triangle vertices.
		indices[index] = z + row
		indices[index + 1] = z + next_row + 1
		indices[index + 2] = z + row + 1
		
		# Second triangle vertices.
		indices[index + 3] = z + row
		indices[index + 4] = z + next_row
		indices[index + 5] = z + next_row + 1
	else:
		# First triangle vertices.
		indices[index] = z + next_row
		indices[index + 1] = z + next_row + 1
		indices[index + 2] = z + row + 1
		
		# Second triangle vertices.
		indices[index + 3] = z + next_row
		indices[index + 4] = z + row + 1
		indices[index + 5] = z + row


# CSG meshes must be closed in Godot 4.4, this is the price for fast CSG.
# Making a cube bellow the tarrain.
func _close_shape(size_x: float, size_z: float, div_x: int, div_z: int, surface_array: Array):
	# Add vertices of the bottom quad.
	var bottom_size = (size_x + size_z) / 2.0
	var center: Vector3 = Vector3(0.5 * size_x, 0, 0.5 * size_z)
	
	var new_vertices:PackedVector3Array  = []
	new_vertices.resize(4)
	new_vertices[0] = Vector3(0, -bottom_size, 0) - center
	new_vertices[1] = Vector3(0, -bottom_size, size_z) - center
	new_vertices[2] = Vector3(size_x, -bottom_size, 0 ) - center
	new_vertices[3] = Vector3(size_x, -bottom_size, size_z) - center
	
	var vert_list: PackedVector3Array = surface_array[Mesh.ARRAY_VERTEX]
	vert_list.append_array(new_vertices)
	
	# Add indices of the bottom quad.
	var index: int = (div_x + 1) * (div_z + 1)
	var new_indices: PackedInt32Array = []
	new_indices.resize(18 + div_x * 12 + div_z * 12)
	
	new_indices[0]= index
	new_indices[1] = index + 1
	new_indices[2] = index + 3
	new_indices[3] = index
	new_indices[4] = index + 3
	new_indices[5] = index + 2
	
	# Fill last triangle for each side.
	# Left
	new_indices[6] = index + 1
	new_indices[7] = index
	new_indices[8] = div_z
	# Right
	new_indices[9] = index + 2
	new_indices[10] = index + 3
	new_indices[11] = div_z * (div_x + 1)
	# Up
	new_indices[12] = index
	new_indices[13] = index + 2
	new_indices[14] = 0
	# Down
	new_indices[15] = index + 3
	new_indices[16] = index + 1
	new_indices[17] = (div_x) * (div_z + 1) + div_z
	
	# Connect indices from terrain plane with bottom quad.
	var indices_idx: int = 18
	for i in range(div_z):
		var left: int = i
		new_indices[indices_idx] = left
		new_indices[indices_idx + 1] = left + 1
		new_indices[indices_idx + 2] = index
		
		var right: int = i + div_x * (div_z + 1)
		new_indices[indices_idx + 3] = right + 1
		new_indices[indices_idx + 4] = right
		new_indices[indices_idx + 5] = index + 3
		
		indices_idx += 6
	
	for i in range(div_x):
		var up: int = div_z * i + i
		new_indices[indices_idx + 6] = up + div_z + 1
		new_indices[indices_idx + 7] = up
		new_indices[indices_idx + 8] = index + 2
		
		var down: int = div_z + (div_z + 1) * i
		new_indices[indices_idx + 9] = down
		new_indices[indices_idx + 10] = down + div_z + 1
		new_indices[indices_idx + 11] = index + 1
		
		indices_idx += 12
	
	indices.append_array(new_indices)
	
	# Add uvs.
	var new_uvs: PackedVector2Array = []
	new_uvs.resize(4)
	new_uvs[0] = Vector2(0,0)
	new_uvs[1] = Vector2(0,1)
	new_uvs[2] = Vector2(1,0)
	new_uvs[3] = Vector2(1,1)
	
	uvs.append_array(new_uvs)
	
	# Add Normals.
	var new_normals: PackedVector3Array = []
	new_normals.resize(4)
	new_normals[0] = Vector3.UP
	new_normals[1] = Vector3.UP
	new_normals[2] = Vector3.UP
	new_normals[3] = Vector3.UP
	
	var normals: PackedVector3Array = surface_array[Mesh.ARRAY_NORMAL]
	normals.append_array(new_normals)
