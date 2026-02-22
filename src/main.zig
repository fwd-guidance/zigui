const std = @import("std");

const c = @cImport({
    @cDefine("RGFW_WEBGPU", {});
    @cInclude("RGFW.h");
    @cInclude("webgpu/webgpu.h");
    @cInclude("stb_truetype.h");
});

// ==========================================
// 1. UI DATA STRUCTURES & ARCHITECTURE
// ==========================================

pub const Rect = struct {
    pos: [2]f32 = .{ 0.0, 0.0 },
    size: [2]f32 = .{ 0.0, 0.0 },
};

pub const SizeKind = enum { pixels, percent_of_parent, children_sum };

pub const Size = struct {
    kind: SizeKind,
    value: f32,
};

pub const BoxFlags = packed struct {
    clickable: bool = false,
    draw_background: bool = false,
    layout_horizontal: bool = false,
    clip_children: bool = false,
    floating: bool = false,
    _padding: u11 = 0,
};

pub const Box = struct {
    // Tree Links
    first: ?*Box = null,
    last: ?*Box = null,
    next: ?*Box = null,
    prev: ?*Box = null,
    parent: ?*Box = null,

    hash: u64,
    flags: BoxFlags,
    z_index: u32 = 0,

    pref_size: [2]Size = .{ .{ .kind = .children_sum, .value = 0.0 }, .{ .kind = .children_sum, .value = 0.0 } },
    rect: Rect = .{},
    clip_rect: [4]f32 = .{ 0.0, 0.0, 10000.0, 10000.0 }, // minX, minY, maxX, maxY

    bg_color: [4]f32 = .{ 0.2, 0.2, 0.2, 1.0 },
    corner_radius: f32 = 0.0,

    // Filled during Build Phase based on Retained State
    hot_t: f32 = 0.0,
    active_t: f32 = 0.0,
    text: []const u8 = "",
};

pub const BoxState = struct {
    last_frame_rect: Rect = .{},
    last_frame_clip: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 },
    last_frame_z_index: u32 = 0,
    last_frame_touched: u64 = 0,

    clickable: bool = false,

    // Animation states
    hot_t: f32 = 0.0,
    active_t: f32 = 0.0,
};

pub const InstanceData = extern struct {
    rect_pos: [2]f32,
    rect_size: [2]f32,
    color: [4]f32,
    clip_rect: [4]f32,
    corner_radius: f32,
    edge_softness: f32,
    type_flag: u32,

    uv_min: [2]f32,
    uv_max: [2]f32,
};

pub const InputState = struct {
    mouse_x: f32 = 0.0,
    mouse_y: f32 = 0.0,
    mouse_left_down: bool = false,
    mouse_left_pressed: bool = false,
    mouse_left_released: bool = false,
};

pub const Font = struct {
    cdata: [96]c.stbtt_bakedchar, // ASCII characters 32 through 126
    texture: c.WGPUTexture,
    bind_group: c.WGPUBindGroup,
};

// ==========================================
// 2. THE UI ENGINE
// ==========================================

pub const UI = struct {
    allocator: std.mem.Allocator,
    frame_arena: std.heap.ArenaAllocator,
    retained_state: std.AutoHashMap(u64, BoxState),

    root: ?*Box = null,
    parent_stack: [64]*Box = undefined,
    parent_stack_top: usize = 0,

    input: InputState = .{},
    current_frame_index: u64 = 0,

    hot_hash_this_frame: u64 = 0,
    active_hash: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) !UI {
        return UI{
            .allocator = allocator,
            .frame_arena = std.heap.ArenaAllocator.init(allocator),
            .retained_state = std.AutoHashMap(u64, BoxState).init(allocator),
        };
    }

    pub fn deinit(self: *UI) void {
        self.retained_state.deinit();
        self.frame_arena.deinit();
    }

    fn generateId(self: *UI, string_id: []const u8) u64 {
        const parent_hash = if (self.parent_stack_top > 0)
            self.parent_stack[self.parent_stack_top - 1].hash
        else
            2166136261;

        var hash = parent_hash;
        for (string_id) |char| {
            hash ^= char;
            hash *%= 1099511628211;
        }
        return hash;
    }

    pub fn beginFrame(self: *UI, dt: f32, input: InputState) void {
        _ = self.frame_arena.reset(.retain_capacity);
        self.input = input;
        self.current_frame_index += 1;
        self.parent_stack_top = 0;
        self.root = null;

        if (!input.mouse_left_down and !input.mouse_left_released) {
            self.active_hash = 0;
        }

        // 1. Z-Sorted Input Resolution
        self.hot_hash_this_frame = 0;
        var highest_z: u32 = 0;

        var it = self.retained_state.iterator();
        while (it.next()) |entry| {
            const state = entry.value_ptr;
            if (state.last_frame_touched != self.current_frame_index - 1) continue;

            if (!state.clickable) continue;

            const rx = state.last_frame_rect;
            const cx = state.last_frame_clip;

            const in_rect = input.mouse_x >= rx.pos[0] and input.mouse_x <= rx.pos[0] + rx.size[0] and
                input.mouse_y >= rx.pos[1] and input.mouse_y <= rx.pos[1] + rx.size[1];

            const in_clip = input.mouse_x >= cx[0] and input.mouse_y >= cx[1] and
                input.mouse_x <= cx[2] and input.mouse_y <= cx[3];

            if (in_rect and in_clip) {
                if (self.hot_hash_this_frame == 0 or state.last_frame_z_index >= highest_z) {
                    self.hot_hash_this_frame = entry.key_ptr.*;
                    highest_z = state.last_frame_z_index;
                }
            }
        }

        // 2. Smooth Animations (Interpolate State Cache)
        it = self.retained_state.iterator();
        while (it.next()) |entry| {
            var state = entry.value_ptr;

            const target_hot: f32 = if (entry.key_ptr.* == self.hot_hash_this_frame) 1.0 else 0.0;
            state.hot_t += (target_hot - state.hot_t) * (dt * 15.0); // 15.0 = speed

            const target_active: f32 = if (entry.key_ptr.* == self.active_hash) 1.0 else 0.0;
            state.active_t += (target_active - state.active_t) * (dt * 25.0);
        }
    }

    pub fn pushBox(self: *UI, string_id: []const u8, flags: BoxFlags) *Box {
        const hash = self.generateId(string_id);
        var box = self.frame_arena.allocator().create(Box) catch unreachable;
        box.* = Box{ .hash = hash, .flags = flags };

        // Attach to Tree
        if (self.parent_stack_top > 0) {
            var parent = self.parent_stack[self.parent_stack_top - 1];
            box.parent = parent;
            if (parent.last) |last| {
                last.next = box;
                box.prev = last;
                parent.last = box;
            } else {
                parent.first = box;
                parent.last = box;
            }
        } else {
            self.root = box;
        }

        // Push to stack
        self.parent_stack[self.parent_stack_top] = box;
        self.parent_stack_top += 1;

        // Sync State
        var state_entry = self.retained_state.getOrPut(hash) catch unreachable;
        if (!state_entry.found_existing) {
            state_entry.value_ptr.* = BoxState{};
        }
        state_entry.value_ptr.last_frame_touched = self.current_frame_index;
        state_entry.value_ptr.clickable = flags.clickable;

        box.hot_t = state_entry.value_ptr.hot_t;
        box.active_t = state_entry.value_ptr.active_t;

        // Interaction
        if (flags.clickable) {
            if (self.hot_hash_this_frame == hash) {
                if (self.input.mouse_left_pressed) {
                    self.active_hash = hash;
                }
            }
            //if (self.active_hash == hash and !self.input.mouse_left_down) {
            //    self.active_hash = 0;
            //}
        }

        return box;
    }

    pub fn popBox(self: *UI) void {
        self.parent_stack_top -= 1;
    }

    // --- Layout Algorithms ---
    pub fn endFrame(self: *UI, app: *AppState) void {
        if (self.root) |root| {
            // Screen Bounds setup
            root.rect.size = .{ 800.0, 600.0 }; // Should match window
            root.clip_rect = .{ 0.0, 0.0, 800.0, 600.0 };

            self.computeSizeBottomUp(root);
            self.computeLayoutTopDown(root, 0.0, 0.0);

            // Cache final state and generate draw commands
            var instances = std.ArrayList(InstanceData){};
            defer instances.deinit(self.allocator);

            self.buildRenderCommands(root, &instances, &app.font);
            app.renderUI(instances.items);
        }
    }

    fn computeSizeBottomUp(self: *UI, node: *Box) void {
        var child_opt = node.first;
        while (child_opt) |child| : (child_opt = child.next) {
            self.computeSizeBottomUp(child);
        }

        for (0..2) |axis| {
            switch (node.pref_size[axis].kind) {
                .pixels => node.rect.size[axis] = node.pref_size[axis].value,
                .children_sum => {
                    var total: f32 = 0.0;
                    var max: f32 = 0.0;
                    var iter = node.first;
                    while (iter) |b| : (iter = b.next) {
                        if (!b.flags.floating) {
                            total += b.rect.size[axis];
                            max = @max(max, b.rect.size[axis]);
                        }
                    }
                    const is_layout_axis = (axis == 0 and node.flags.layout_horizontal) or
                        (axis == 1 and !node.flags.layout_horizontal);
                    node.rect.size[axis] = if (is_layout_axis) total else max;
                },
                .percent_of_parent => {}, // Handled top-down
            }
        }
    }

    fn computeLayoutTopDown(self: *UI, node: *Box, start_x: f32, start_y: f32) void {
        node.rect.pos = .{ start_x, start_y };
        var cursor_x = start_x;
        var cursor_y = start_y;

        var children_clip = node.clip_rect;
        if (node.flags.clip_children) {
            children_clip[0] = @max(children_clip[0], node.rect.pos[0]);
            children_clip[1] = @max(children_clip[1], node.rect.pos[1]);
            children_clip[2] = @min(children_clip[2], node.rect.pos[0] + node.rect.size[0]);
            children_clip[3] = @min(children_clip[3], node.rect.pos[1] + node.rect.size[1]);
        }

        var child_opt = node.first;
        while (child_opt) |child| : (child_opt = child.next) {
            for (0..2) |axis| {
                if (child.pref_size[axis].kind == .percent_of_parent) {
                    child.rect.size[axis] = node.rect.size[axis] * (child.pref_size[axis].value / 100.0);
                }
            }

            if (child.flags.floating) {
                child.clip_rect = .{ 0.0, 0.0, 800.0, 600.0 }; // Escape clipping
                self.computeLayoutTopDown(child, start_x, start_y);
            } else {
                child.clip_rect = children_clip;
                self.computeLayoutTopDown(child, cursor_x, cursor_y);
                if (node.flags.layout_horizontal) {
                    cursor_x += child.rect.size[0];
                } else {
                    cursor_y += child.rect.size[1];
                }
            }
        }
    }

    fn buildRenderCommands(self: *UI, node: *Box, instances: *std.ArrayList(InstanceData), font: *Font) void {
        // Cache state for next frame
        if (self.retained_state.getPtr(node.hash)) |state| {
            state.last_frame_rect = node.rect;
            state.last_frame_clip = node.clip_rect;
            state.last_frame_z_index = node.z_index;
        }

        if (node.flags.draw_background) {
            instances.append(self.allocator, InstanceData{
                .rect_pos = node.rect.pos,
                .rect_size = node.rect.size,
                .color = node.bg_color,
                .clip_rect = node.clip_rect,
                .corner_radius = node.corner_radius,
                .edge_softness = 1.0,
                .type_flag = 0,
                .uv_min = .{ 0.0, 0.0 },
                .uv_max = .{ 0.0, 0.0 },
            }) catch unreachable;
        }

        // Draw Background (Existing logic) ...

        // Draw Text
        if (node.text.len > 0) {
            var cursor_x = node.rect.pos[0];
            var cursor_y = node.rect.pos[1] + 24.0; // Offset by baseline

            for (node.text) |char| {
                if (char >= 32 and char < 128) {
                    var q: c.stbtt_aligned_quad = undefined;
                    // This STB function calculates the exact pos and UVs for this character
                    c.stbtt_GetBakedQuad(&font.cdata, 512, 512, char - 32, &cursor_x, &cursor_y, &q, 1);

                    instances.append(self.allocator, InstanceData{
                        .rect_pos = .{ q.x0, q.y0 },
                        .rect_size = .{ q.x1 - q.x0, q.y1 - q.y0 },
                        .color = .{ 1.0, 1.0, 1.0, 1.0 }, // White text
                        .clip_rect = node.clip_rect,
                        .corner_radius = 0.0,
                        .edge_softness = 0.0,
                        .type_flag = 1, // Flag as text
                        .uv_min = .{ q.s0, q.t0 },
                        .uv_max = .{ q.s1, q.t1 },
                    }) catch unreachable;
                }
            }
        }

        var iter = node.first;
        while (iter) |child| : (iter = child.next) {
            self.buildRenderCommands(child, instances, font);
        }
    }

    // --- High Level API ---
    pub fn button(self: *UI, text: []const u8) bool {
        var box = self.pushBox(text, BoxFlags{ .clickable = true, .draw_background = true });

        box.text = text;
        box.pref_size = .{ .{ .kind = .pixels, .value = 150.0 }, .{ .kind = .pixels, .value = 40.0 } };
        box.corner_radius = 8.0;

        // Smooth color interpolation based on animated state
        const base_color = [4]f32{ 0.2, 0.2, 0.2, 1.0 };
        const hover_color = [4]f32{ 1.0, 0.0, 0.0, 1.0 };
        const active_color = [4]f32{ 0.0, 0.0, 1.0, 1.0 };

        // Blend colors using the _t values!
        for (0..3) |i| {
            box.bg_color[i] = base_color[i] +
                (hover_color[i] - base_color[i]) * box.hot_t +
                (active_color[i] - hover_color[i]) * box.active_t;
        }

        self.popBox();
        return self.active_hash == box.hash and self.input.mouse_left_released and self.hot_hash_this_frame == box.hash;
    }

    pub fn label(self: *UI, text: []const u8) void {
        var box = self.pushBox(text, BoxFlags{}); // No background, not clickable
        box.text = text;

        // Optional: Force the box size to wrap the text somewhat tightly
        // (In a full engine, you'd calculate this exactly using the STB font metrics)
        box.pref_size = .{ .{ .kind = .pixels, .value = @as(f32, @floatFromInt(text.len)) * 16.0 }, .{ .kind = .pixels, .value = 32.0 } };

        self.popBox();
    }
};

// ==========================================
// 3. WGPU BACKEND & SHADER
// ==========================================

const wgsl_shader =
    \\ struct VertexInput { @location(0) pos: vec2<f32>, };
    \\ struct InstanceInput {
    \\     @location(1) rect_pos: vec2<f32>,
    \\     @location(2) rect_size: vec2<f32>,
    \\     @location(3) color: vec4<f32>,
    \\     @location(4) clip_rect: vec4<f32>,
    \\     @location(5) corner_radius: f32,
    \\     @location(6) edge_softness: f32,
    \\     @location(7) type_flag: u32,
    \\     @location(8) uv_min: vec2<f32>,
    \\     @location(9) uv_max: vec2<f32>,
    \\ };
    \\ struct VertexOutput {
    \\     @builtin(position) clip_pos: vec4<f32>,
    \\     @location(0) uv: vec2<f32>,
    \\     @location(1) color: vec4<f32>,
    \\     @location(2) box_size: vec2<f32>,
    \\     @location(3) corner_radius: f32,
    \\     @location(4) edge_softness: f32,
    \\     @location(5) clip_rect: vec4<f32>,
    \\     @location(6) type_flag: u32,
    \\     @location(7) tex_uv: vec2<f32>,
    \\ };
    \\
    \\ @group(0) @binding(0) var font_tex: texture_2d<f32>;
    \\ @group(0) @binding(1) var font_sampler: sampler;
    \\
    \\ @vertex fn vs_main(model: VertexInput, instance: InstanceInput) -> VertexOutput {
    \\     var out: VertexOutput;
    \\     out.uv = model.pos;
    \\     let pixel_pos = instance.rect_pos + (model.pos * instance.rect_size);
    \\     let screen_size = vec2<f32>(800.0, 600.0);
    \\     let ndc_x = (pixel_pos.x / screen_size.x) * 2.0 - 1.0;
    \\     let ndc_y = 1.0 - (pixel_pos.y / screen_size.y) * 2.0;
    \\     out.clip_pos = vec4<f32>(ndc_x, ndc_y, 0.0, 1.0);
    \\     out.uv = model.pos;
    \\     out.color = instance.color;
    \\     out.box_size = instance.rect_size;
    \\     out.corner_radius = instance.corner_radius;
    \\     out.edge_softness = max(instance.edge_softness, 0.001);
    \\     out.clip_rect = instance.clip_rect;
    \\     out.type_flag = instance.type_flag;
    \\     out.tex_uv = mix(instance.uv_min, instance.uv_max, model.pos);
    \\     return out;
    \\ }
    \\ @fragment fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    \\     // WGPU automatically converts @builtin(position) to framebuffer pixel coordinates here
    \\     let pixel_x = in.clip_pos.x;
    \\     let pixel_y = in.clip_pos.y;
    \\     
    \\     if (pixel_x < in.clip_rect[0] || pixel_y < in.clip_rect[1] || 
    \\         pixel_x > in.clip_rect[2] || pixel_y > in.clip_rect[3]) { discard; }
    \\     if (in.type_flag == 1u) {
    \\         let alpha = textureSample(font_tex, font_sampler, in.tex_uv).r;
    \\         if (alpha <= 0.01) { discard; }
    \\         return vec4<f32>(in.color.rgb, in.color.a * alpha);
    \\     } else {
    \\         let half_size = in.box_size * 0.5;
    \\         let pixel_pos = (in.uv * in.box_size) - half_size; 
    \\         let d = length(max(abs(pixel_pos) - half_size + in.corner_radius, vec2<f32>(0.0))) - in.corner_radius;
    \\         let alpha = 1.0 - smoothstep(0.0, in.edge_softness, d);
    \\         if (alpha <= 0.0) { discard; }
    \\         return vec4<f32>(in.color.rgb, in.color.a * alpha);
    \\    }
    \\ }
;

const AppState = struct {
    window: ?*c.RGFW_window,
    instance: c.WGPUInstance,
    surface: c.WGPUSurface,
    adapter: c.WGPUAdapter,
    device: c.WGPUDevice,
    queue: c.WGPUQueue,
    surface_format: c.WGPUTextureFormat,
    clear_color: [3]f32,

    // UI Graphics Pipeline
    pipeline: c.WGPURenderPipeline,
    vbo: c.WGPUBuffer,
    ibo: c.WGPUBuffer,
    font: Font,

    const Self = @This();

    pub fn init() !Self {
        const window = c.RGFW_createWindow("Zig WGPU UI", 100, 100, 800, 600, 0);
        if (window == null) return error.WindowCreationFailed;

        var event: c.RGFW_event = undefined;
        while (c.RGFW_window_checkEvent(window, &event) != 0) {}

        const empty_label = c.WGPUStringView{ .data = null, .length = 0 };

        const instance = c.wgpuCreateInstance(null);
        const surface = c.RGFW_window_createSurface_WebGPU(window, instance);
        const adapter = requestAdapter(instance, surface);
        const device = requestDevice(adapter);
        const queue = c.wgpuDeviceGetQueue(device);

        // 1. Bake the Font
        const ttf_file = try std.fs.cwd().readFileAlloc(std.heap.page_allocator, "font.otf", 1024 * 1024 * 10);
        defer std.heap.page_allocator.free(ttf_file);

        var font: Font = undefined;
        var temp_bitmap: [512 * 512]u8 = undefined;
        _ = c.stbtt_BakeFontBitmap(ttf_file.ptr, 0, 32.0, // 32.0 is the pixel height
            &temp_bitmap, 512, 512, 32, 96, &font.cdata);

        // 2. Create WGPU Texture
        const tex_desc = c.WGPUTextureDescriptor{
            .nextInChain = null,
            .label = empty_label,
            .usage = c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_CopyDst,
            .dimension = c.WGPUTextureDimension_2D,
            .size = .{ .width = 512, .height = 512, .depthOrArrayLayers = 1 },
            .format = c.WGPUTextureFormat_R8Unorm, // Single channel alpha!
            .mipLevelCount = 1,
            .sampleCount = 1,
            .viewFormatCount = 0,
            .viewFormats = null,
        };
        font.texture = c.wgpuDeviceCreateTexture(device, &tex_desc);

        // Upload the bitmap bytes
        const image_copy = c.WGPUTexelCopyTextureInfo{
            //.nextInChain = null,
            .texture = font.texture,
            .mipLevel = 0,
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .aspect = c.WGPUTextureAspect_All,
        };
        const layout = c.WGPUTexelCopyBufferLayout{
            //.nextInChain = null,
            .offset = 0,
            .bytesPerRow = 512,
            .rowsPerImage = 512,
        };
        const copy_size = c.WGPUExtent3D{ .width = 512, .height = 512, .depthOrArrayLayers = 1 };
        c.wgpuQueueWriteTexture(queue, &image_copy, &temp_bitmap, temp_bitmap.len, &layout, &copy_size);

        const tex_view = c.wgpuTextureCreateView(font.texture, null);
        defer c.wgpuTextureViewRelease(tex_view);

        // 3. Create Sampler
        const sampler_desc = c.WGPUSamplerDescriptor{
            .nextInChain = null,
            .label = empty_label,
            .addressModeU = c.WGPUAddressMode_ClampToEdge,
            .addressModeV = c.WGPUAddressMode_ClampToEdge,
            .addressModeW = c.WGPUAddressMode_ClampToEdge,
            .magFilter = c.WGPUFilterMode_Linear,
            .minFilter = c.WGPUFilterMode_Linear,
            .mipmapFilter = c.WGPUMipmapFilterMode_Linear,
            .lodMinClamp = 0.0,
            .lodMaxClamp = 32.0,
            .compare = c.WGPUCompareFunction_Undefined,
            .maxAnisotropy = 1,
            // ... leave remaining as 0 / default
        };
        const font_sampler = c.wgpuDeviceCreateSampler(device, &sampler_desc);
        defer c.wgpuSamplerRelease(font_sampler);

        // --- 4. Define the Bind Group Layout (The "Contract") ---
        //var bgl_entries = [_]c.WGPUBindGroupLayoutEntry{std.mem.zeroes(c.WGPUBindGroupLayoutEntry) ** 2};
        // --- 4. Define the Bind Group Layout (The "Contract") ---
        var bgl_entries = [_]c.WGPUBindGroupLayoutEntry{
            std.mem.zeroes(c.WGPUBindGroupLayoutEntry),
            std.mem.zeroes(c.WGPUBindGroupLayoutEntry),
        };

        // Entry 0: The Texture
        bgl_entries[0].binding = 0;
        bgl_entries[0].visibility = c.WGPUShaderStage_Fragment;
        bgl_entries[0].texture.sampleType = c.WGPUTextureSampleType_Float;
        bgl_entries[0].texture.viewDimension = c.WGPUTextureViewDimension_2D;

        // Entry 1: The Sampler
        bgl_entries[1].binding = 1;
        bgl_entries[1].visibility = c.WGPUShaderStage_Fragment;
        bgl_entries[1].sampler.type = c.WGPUSamplerBindingType_Filtering;

        const bgl_desc = c.WGPUBindGroupLayoutDescriptor{
            .nextInChain = null,
            .label = empty_label,
            .entryCount = bgl_entries.len,
            .entries = &bgl_entries,
        };
        const bind_group_layout = c.wgpuDeviceCreateBindGroupLayout(device, &bgl_desc);
        defer c.wgpuBindGroupLayoutRelease(bind_group_layout);

        // --- 5. Create the Actual Bind Group (The Data) ---
        //var bg_entries = [_]c.WGPUBindGroupEntry{std.mem.zeroes(c.WGPUBindGroupEntry) ** 2};
        // --- 5. Create the Actual Bind Group (The Data) ---
        var bg_entries = [_]c.WGPUBindGroupEntry{
            std.mem.zeroes(c.WGPUBindGroupEntry),
            std.mem.zeroes(c.WGPUBindGroupEntry),
        };

        bg_entries[0].binding = 0;
        bg_entries[0].textureView = tex_view;

        bg_entries[1].binding = 1;
        bg_entries[1].sampler = font_sampler;

        const bg_desc = c.WGPUBindGroupDescriptor{
            .nextInChain = null,
            .label = empty_label,
            .layout = bind_group_layout,
            .entryCount = bg_entries.len,
            .entries = &bg_entries,
        };
        font.bind_group = c.wgpuDeviceCreateBindGroup(device, &bg_desc);

        var caps: c.WGPUSurfaceCapabilities = undefined;
        _ = c.wgpuSurfaceGetCapabilities(surface, adapter, &caps);
        const surface_format = if (caps.formatCount > 0) caps.formats[0] else c.WGPUTextureFormat_BGRA8Unorm;

        // --- Setup UI Pipeline ---
        // 1. Shader Module
        //const wgsl_desc = c.WGPUShaderModuleWGSLDescriptor{
        //    .chain = .{ .next = null, .sType = c.WGPUSType_ShaderModuleWGSLDescriptor },
        //    .code = wgsl_shader.ptr,
        //};

        const wgsl_desc = c.WGPUShaderSourceWGSL{
            .chain = .{ .next = null, .sType = c.WGPUSType_ShaderSourceWGSL },
            .code = c.WGPUStringView{
                .data = wgsl_shader.ptr,
                .length = wgsl_shader.len,
            },
        };

        const shader_desc = c.WGPUShaderModuleDescriptor{
            .nextInChain = @ptrCast(&wgsl_desc),
            .label = empty_label,
        };
        const shader = c.wgpuDeviceCreateShaderModule(device, &shader_desc);

        // 2. Vertex Buffers (Unit Quad)
        const quad_verts = [_]f32{ 0.0, 0.0, 1.0, 0.0, 1.0, 1.0, 0.0, 1.0, 0.0, 0.0, 1.0, 1.0 }; // Triangles
        const vbo_desc = c.WGPUBufferDescriptor{
            .nextInChain = null,
            .label = empty_label,
            .usage = c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_CopyDst,
            .size = @sizeOf(@TypeOf(quad_verts)),
            .mappedAtCreation = 0,
        };
        const vbo = c.wgpuDeviceCreateBuffer(device, &vbo_desc);
        c.wgpuQueueWriteBuffer(queue, vbo, 0, &quad_verts, @sizeOf(@TypeOf(quad_verts)));

        // 3. Instance Buffer (Dynamic)
        const ibo_desc = c.WGPUBufferDescriptor{
            .nextInChain = null,
            .label = empty_label,
            .usage = c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_CopyDst,
            .size = @sizeOf(InstanceData) * 1000,
            .mappedAtCreation = 0,
        };
        const ibo = c.wgpuDeviceCreateBuffer(device, &ibo_desc);

        // 4. Pipeline Config (Skipping attribute boilerplate for brevity, map InstanceData appropriately)
        // ... (Imagine full pipeline descriptor here connecting to shader) ...
        // 4. Pipeline Configuration
        //const empty_label = c.WGPUStringView{ .data = null, .length = 0 };
        const vs_entry = c.WGPUStringView{ .data = "vs_main", .length = 7 };
        const fs_entry = c.WGPUStringView{ .data = "fs_main", .length = 7 };

        // Buffer 0: The unit quad vertices
        const vertex_attributes_0 = [_]c.WGPUVertexAttribute{
            .{
                .format = c.WGPUVertexFormat_Float32x2,
                .offset = 0,
                .shaderLocation = 0,
            },
        };

        // Buffer 1: The InstanceData struct mapped to shader locations
        const vertex_attributes_1 = [_]c.WGPUVertexAttribute{
            .{ .format = c.WGPUVertexFormat_Float32x2, .offset = @offsetOf(InstanceData, "rect_pos"), .shaderLocation = 1 },
            .{ .format = c.WGPUVertexFormat_Float32x2, .offset = @offsetOf(InstanceData, "rect_size"), .shaderLocation = 2 },
            .{ .format = c.WGPUVertexFormat_Float32x4, .offset = @offsetOf(InstanceData, "color"), .shaderLocation = 3 },
            .{ .format = c.WGPUVertexFormat_Float32x4, .offset = @offsetOf(InstanceData, "clip_rect"), .shaderLocation = 4 },
            .{ .format = c.WGPUVertexFormat_Float32, .offset = @offsetOf(InstanceData, "corner_radius"), .shaderLocation = 5 },
            .{ .format = c.WGPUVertexFormat_Float32, .offset = @offsetOf(InstanceData, "edge_softness"), .shaderLocation = 6 },
            .{ .format = c.WGPUVertexFormat_Uint32, .offset = @offsetOf(InstanceData, "type_flag"), .shaderLocation = 7 },
            .{ .format = c.WGPUVertexFormat_Float32x2, .offset = @offsetOf(InstanceData, "uv_min"), .shaderLocation = 8 },
            .{ .format = c.WGPUVertexFormat_Float32x2, .offset = @offsetOf(InstanceData, "uv_max"), .shaderLocation = 9 },
        };

        const vertex_buffer_layouts = [_]c.WGPUVertexBufferLayout{
            .{
                .arrayStride = 2 * @sizeOf(f32), // size of vec2 pos
                .stepMode = c.WGPUVertexStepMode_Vertex,
                .attributeCount = vertex_attributes_0.len,
                .attributes = &vertex_attributes_0,
            },
            .{
                .arrayStride = @sizeOf(InstanceData),
                .stepMode = c.WGPUVertexStepMode_Instance,
                .attributeCount = vertex_attributes_1.len,
                .attributes = &vertex_attributes_1,
            },
        };

        // Alpha Blending for rounded corners and text
        const blend_state = c.WGPUBlendState{
            .color = .{
                .operation = c.WGPUBlendOperation_Add,
                .srcFactor = c.WGPUBlendFactor_SrcAlpha,
                .dstFactor = c.WGPUBlendFactor_OneMinusSrcAlpha,
            },
            .alpha = .{
                .operation = c.WGPUBlendOperation_Add,
                .srcFactor = c.WGPUBlendFactor_One,
                .dstFactor = c.WGPUBlendFactor_OneMinusSrcAlpha,
            },
        };

        const color_target = c.WGPUColorTargetState{
            .nextInChain = null,
            .format = surface_format,
            .blend = &blend_state,
            .writeMask = c.WGPUColorWriteMask_All,
        };

        const fragment_state = c.WGPUFragmentState{
            .nextInChain = null,
            .module = shader,
            .entryPoint = fs_entry,
            .constantCount = 0,
            .constants = null,
            .targetCount = 1,
            .targets = &color_target,
        };

        const pipeline_layout_desc = c.WGPUPipelineLayoutDescriptor{
            .nextInChain = null,
            .label = empty_label,
            .bindGroupLayoutCount = 1,
            .bindGroupLayouts = &bind_group_layout,
        };
        const pipeline_layout = c.wgpuDeviceCreatePipelineLayout(device, &pipeline_layout_desc);
        defer c.wgpuPipelineLayoutRelease(pipeline_layout);

        const pipeline_desc = c.WGPURenderPipelineDescriptor{
            .nextInChain = null,
            .label = empty_label,
            .layout = pipeline_layout,
            .vertex = .{
                .nextInChain = null,
                .module = shader,
                .entryPoint = vs_entry,
                .constantCount = 0,
                .constants = null,
                .bufferCount = vertex_buffer_layouts.len,
                .buffers = &vertex_buffer_layouts,
            },
            .primitive = .{
                .nextInChain = null,
                .topology = c.WGPUPrimitiveTopology_TriangleList,
                .stripIndexFormat = c.WGPUIndexFormat_Undefined,
                .frontFace = c.WGPUFrontFace_CCW,
                .cullMode = c.WGPUCullMode_None,
            },
            .depthStencil = null,
            .multisample = .{
                .nextInChain = null,
                .count = 1,
                .mask = 0xFFFFFFFF,
                .alphaToCoverageEnabled = 0,
            },
            .fragment = &fragment_state,
        };

        const pipeline = c.wgpuDeviceCreateRenderPipeline(device, &pipeline_desc);

        return Self{
            .window = window,
            .instance = instance,
            .surface = surface,
            .adapter = adapter,
            .device = device,
            .queue = queue,
            .surface_format = surface_format,
            .clear_color = [3]f32{ 0.1, 0.1, 0.1 },
            .pipeline = pipeline,
            .vbo = vbo,
            .ibo = ibo,
            .font = font,
        };
    }

    pub fn deinit(self: *Self) void {
        // Replace the entire AppState.deinit function with:
        c.wgpuBufferRelease(self.vbo);
        c.wgpuBufferRelease(self.ibo);
        // Note: pipeline is stubbed, so we skip c.wgpuRenderPipelineRelease(self.pipeline)
        c.wgpuRenderPipelineRelease(self.pipeline);

        c.wgpuQueueRelease(self.queue);
        c.wgpuDeviceRelease(self.device);
        c.wgpuAdapterRelease(self.adapter);
        c.wgpuSurfaceRelease(self.surface);
        c.wgpuInstanceRelease(self.instance);
        c.RGFW_window_close(self.window);
    }

    pub fn configureSurface(self: *Self) void {
        const surface_config = c.WGPUSurfaceConfiguration{
            .nextInChain = null,
            .device = self.device,
            .format = self.surface_format,
            .usage = c.WGPUTextureUsage_RenderAttachment,
            .width = 800,
            .height = 600,
            .presentMode = c.WGPUPresentMode_Fifo,
            .alphaMode = c.WGPUCompositeAlphaMode_Auto,
            .viewFormatCount = 0,
            .viewFormats = null,
        };
        c.wgpuSurfaceConfigure(self.surface, &surface_config);
    }

    pub fn renderUI(self: *Self, instances: []const InstanceData) void {
        var surface_texture: c.WGPUSurfaceTexture = undefined;
        c.wgpuSurfaceGetCurrentTexture(self.surface, &surface_texture);
        if (surface_texture.texture == null) return;

        const texture_view = c.wgpuTextureCreateView(surface_texture.texture, null);
        defer {
            c.wgpuTextureViewRelease(texture_view);
            c.wgpuTextureRelease(surface_texture.texture);
        }

        // Update Instance Buffer
        c.wgpuQueueWriteBuffer(self.queue, self.ibo, 0, instances.ptr, instances.len * @sizeOf(InstanceData));

        const encoder = c.wgpuDeviceCreateCommandEncoder(self.device, null);
        defer c.wgpuCommandEncoderRelease(encoder);

        const color_attachment = c.WGPURenderPassColorAttachment{
            .view = texture_view,
            .loadOp = c.WGPULoadOp_Clear,
            .storeOp = c.WGPUStoreOp_Store,
            .clearValue = .{ .r = self.clear_color[0], .g = self.clear_color[1], .b = self.clear_color[2], .a = 1.0 },
            .depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED,
            .resolveTarget = null,
        };
        const render_pass_desc = c.WGPURenderPassDescriptor{
            .colorAttachmentCount = 1,
            .colorAttachments = &color_attachment,
            .depthStencilAttachment = null,
            .occlusionQuerySet = null,
            .timestampWrites = null,
            .label = .{ .data = null, .length = 0 },
        };

        const pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &render_pass_desc);

        c.wgpuRenderPassEncoderSetPipeline(pass, self.pipeline);

        c.wgpuRenderPassEncoderSetBindGroup(pass, 0, self.font.bind_group, 0, null);

        // Bind the two vertex buffers
        c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, self.vbo, 0, c.WGPU_WHOLE_SIZE);
        c.wgpuRenderPassEncoderSetVertexBuffer(pass, 1, self.ibo, 0, c.WGPU_WHOLE_SIZE);

        // Draw 6 vertices (2 triangles for the unit quad) N times
        if (instances.len > 0) {
            c.wgpuRenderPassEncoderDraw(pass, 6, @intCast(instances.len), 0, 0);
        }

        c.wgpuRenderPassEncoderEnd(pass);
        c.wgpuRenderPassEncoderRelease(pass);

        const cmd_buf = c.wgpuCommandEncoderFinish(encoder, null);
        c.wgpuQueueSubmit(self.queue, 1, &cmd_buf);
        _ = c.wgpuSurfacePresent(self.surface);
    }
};

// ... [Include user provided requestAdapter and requestDevice functions here] ... [cite: 37, 41]

// ==========================================
// 4. MAIN LOOP
// ==========================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var app = try AppState.init();
    defer app.deinit();
    app.configureSurface();

    var ui = try UI.init(gpa.allocator());
    defer ui.deinit();

    const dt: f32 = 0.016; // Simulate 60fps for example

    // Create a persistent input state outside the loop
    var current_input = InputState{};
    var running = true;

    while (running and c.RGFW_window_shouldClose(app.window) == 0) {
        // 1. Reset 1-frame input triggers at the start of every frame
        current_input.mouse_left_pressed = false;
        current_input.mouse_left_released = false;

        // 2. Poll RGFW Events
        var event: c.RGFW_event = undefined;
        while (c.RGFW_window_checkEvent(app.window, &event) != 0) {
            switch (event.type) {
                c.RGFW_mousePosChanged => {
                    // Update mouse position (cast from integer to f32)
                    current_input.mouse_x = @floatFromInt(event.mouse.x);
                    current_input.mouse_y = @floatFromInt(event.mouse.y);
                },
                c.RGFW_mouseButtonPressed => {
                    if (event.button.value == c.RGFW_mouseLeft) {
                        current_input.mouse_left_down = true;
                        current_input.mouse_left_pressed = true; // True for exactly 1 frame
                    }
                },
                c.RGFW_mouseButtonReleased => {
                    if (event.button.value == c.RGFW_mouseLeft) {
                        current_input.mouse_left_down = false;
                        current_input.mouse_left_released = true; // True for exactly 1 frame
                    }
                },
                c.RGFW_quit => {
                    //c.RGFW_window_setShouldClose(app.window, 1);
                    running = false;
                },
                c.RGFW_keyPressed => {
                    if (event.key.value == c.RGFW_escape) {
                        //c.RGFW_window_setShouldClose(app.window, 1);
                        running = false;
                    }
                },
                else => {},
            }
        }

        if (!running) break;

        // 3. Build UI Tree
        ui.beginFrame(dt, current_input);

        // --- MAIN CONTAINER ---
        var main_panel = ui.pushBox("Container", BoxFlags{ .draw_background = true, .layout_horizontal = false });
        main_panel.pref_size = .{ .{ .kind = .percent_of_parent, .value = 100.0 }, .{ .kind = .percent_of_parent, .value = 100.0 } };
        main_panel.bg_color = .{ 0.1, 0.1, 0.1, 1.0 };

        ui.label("My Zig GUI Engine");
        // --- BUTTON 1 ---
        if (ui.button("Start")) {
            std.debug.print("Start Button Clicked!\n", .{});
        }

        // --- INVISIBLE SPACER ---
        var spacer = ui.pushBox("Spacer", BoxFlags{});
        spacer.pref_size = .{ .{ .kind = .pixels, .value = 10.0 }, .{ .kind = .pixels, .value = 20.0 } };
        ui.popBox();

        // --- BUTTON 2 ---
        if (ui.button("Settings")) {
            std.debug.print("Settings Button Clicked!\n", .{});
        }

        ui.popBox();

        // 4. Layout & Render Frame
        ui.endFrame(&app);
    }
}

//const std = @import("std");
//
//const c = @cImport({
//    @cDefine("RGFW_WEBGPU", {});
//    @cInclude("RGFW.h");
//    @cInclude("webgpu/webgpu.h");
//});
//
//const AppState = struct {
//    window: ?*c.RGFW_window,
//    instance: c.WGPUInstance,
//    surface: c.WGPUSurface,
//    adapter: c.WGPUAdapter,
//    device: c.WGPUDevice,
//    queue: c.WGPUQueue,
//    surface_format: c.WGPUTextureFormat,
//    clear_color: [3]f32,
//
//    const Self = @This();
//
//    pub fn init() !Self {
//        const window = c.RGFW_createWindow(
//            "title",
//            100,
//            100,
//            800,
//            600,
//            0,
//        );
//        if (window == null) return error.WindowCreationFailed;
//
//        // Process initial events
//        var event: c.RGFW_event = undefined;
//        while (c.RGFW_window_checkEvent(window, &event) != 0) {}
//
//        const instance = c.wgpuCreateInstance(null);
//        if (instance == null) return error.NoInstance;
//
//        const surface = c.RGFW_window_createSurface_WebGPU(window, instance);
//        if (surface == null) return error.NoSurface;
//
//        const adapter = requestAdapter(instance, surface);
//        if (adapter == null) return error.NoAdapter;
//
//        const device = requestDevice(adapter);
//        if (device == null) return error.NoDevice;
//
//        const queue = c.wgpuDeviceGetQueue(device);
//
//        // Get surface format
//        var caps: c.WGPUSurfaceCapabilities = undefined;
//        _ = c.wgpuSurfaceGetCapabilities(surface, adapter, &caps);
//        defer c.wgpuSurfaceCapabilitiesFreeMembers(caps);
//
//        const surface_format = if (caps.formatCount > 0)
//            caps.formats[0]
//        else
//            c.WGPUTextureFormat_BGRA8Unorm;
//
//        return Self{
//            .window = window,
//            .instance = instance,
//            .surface = surface,
//            .adapter = adapter,
//            .device = device,
//            .queue = queue,
//            .surface_format = surface_format,
//            .clear_color = [3]f32{ 1.0, 0.0, 0.0 }, // Start with red
//        };
//    }
//
//    pub fn deinit(self: *Self) void {
//        c.wgpuQueueRelease(self.queue);
//        c.wgpuDeviceRelease(self.device);
//        c.wgpuAdapterRelease(self.adapter);
//        c.wgpuSurfaceRelease(self.surface);
//        c.wgpuInstanceRelease(self.instance);
//        c.RGFW_window_close(self.window);
//    }
//
//    pub fn configureSurface(self: *Self) void {
//        const surface_config = c.WGPUSurfaceConfiguration{
//            .device = self.device,
//            .format = self.surface_format,
//            .usage = c.WGPUTextureUsage_RenderAttachment,
//            .width = 800,
//            .height = 600,
//            .presentMode = c.WGPUPresentMode_Fifo,
//            .alphaMode = c.WGPUCompositeAlphaMode_Auto,
//            .viewFormatCount = 0,
//            .viewFormats = null,
//        };
//        c.wgpuSurfaceConfigure(self.surface, &surface_config);
//    }
//
//    pub fn handleInput(self: *Self) bool {
//        var event: c.RGFW_event = undefined;
//        const step: f32 = 0.05;
//
//        while (c.RGFW_window_checkEvent(self.window, &event) != 0) {
//            if (event.type == c.RGFW_keyPressed) {
//                switch (event.key.value) {
//                    c.RGFW_escape => c.RGFW_window_setShouldClose(self.window, 1),
//                    'q', 'Q' => {
//                        self.clear_color[0] = @min(1.0, self.clear_color[0] + step);
//                        std.debug.print("Red: {d:.2}\n", .{self.clear_color[0]});
//                    },
//                    'a', 'A' => {
//                        self.clear_color[0] = @max(0.0, self.clear_color[0] - step);
//                        std.debug.print("Red: {d:.2}\n", .{self.clear_color[0]});
//                    },
//                    'w', 'W' => {
//                        self.clear_color[1] = @min(1.0, self.clear_color[1] + step);
//                        std.debug.print("Green: {d:.2}\n", .{self.clear_color[1]});
//                    },
//                    's', 'S' => {
//                        self.clear_color[1] = @max(0.0, self.clear_color[1] - step);
//                        std.debug.print("Green: {d:.2}\n", .{self.clear_color[1]});
//                    },
//                    'e', 'E' => {
//                        self.clear_color[2] = @min(1.0, self.clear_color[2] + step);
//                        std.debug.print("Blue: {d:.2}\n", .{self.clear_color[2]});
//                    },
//                    'd', 'D' => {
//                        self.clear_color[2] = @max(0.0, self.clear_color[2] - step);
//                        std.debug.print("Blue: {d:.2}\n", .{self.clear_color[2]});
//                    },
//                    else => {},
//                }
//            }
//        }
//
//        return c.RGFW_window_shouldClose(self.window) == 0;
//    }
//
//    pub fn render(self: *Self) void {
//        var surface_texture: c.WGPUSurfaceTexture = undefined;
//        c.wgpuSurfaceGetCurrentTexture(self.surface, &surface_texture);
//
//        if (surface_texture.texture == null) return;
//
//        const texture_view = c.wgpuTextureCreateView(surface_texture.texture, null);
//        defer {
//            c.wgpuTextureViewRelease(texture_view);
//            c.wgpuTextureRelease(surface_texture.texture);
//        }
//
//        const encoder = c.wgpuDeviceCreateCommandEncoder(self.device, null);
//        defer c.wgpuCommandEncoderRelease(encoder);
//
//        const color_attachment = c.WGPURenderPassColorAttachment{
//            .view = texture_view,
//            .loadOp = c.WGPULoadOp_Clear,
//            .storeOp = c.WGPUStoreOp_Store,
//            .clearValue = .{
//                .r = self.clear_color[0],
//                .g = self.clear_color[1],
//                .b = self.clear_color[2],
//                .a = 1.0,
//            },
//            .depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED,
//            .resolveTarget = null,
//        };
//
//        const empty_label = c.WGPUStringView{
//            .data = null,
//            .length = 0,
//        };
//
//        const render_pass_desc = c.WGPURenderPassDescriptor{
//            .colorAttachmentCount = 1,
//            .colorAttachments = &color_attachment,
//            .depthStencilAttachment = null,
//            .occlusionQuerySet = null,
//            .timestampWrites = null,
//            .label = empty_label,
//        };
//
//        const render_pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &render_pass_desc);
//        c.wgpuRenderPassEncoderEnd(render_pass);
//        c.wgpuRenderPassEncoderRelease(render_pass);
//
//        const command_buffer = c.wgpuCommandEncoderFinish(encoder, null);
//        defer c.wgpuCommandBufferRelease(command_buffer);
//
//        c.wgpuQueueSubmit(self.queue, 1, &command_buffer);
//        _ = c.wgpuSurfacePresent(self.surface);
//    }
//};
//
//pub fn main() !void {
//    var app = try AppState.init();
//    defer app.deinit();
//
//    app.configureSurface();
//
//    std.debug.print("Controls:\n", .{});
//    std.debug.print("  Q/A - Red up/down\n", .{});
//    std.debug.print("  W/S - Green up/down\n", .{});
//    std.debug.print("  E/D - Blue up/down\n", .{});
//
//    while (app.handleInput()) {
//        app.render();
//    }
//}

fn requestAdapter(instance: c.WGPUInstance, surface: c.WGPUSurface) c.WGPUAdapter {
    const options = c.WGPURequestAdapterOptions{
        .compatibleSurface = surface,
        .powerPreference = c.WGPUPowerPreference_HighPerformance,
        .backendType = c.WGPUBackendType_Undefined,
        .forceFallbackAdapter = 0,
        .nextInChain = null,
    };

    var adapter: c.WGPUAdapter = null;
    const callback_info = c.WGPURequestAdapterCallbackInfo{
        .mode = c.WGPUCallbackMode_WaitAnyOnly,
        .callback = requestAdapterCallback,
        .userdata1 = @ptrCast(&adapter),
        .userdata2 = null,
        .nextInChain = null,
    };

    _ = c.wgpuInstanceRequestAdapter(instance, &options, callback_info);
    return adapter;
}

fn requestAdapterCallback(status: c.WGPURequestAdapterStatus, adapter: c.WGPUAdapter, message: c.WGPUStringView, userdata1: ?*anyopaque, userdata2: ?*anyopaque) callconv(.c) void {
    _ = status;
    _ = message;
    _ = userdata2;
    const adapter_ptr: *c.WGPUAdapter = @ptrCast(@alignCast(userdata1));
    adapter_ptr.* = adapter;
}

fn requestDevice(adapter: c.WGPUAdapter) c.WGPUDevice {
    var device: c.WGPUDevice = null;
    const callback_info = c.WGPURequestDeviceCallbackInfo{
        .mode = c.WGPUCallbackMode_WaitAnyOnly,
        .callback = requestDeviceCallback,
        .userdata1 = @ptrCast(&device),
        .userdata2 = null,
        .nextInChain = null,
    };

    _ = c.wgpuAdapterRequestDevice(adapter, null, callback_info);
    return device;
}

fn requestDeviceCallback(status: c.WGPURequestDeviceStatus, device: c.WGPUDevice, message: c.WGPUStringView, userdata1: ?*anyopaque, userdata2: ?*anyopaque) callconv(.c) void {
    _ = status;
    _ = message;
    _ = userdata2;
    const device_ptr: *c.WGPUDevice = @ptrCast(@alignCast(userdata1));
    device_ptr.* = device;
}
