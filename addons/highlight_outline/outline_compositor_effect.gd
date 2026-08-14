@tool
extends CompositorEffect
class_name OutlineCompositorEffect

## 选中物体外轮廓（剪影）CompositorEffect。
## 流程：stencil_copy（把 stencil 边界复制为种子）→ jump_flood 多 pass（距离场扩散）
##      → draw_outline（距离 ≤ 厚度的像素混合轮廓色）。
## 参考 bgolus 的宽轮廓算法与 dmlary/godot-stencil-based-outline-compositor-effect（MIT）。

# --- Exports ---
## 轮廓颜色。
@export var outline_color: Color = Color(1.0, 0.5, 0.0, 1.0)

## 轮廓厚度（屏幕空间像素）。
@export_range(0, 181) var thickness: int = 4:
	set(value):
		value = clampi(value, 0, 181)
		thickness = value
		_passes = 0
		while value > 0:
			value = value >> 1
			_passes += 1

## 选中的物体写入的 stencil 值。
@export var stencil_value: int = 1

## 检查 stencil 时使用的掩码。
@export var stencil_mask: int = 1

# --- Private Vars ---
## jump-flood 需要执行的 pass 数（由 thickness 推导）。
var _passes: int = 1

var _shader_dir: String = get_script().get_path().get_base_dir() + "/shaders/"
var _jf_shader_file: String = _shader_dir + "jump_flood.glsl"
var _sc_shader_file: String = _shader_dir + "stencil_copy.glsl"
var _do_shader_file: String = _shader_dir + "draw_outline.glsl"

var _rd: RenderingDevice

# stencil copy 管线相关
var _sc_shader: RID
var _sc_uniform_set: RID
var _sc_framebuffer: RID
var _sc_pipeline: RID

# draw outline 管线相关
var _do_shader: RID
var _do_pipeline: RID

# 全屏 quad 顶点
var _scdo_vertex_format: int
var _scdo_vertex_buffer: RID
var _scdo_vertex_array: RID

# 分辨率 uniform buffer（stencil copy 与 draw outline 共用）
var _scdo_uniform_buffer: RID

# jump-flood 相关
var _jf_shader: RID
var _jf_pipeline: RID
var _jf_uniform_sets: Array[RID] = [RID(), RID()]

# 缓存，用于检测变化
var _color_texture: RID
var _depth_texture: RID
var _resolution: Vector2i = Vector2i(1, 1)

# 跳洪扩散使用的 ping-pong 纹理
var _textures: Array[RID] = [RID(), RID(), RID()]

var _mutex: Mutex = Mutex.new()
var _rebuild_pipelines: bool = true

# --- Built-in Functions ---

func _init() -> void:
	# 使用透明 overlay 写 stencil（transparent pass 写入），
	# 故在 POST_TRANSPARENT 阶段读取 stencil。
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	
	_rd = RenderingServer.get_rendering_device()
	
	# 全屏 quad 顶点格式（一个 vec3 属性）
	var vertex_attr := RDVertexAttribute.new()
	vertex_attr.location = 0
	vertex_attr.format = RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT
	vertex_attr.stride = 4 * 3
	_scdo_vertex_format = _rd.vertex_format_create([vertex_attr])
	
	# 一个覆盖整个屏幕的大三角形（CCW 绕序，正面朝向相机）
	var vertex_data := PackedVector3Array([
		Vector3(-1, -1, 0),
		Vector3(3, -1, 0),
		Vector3(-1, 3, 0),
	])
	var vertex_bytes := vertex_data.to_byte_array()
	_scdo_vertex_buffer = _rd.vertex_buffer_create(vertex_bytes.size(), vertex_bytes)
	_scdo_vertex_array = _rd.vertex_array_create(3, _scdo_vertex_format, [_scdo_vertex_buffer])
	
	# 分辨率 uniform buffer（16 字节）
	var buffer := PackedFloat32Array([1.0, 1.0, 0.0, 0.0]).to_byte_array()
	_scdo_uniform_buffer = _rd.uniform_buffer_create(buffer.size(), buffer)
	
	_rebuild_pipelines = true


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if _jf_shader.is_valid():
			_rd.free_rid(_jf_shader)
		if _sc_shader.is_valid():
			_rd.free_rid(_sc_shader)
		if _do_shader.is_valid():
			_rd.free_rid(_do_shader)
		for rid: RID in _textures:
			if rid.is_valid():
				_rd.free_rid(rid)
		if _scdo_vertex_buffer.is_valid():
			_rd.free_rid(_scdo_vertex_buffer)
		if _scdo_uniform_buffer.is_valid():
			_rd.free_rid(_scdo_uniform_buffer)


# --- Private Functions ---

func _load_glsl_from_file(p_path: String) -> RDShaderSPIRV:
	var shader_file: RDShaderFile = ResourceLoader.load(p_path)
	if shader_file == null:
		push_error("Failed to load shader file: ", p_path)
		return null
	return shader_file.get_spirv()


# 构建 stencil copy 渲染管线：用 stencil 测试过滤，把选中物体像素写入种子纹理。
func _build_sc_pipeline() -> void:
	if _sc_shader.is_valid():
		_rd.free_rid(_sc_shader)
		_sc_shader = RID()
	
	var shader_spirv := _load_glsl_from_file(_sc_shader_file)
	if shader_spirv == null:
		push_error("Failed to load stencil copy shader")
		return
	_sc_shader = _rd.shader_create_from_spirv(shader_spirv)
	assert(_sc_shader.is_valid())
	
	# 分辨率 uniform set
	assert(_scdo_uniform_buffer.is_valid())
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	uniform.binding = 0
	uniform.add_id(_scdo_uniform_buffer)
	_sc_uniform_set = _rd.uniform_set_create([uniform], _sc_shader, 0)
	
	# 构建 framebuffer：颜色（种子纹理）+ 深度（真实场景 depth-stencil）
	assert(_textures[0].is_valid())
	assert(_depth_texture.is_valid())
	
	var attachments: Array[RDAttachmentFormat] = []
	var attachment_format := RDAttachmentFormat.new()
	
	var tex_format := _rd.texture_get_format(_textures[0])
	attachment_format.format = tex_format.format
	attachment_format.usage_flags = tex_format.usage_bits
	attachment_format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	attachments.push_back(attachment_format)
	
	var depth_format := _rd.texture_get_format(_depth_texture)
	attachment_format = RDAttachmentFormat.new()
	attachment_format.format = depth_format.format
	attachment_format.usage_flags = depth_format.usage_bits
	attachment_format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	attachments.push_back(attachment_format)
	
	var format := _rd.framebuffer_format_create(attachments)
	_sc_framebuffer = _rd.framebuffer_create([_textures[0], _depth_texture], format)
	assert(_sc_framebuffer.is_valid())
	
	# 管线：stencil 测试 = (stencil & mask) == (reference & mask) 的像素通过
	var blend := RDPipelineColorBlendState.new()
	var blend_attachment := RDPipelineColorBlendStateAttachment.new()
	blend.attachments.push_back(blend_attachment)
	
	var stencil_state := RDPipelineDepthStencilState.new()
	stencil_state.enable_stencil = true
	stencil_state.front_op_compare = RenderingDevice.COMPARE_OP_EQUAL
	stencil_state.front_op_compare_mask = stencil_mask
	stencil_state.front_op_reference = stencil_value
	stencil_state.front_op_fail = RenderingDevice.STENCIL_OP_KEEP
	stencil_state.front_op_pass = RenderingDevice.STENCIL_OP_KEEP
	
	_sc_pipeline = _rd.render_pipeline_create(
		_sc_shader,
		format,
		_scdo_vertex_format,
		RenderingDevice.RENDER_PRIMITIVE_TRIANGLES,
		RDPipelineRasterizationState.new(),
		RDPipelineMultisampleState.new(),
		stencil_state,
		blend,
	)
	assert(_sc_pipeline.is_valid())


# 构建 draw outline compute 管线。
func _build_do_pipeline() -> void:
	if _do_shader.is_valid():
		_rd.free_rid(_do_shader)
		_do_shader = RID()
	
	var shader_spirv := _load_glsl_from_file(_do_shader_file)
	if shader_spirv == null:
		push_error("Failed to load draw outline shader")
		return
	_do_shader = _rd.shader_create_from_spirv(shader_spirv)
	assert(_do_shader.is_valid())
	
	_do_pipeline = _rd.compute_pipeline_create(_do_shader)
	assert(_do_pipeline.is_valid())


# 构建 jump-flood compute 管线与 ping-pong uniform set。
func _build_jf_pipeline() -> void:
	if _jf_shader.is_valid():
		_rd.free_rid(_jf_shader)
		_jf_shader = RID()
	
	var shader_spirv := _load_glsl_from_file(_jf_shader_file)
	if shader_spirv == null:
		push_error("Failed to load jump flood shader")
		return
	_jf_shader = _rd.shader_create_from_spirv(shader_spirv)
	assert(_jf_shader.is_valid())
	
	_jf_pipeline = _rd.compute_pipeline_create(_jf_shader)
	assert(_jf_pipeline.is_valid())
	
	assert(_textures[0].is_valid())
	assert(_textures[1].is_valid())
	
	# 两个 uniform set，用于 ping-pong 交换纹理
	var groups: Array = [[0, _textures[0], _textures[1]], [1, _textures[1], _textures[0]]]
	for group: Array in groups:
		var pass_number: int = group[0]
		var src_texture: RID = group[1]
		var dest_texture: RID = group[2]
		
		var src_uniform := RDUniform.new()
		src_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		src_uniform.binding = 0
		src_uniform.add_id(src_texture)
		
		var dest_uniform := RDUniform.new()
		dest_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		dest_uniform.binding = 1
		dest_uniform.add_id(dest_texture)
		
		_jf_uniform_sets[pass_number] = _rd.uniform_set_create([src_uniform, dest_uniform], _jf_shader, 0)


# 创建 jump-flood 输出纹理（与渲染分辨率一致）。
func _build_textures() -> void:
	var texture_format := RDTextureFormat.new()
	texture_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	texture_format.width = _resolution.x
	texture_format.height = _resolution.y
	texture_format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	texture_format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	)
	
	var texture_view := RDTextureView.new()
	
	for i: int in _textures.size():
		var rid: RID = _rd.texture_create(texture_format, texture_view)
		assert(rid.is_valid())
		var old_rid: RID = _textures[i]
		_textures[i] = rid
		if old_rid.is_valid():
			_rd.free_rid(old_rid)


# 更新分辨率 uniform buffer。
func _update_common_buffers() -> void:
	assert(_scdo_uniform_buffer.is_valid())
	var buffer := PackedFloat32Array([float(_resolution.x), float(_resolution.y), 0.0, 0.0]).to_byte_array()
	_rd.buffer_update(_scdo_uniform_buffer, 0, buffer.size(), buffer)


# --- Public Functions ---

# 由渲染线程每帧调用。
func _render_callback(_p_effect_callback_type: int, p_render_data: RenderData) -> void:
	if not _rd:
		return
	
	var render_scene_buffers: RenderSceneBuffersRD = p_render_data.get_render_scene_buffers()
	if render_scene_buffers == null:
		return
	
	var size := render_scene_buffers.get_internal_size()
	if size.x == 0 and size.y == 0:
		return
	
	var rebuild := false
	
	if _rebuild_pipelines:
		_mutex.lock()
		_rebuild_pipelines = false
		_mutex.unlock()
		rebuild = true
	
	if _resolution != size:
		_resolution = size
		rebuild = true
	
	var color_tex: RID = render_scene_buffers.get_color_layer(0)
	if color_tex != _color_texture:
		_color_texture = color_tex
		rebuild = true
	
	var depth_tex: RID = render_scene_buffers.get_depth_layer(0)
	if depth_tex != _depth_texture:
		_depth_texture = depth_tex
		rebuild = true
	
	if rebuild:
		_build_textures()
		_update_common_buffers()
		_build_sc_pipeline()
		_build_jf_pipeline()
		_build_do_pipeline()
	
	# 1 stencil copy：用 stencil 测试过滤，生成种子纹理
	var draw_list := _rd.draw_list_begin(
		_sc_framebuffer,
		RenderingDevice.DRAW_CLEAR_COLOR_0,
		PackedColorArray([Color(-1, -1, 32768, -1)]),
		1.0,
		0,
		Rect2(),
		RenderingDevice.OPAQUE_PASS,
	)
	
	_rd.draw_list_bind_render_pipeline(draw_list, _sc_pipeline)
	_rd.draw_list_bind_vertex_array(draw_list, _scdo_vertex_array)
	_rd.draw_list_bind_uniform_set(draw_list, _sc_uniform_set, 0)
	_rd.draw_list_draw(draw_list, false, 3)
	_rd.draw_list_end()
	
	# 2 jump-flood：距离场扩散
	@warning_ignore("integer_division")
	var x_groups: int = (_resolution.x - 1) / 8 + 1
	@warning_ignore("integer_division")
	var y_groups: int = (_resolution.y - 1) / 8 + 1
	
	var push_constant := PackedByteArray()
	push_constant.resize(4)  # 仅 uint stride，4 字节
	
	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list, _jf_pipeline)
	
	for i: int in _passes:
		var stride: int = 1 << (_passes - i - 1)
		push_constant.encode_u32(0, stride)
		_rd.compute_list_set_push_constant(compute_list, push_constant, push_constant.size())
		_rd.compute_list_bind_uniform_set(compute_list, _jf_uniform_sets[i & 0x1], 0)
		_rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
	
	_rd.compute_list_end()
	
	# 3 draw outline：把轮廓色混合到 color buffer
	var src_uniform := RDUniform.new()
	src_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	src_uniform.binding = 0
	src_uniform.add_id(_textures[_passes & 0x1])
	
	var dest_uniform := RDUniform.new()
	dest_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	dest_uniform.binding = 1
	dest_uniform.add_id(_color_texture)
	
	var uniform_set := UniformSetCacheRD.get_cache(_do_shader, 0, [src_uniform, dest_uniform])
	assert(uniform_set.is_valid())
	
	var do_push_constant := PackedByteArray()
	do_push_constant.resize(20)  # vec4 color(16) + uint dist(4)
	do_push_constant.encode_float(0, outline_color.r)
	do_push_constant.encode_float(4, outline_color.g)
	do_push_constant.encode_float(8, outline_color.b)
	do_push_constant.encode_float(12, outline_color.a)
	do_push_constant.encode_u32(16, thickness * thickness)
	
	compute_list = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list, _do_pipeline)
	_rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	_rd.compute_list_set_push_constant(compute_list, do_push_constant, do_push_constant.size())
	_rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
	_rd.compute_list_end()
