# Godot Highlight Outline

<img width="1465" height="950" alt="截屏2026-08-14 17 50 26" src="https://github.com/user-attachments/assets/47adb442-fff5-4196-8017-7c6aacc4342e" />

A **Godot editor plugin** that draws a crisp, screen-space silhouette outline around the selected `MeshInstance3D` in the 3D viewport.

Unlike typical edge-detection plugins, it highlights **only the outer silhouette** of the selected object — not the internal hard edges, UV seams, or wireframe lines.

> [!NOTE]
> This is an **editor-only** tool plugin. It enhances the editor's selection feedback and does not add any runtime game functionality.

## Features

- Draws a clean **silhouette outline** (no internal edge noise).
- **Screen-space uniform thickness** — constant width regardless of camera distance or object scale.
- Adjustable **color** and **thickness** (in pixels).
- Does **not modify** the selected object's original material.
- Fully GPU-driven using **stencil buffer + CompositorEffect + jump flooding** — logarithmic pass count, suitable even for thick outlines.

## How It Works

1. When a `MeshInstance3D` is selected, the plugin attaches a **transparent `StandardMaterial3D` overlay** to it. The overlay is invisible (`albedo alpha = 0`) but writes `1` into the **stencil buffer** across the object's full projection — it enables both `WRITE` and `WRITE_DEPTH_FAIL` stencil flags, so even occluded parts of the object are marked.
2. A custom `CompositorEffect` (`outline_compositor_effect.gd`) is attached to the editor 3D viewport's camera and runs after the transparent pass.
3. The effect performs three steps:
   - **`stencil_copy`** — copies the stencil mask into a "seed" texture (pixels covered by the selected object become seeds).
   - **`jump_flood`** ×N — spreads a distance field across the screen using the [Jump Flooding algorithm](https://bgolus.medium.com/the-quest-for-very-wide-outlines-ba82ed442cd9). Every pixel learns its squared distance to the nearest seed.
   - **`draw_outline`** — pixels whose distance falls inside `(0, thickness²]` are written with the outline color.

Because the outline is derived from a **stencil mask** (not a normal/depth Sobel filter), internal hard edges are never highlighted.

## Requirements

- **Godot 4.5+** (stencil buffer support; tested on **4.7.1**).
- **Forward+** or **Mobile** renderer.
  - ⚠️ The **Compatibility** renderer is **not supported** (`RenderingDevice` / `CompositorEffect` are unavailable).

## Installation

1. Copy the `highlight_outline` folder into your project's `addons/` directory:

   ```
   res://addons/highlight_outline/
   ```

2. Open **Project → Project Settings → Plugins** and enable **Highlight Outline**.

3. Open the 3D viewport and select any `MeshInstance3D` — its silhouette is outlined automatically.

## Configuration

Edit the defaults directly in `plugin.gd` inside `_enter_tree()`:

```gdscript
_effect = OutlineEffectScript.new()
_effect.thickness = 8 # outline width in pixels
_effect.outline_color = Color(1.0, 0.5, 0.0, 1.0) # outline color
```

| Setting | Type | Range | Default | Description |
|---------|------|-------|---------|-------------|
| `thickness` | `int` | `0 – 181` | `4` | Outline width in screen-space pixels. |
| `outline_color` | `Color` | — | `Color(1, 0.5, 0, 1)` | Outline color (orange). |

> Changes take effect immediately on the next selection; no shader recompilation is required.

## Project Structure

```
highlight_outline/
├── plugin.cfg                    # Plugin manifest
├── plugin.gd                     # Selection handling, Compositor mounting, stencil overlay management
├── outline_compositor_effect.gd  # CompositorEffect: stencil_copy → jump_flood → draw_outline
└── shaders/
    ├── stencil_copy.glsl         # Copies the stencil mask into a seed texture
    ├── jump_flood.glsl           # Jump flooding distance-field propagation
    └── draw_outline.glsl         # Writes the outline color inside the distance band
```

## Limitations

- Editor-only; no runtime effect.
- Only the **first** `MeshInstance3D` in the current selection is highlighted.
- Tested primarily in **single-viewport** mode (`get_editor_viewport_3d(0)`); 2×2 / 4-view layouts are not guaranteed stable.
- Resizing an **embedded** (docked/floating) game panel while the effect is active may hit engine assertions — a known Godot issue also reported by the reference implementation.
- Stencil support is experimental and was buggy in early 4.5 builds; **4.7+ is recommended**.

## License

[MIT](LICENSE)

## Acknowledgments

- [Ben Golus (@bgolus)](https://bgolus.medium.com/the-quest-for-very-wide-outlines-ba82ed442cd9) — the Jump Flooding wide-outline algorithm.
- [dmlary/godot-stencil-based-outline-compositor-effect](https://github.com/dmlary/godot-stencil-based-outline-compositor-effect) — reference CompositorEffect implementation (MIT).
