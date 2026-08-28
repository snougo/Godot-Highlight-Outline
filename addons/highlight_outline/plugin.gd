@tool
extends EditorPlugin

const OutlineEffectScript: GDScript = preload("res://addons/highlight_outline/outline_compositor_effect.gd")

# --- 设置路径常量（分层组织：插件名/分组/设置项，参考 shader_library） ---
const SETTING_COLOR := "highlight_outline/appearance/outline_color"
const SETTING_THICKNESS := "highlight_outline/appearance/thickness"
const DEFAULT_COLOR := Color(1.0, 0.5, 0.0, 1.0)
const DEFAULT_THICKNESS := 2

# 旧版（未分组）设置路径，仅用于迁移清理
const LEGACY_SETTING_COLOR := "highlight_outline/outline_color"
const LEGACY_SETTING_THICKNESS := "highlight_outline/thickness"

var _compositor: Compositor
var _effect: OutlineCompositorEffect
var _stencil_material: StandardMaterial3D
var _selected_node: MeshInstance3D


func _enter_tree() -> void:
	_register_settings()

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
	_apply_settings_to_effect()
	_compositor = Compositor.new()
	_compositor.compositor_effects = [_effect]
	
	get_editor_interface().get_selection().selection_changed.connect(_on_selection_changed)
	ProjectSettings.settings_changed.connect(_on_project_settings_changed)
	
	call_deferred("_attach_compositor")


func _exit_tree() -> void:
	_clear_outline()
	_detach_compositor()
	if ProjectSettings.settings_changed.is_connected(_on_project_settings_changed):
		ProjectSettings.settings_changed.disconnect(_on_project_settings_changed)
	_stencil_material = null
	_effect = null
	_compositor = null


# 仅在用户于插件管理器中"禁用"时调用，编辑器关闭不会触发 → 避免 project.godot 反复改写
func _disable_plugin() -> void:
	if ProjectSettings.settings_changed.is_connected(_on_project_settings_changed):
		ProjectSettings.settings_changed.disconnect(_on_project_settings_changed)
	# 移除当前分组设置，并顺带清理旧版残留键
	for setting: String in [SETTING_COLOR, SETTING_THICKNESS, LEGACY_SETTING_COLOR, LEGACY_SETTING_THICKNESS]:
		ProjectSettings.set_setting(setting, null)     # null = 擦除该设置项
	ProjectSettings.save()


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


# --- Private Functions ---

# 注册项目设置（保留用户已改过的值，只补默认值/类型提示/初始值）
func _register_settings() -> void:
	_migrate_legacy_settings()

	# 轮廓颜色
	if not ProjectSettings.has_setting(SETTING_COLOR):
		ProjectSettings.set_setting(SETTING_COLOR, DEFAULT_COLOR)
	ProjectSettings.set_initial_value(SETTING_COLOR, DEFAULT_COLOR)
	ProjectSettings.add_property_info({
		"name": SETTING_COLOR,
		"type": TYPE_COLOR,
	})
	ProjectSettings.set_as_basic(SETTING_COLOR, true)

	# 轮廓粗细
	if not ProjectSettings.has_setting(SETTING_THICKNESS):
		ProjectSettings.set_setting(SETTING_THICKNESS, DEFAULT_THICKNESS)
	ProjectSettings.set_initial_value(SETTING_THICKNESS, DEFAULT_THICKNESS)
	ProjectSettings.add_property_info({
		"name": SETTING_THICKNESS,
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_RANGE,
		"hint_string": "0,181,1",
	})
	ProjectSettings.set_as_basic(SETTING_THICKNESS, true)


# 把旧版未分组的设置迁移到新路径，再擦除旧键
func _migrate_legacy_settings() -> void:
	if ProjectSettings.has_setting(LEGACY_SETTING_COLOR) and not ProjectSettings.has_setting(SETTING_COLOR):
		ProjectSettings.set_setting(SETTING_COLOR, ProjectSettings.get_setting(LEGACY_SETTING_COLOR))
	if ProjectSettings.has_setting(LEGACY_SETTING_THICKNESS) and not ProjectSettings.has_setting(SETTING_THICKNESS):
		ProjectSettings.set_setting(SETTING_THICKNESS, ProjectSettings.get_setting(LEGACY_SETTING_THICKNESS))

	ProjectSettings.set_setting(LEGACY_SETTING_COLOR, null)
	ProjectSettings.set_setting(LEGACY_SETTING_THICKNESS, null)


# 把项目设置的值应用到 effect（thickness setter 会同步重算 jump-flood pass 数）
func _apply_settings_to_effect() -> void:
	_effect.thickness = int(ProjectSettings.get_setting(SETTING_THICKNESS, DEFAULT_THICKNESS))
	_effect.outline_color = ProjectSettings.get_setting(SETTING_COLOR, DEFAULT_COLOR)


# --- Signal Callbacks ---

func _on_project_settings_changed() -> void:
	if _effect != null:
		_apply_settings_to_effect()
