@tool
extends EditorPlugin

const OutlineEffectScript: GDScript = preload("res://addons/highlight_outline/outline_compositor_effect.gd")

var _compositor: Compositor
var _effect: OutlineCompositorEffect
var _stencil_material: StandardMaterial3D
var _selected_node: MeshInstance3D


func _enter_tree() -> void:
	# 写 stencil 的 overlay 材质：透明不改变外观；
	# depth pass 与 depth fail 都写 stencil（= 无视深度，覆盖完整投影，避免内部"洞"）
	_stencil_material = StandardMaterial3D.new()
	_stencil_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_stencil_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_stencil_material.albedo_color = Color(1, 1, 1, 0)
	_stencil_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_stencil_material.stencil_mode = BaseMaterial3D.STENCIL_MODE_CUSTOM
	_stencil_material.stencil_flags = BaseMaterial3D.STENCIL_FLAG_WRITE | BaseMaterial3D.STENCIL_FLAG_WRITE_DEPTH_FAIL
	_stencil_material.stencil_reference = 1
	_stencil_material.stencil_compare = BaseMaterial3D.STENCIL_COMPARE_ALWAYS
	
	# CompositorEffect + Compositor
	_effect = OutlineEffectScript.new()
	_effect.thickness = 2 # ← 轮廓粗细(像素)
	_effect.outline_color = Color(1.0, 0.5, 0.0, 1.0) # 颜色
	_compositor = Compositor.new()
	_compositor.compositor_effects = [_effect]
	
	get_editor_interface().get_selection().selection_changed.connect(_on_selection_changed)
	
	call_deferred("_attach_compositor")



func _exit_tree() -> void:
	_clear_outline()
	_detach_compositor()
	_stencil_material = null
	_effect = null
	_compositor = null


func _attach_compositor() -> void:
	var viewport := get_editor_interface().get_editor_viewport_3d(0)
	if viewport == null:
		return
	var camera := viewport.get_camera_3d()
	if camera == null:
		return
	if camera.compositor != _compositor:
		camera.compositor = _compositor


func _detach_compositor() -> void:
	var viewport := get_editor_interface().get_editor_viewport_3d(0)
	if viewport == null:
		return
	var camera := viewport.get_camera_3d()
	if camera != null and camera.compositor == _compositor:
		camera.compositor = null


func _on_selection_changed() -> void:
	_clear_outline()
	# 编辑器可能在切视口时重置 camera，惰性重挂
	_attach_compositor()
	
	var selected := get_editor_interface().get_selection().get_selected_nodes()
	for node: Node in selected:
		if node is MeshInstance3D:
			_selected_node = node
			break
	
	if _selected_node != null:
		_selected_node.material_overlay = _stencil_material


func _clear_outline() -> void:
	if _selected_node != null and is_instance_valid(_selected_node):
		_selected_node.material_overlay = null
	_selected_node = null


func _enable_plugin() -> void:
	pass


func _disable_plugin() -> void:
	pass
