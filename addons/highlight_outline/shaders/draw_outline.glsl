#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) uniform image2D u_src_image;
layout(rgba16f, set = 0, binding = 1) uniform image2D u_dest_image;

layout(push_constant, std430) uniform Params {
	vec4 color;
	uint dist;
} params;

void main() {
	ivec2 image_size = imageSize(u_src_image);
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy);

	if (coord.x >= image_size.x || coord.y >= image_size.y) {
		return;
	}

	vec4 output_color = imageLoad(u_dest_image, coord);

	// 距离场值在 (0, dist] 范围内 → 轮廓
	vec4 value = imageLoad(u_src_image, coord);
	if (value.b > 0.0 && value.b <= float(params.dist)) {
		output_color = params.color;
	}

	imageStore(u_dest_image, coord, output_color);
}
