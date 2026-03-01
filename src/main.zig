const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cDefine("RGFW_WEBGPU", {});
    @cInclude("RGFW.h");
    @cInclude("webgpu/webgpu.h");
    @cInclude("stb_image.h");
    @cInclude("tinyobj_loader_c.h");
});

// ==========================================
// 1. UI DATA STRUCTURES & ARCHITECTURE
// ==========================================

var counter: i32 = 0;
var vsync_enabled: bool = true;
var show_debug: bool = false;
var graphics_quality: usize = 1; // 0=Low, 1=Medium, 2=High
var master_volume: f32 = 0.5;
var my_text_buf: [256]u8 = undefined;
var my_text_len: usize = 0;
var my_dropdown_index: usize = 0;
const dropdown_options = [_][]const u8{ "Low", "Medium", "High", "Ultra" };
var my_image: Texture = undefined;
var image_loaded: bool = false;
var my_graph_data: [50]f32 = undefined;
var my_camera_yaw: f32 = 0.785; // 45 degrees
var my_camera_pitch: f32 = 0.523; // 30 degrees
var my_camera_zoom: f32 = 5.0;
var is_3d_ready: bool = false;
var my_light_x: f32 = 0.5;
var my_ambient: f32 = 0.2;
var my_wobble: f32 = 0.0;
var total_time: f32 = 0.0;
var available_models: std.ArrayList([:0]const u8) = undefined;
var my_ui_tint = [4]f32{ 1.0, 0.25, 0.25, 1.0 };
var frame_count: u32 = 0;
var fps_timer: f32 = 0.0;
var current_fps: f32 = 0.0;

const BMFontChar = struct {
    id: u32,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    xoffset: f32,
    yoffset: f32,
    xadvance: f32,
};

const BMFontCommon = struct {
    lineHeight: f32,
    base: f32,
    scaleW: f32,
    scaleH: f32,
};

const BMFont = struct {
    common: BMFontCommon,
    chars: []BMFontChar,
};

const MSDFBounds = struct { left: f32, bottom: f32, right: f32, top: f32 };

const MSDFGlyph = struct {
    unicode: u32,
    advance: f32,
    planeBounds: ?MSDFBounds = null,
    atlasBounds: ?MSDFBounds = null,
};

const MSDFMetrics = struct {
    emSize: f32,
    lineHeight: f32,
    ascender: f32,
    descender: f32,
};

const MSDFFont = struct {
    metrics: MSDFMetrics,
    glyphs: []MSDFGlyph,
};

pub const Rect = struct {
    pos: [2]f32 = .{ 0.0, 0.0 },
    size: [2]f32 = .{ 0.0, 0.0 },
};

pub const Vertex3D = extern struct {
    position: [3]f32,
    normal: [3]f32,
    uv: [2]f32,
    color: [3]f32,
};

pub const ModelData = struct {
    vertices: []Vertex3D,
    texture_path: ?[]u8, // We use an optional slice since models might not have textures!
};

// 96 bytes total, perfectly aligned for WebGPU!
pub const UniformData = extern struct {
    mvp: [16]f32, // 64 bytes
    light_dir: [3]f32, // 12 bytes
    ambient: f32, // 4 bytes
    wobble_intensity: f32, // 4 bytes
    time: f32, // 4 bytes
    padding: [2]f32, // 8 bytes (forces 16-byte alignment)
};

pub const Math3D = struct {
    // Strictly Column-Major Multiplication
    pub fn mul(a: [16]f32, b: [16]f32) [16]f32 {
        var out = std.mem.zeroes([16]f32);
        for (0..4) |col| {
            for (0..4) |row| {
                for (0..4) |i| {
                    out[col * 4 + row] += a[i * 4 + row] * b[col * 4 + i];
                }
            }
        }
        return out;
    }

    // WebGPU specific perspective (Z maps to 0.0 to 1.0)
    pub fn perspective(fovy_rad: f32, aspect: f32, near: f32, far: f32) [16]f32 {
        const f = 1.0 / @tan(fovy_rad / 2.0);
        var out = std.mem.zeroes([16]f32);
        out[0] = f / aspect;
        out[5] = f;
        out[10] = far / (near - far);
        out[11] = -1.0;
        out[14] = (far * near) / (near - far);
        return out;
    }

    // (lookAt remains exactly the same, it was already column-major!)
    pub fn lookAt(eye: [3]f32, center: [3]f32, up: [3]f32) [16]f32 {
        var f = [3]f32{ center[0] - eye[0], center[1] - eye[1], center[2] - eye[2] };
        const f_len = @sqrt(f[0] * f[0] + f[1] * f[1] + f[2] * f[2]);
        f = .{ f[0] / f_len, f[1] / f_len, f[2] / f_len };

        var s = [3]f32{ f[1] * up[2] - f[2] * up[1], f[2] * up[0] - f[0] * up[2], f[0] * up[1] - f[1] * up[0] };
        const s_len = @sqrt(s[0] * s[0] + s[1] * s[1] + s[2] * s[2]);
        s = .{ s[0] / s_len, s[1] / s_len, s[2] / s_len };

        const u = [3]f32{ s[1] * f[2] - s[2] * f[1], s[2] * f[0] - s[0] * f[2], s[0] * f[1] - s[1] * f[0] };

        return [16]f32{
            s[0],                                             u[0],                                             -f[0],                                         0.0,
            s[1],                                             u[1],                                             -f[1],                                         0.0,
            s[2],                                             u[2],                                             -f[2],                                         0.0,
            -(s[0] * eye[0] + s[1] * eye[1] + s[2] * eye[2]), -(u[0] * eye[0] + u[1] * eye[1] + u[2] * eye[2]), f[0] * eye[0] + f[1] * eye[1] + f[2] * eye[2], 1.0,
        };
    }
};

pub const SizeKind = enum { pixels, percent_of_parent, text_content, children_sum };

pub const SizeConstraint = struct {
    kind: SizeKind = .pixels,
    value: f32 = 0.0,
};

pub const BoxFlags = packed struct {
    clickable: bool = false,
    draw_background: bool = false,
    layout_horizontal: bool = false,
    clip_children: bool = false,
    floating: bool = false,
    scrollable_y: bool = false,
    is_popup: bool = false,
    _padding: u10 = 0,
};

pub const TextAlign = enum { left, center, right };

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

    rect: Rect = .{},
    clip_rect: [4]f32 = .{ 0.0, 0.0, 10000.0, 10000.0 }, // minX, minY, maxX, maxY

    bg_color: [4]f32 = .{ 0.2, 0.2, 0.2, 1.0 },
    corner_radius: f32 = 0.0,

    // Filled during Build Phase based on Retained State
    hot_t: f32 = 0.0,
    active_t: f32 = 0.0,
    text: []const u8 = "",
    text_align: TextAlign = .left,
    pref_size: [2]SizeConstraint = .{ .{}, .{} },
    calculated_size: [2]f32 = .{ 0.0, 0.0 },
    padding: f32 = 0.0,
    gap: f32 = 0.0,
    is_focused: bool = false,
    text_cursor_index: usize = 0,
    fixed_x: f32 = 0.0,
    fixed_y: f32 = 0.0,
    texture: ?Texture = null,

    graph_data: ?[]const f32 = null,
    graph_min: f32 = 0.0,
    graph_max: f32 = 1.0,

    submit_index: u32 = 0,
};

pub const BoxState = struct {
    last_frame_rect: Rect = .{},
    last_frame_clip: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 },
    last_frame_z_index: u32 = 0,
    last_frame_touched: u64 = 0,
    last_frame_submit_index: u32 = 0,

    clickable: bool = false,
    scrollable_y: bool = false,

    // Animation states
    hot_t: f32 = 0.0,
    active_t: f32 = 0.0,

    drag_offset_x: f32 = 0.0,
    drag_offset_y: f32 = 0.0,
    window_x: f32 = 0.0,
    window_y: f32 = 0.0,
    window_width: f32 = 0.0,
    window_height: f32 = 0.0,

    root_window_hash: u64 = 0,
    persistent_z: u32 = 0,
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

pub const DrawCmd = struct {
    bind_group: c.WGPUBindGroup,
    instance_offset: u32,
    instance_count: u32,
};

pub const Texture = struct {
    wgpu_tex: c.WGPUTexture,
    bind_group: c.WGPUBindGroup,
    width: u32,
    height: u32,
};

pub const InputState = struct {
    mouse_x: f32 = 0.0,
    mouse_y: f32 = 0.0,
    mouse_left_down: bool = false,
    mouse_left_pressed: bool = false,
    mouse_left_released: bool = false,

    scroll_y: f32 = 0.0,

    typed_char: u8 = 0,
    backspace_pressed: bool = false,
    shift_pressed: bool = false,
    caps_lock_active: bool = false,
    left_arrow_pressed: bool = false,
    right_arrow_pressed: bool = false,
};

pub const Font = struct {
    texture: c.WGPUTexture,
    view: c.WGPUTextureView,
    sampler: c.WGPUSampler,
    bind_group: c.WGPUBindGroup,
};

pub const ButtonTheme = struct {
    base: [4]f32 = .{ 0.2, 0.2, 0.2, 1.0 },
    hover: [4]f32 = .{ 1.0, 0.0, 0.0, 1.0 },
    active: [4]f32 = .{ 0.0, 0.0, 1.0, 1.0 },
};

const AppContext = struct {
    app: *AppState,
    ui: *UI,
    input: *InputState,
    window_width: *u32,
    window_height: *u32,
};

// ==========================================
// 2. THE UI ENGINE
// ==========================================

pub const UI = struct {
    allocator: std.mem.Allocator,
    frame_arena: std.heap.ArenaAllocator,
    retained_state: std.AutoHashMap(u64, BoxState),

    font_map: std.AutoHashMap(u32, BMFontChar) = undefined,
    font_metrics: BMFontCommon = undefined,

    root: ?*Box = null,
    parent_stack: [64]*Box = undefined,
    parent_stack_top: usize = 0,
    submit_counter: u32 = 0,

    input: InputState = .{},
    current_frame_index: u64 = 0,

    hot_hash_this_frame: u64 = 0,
    active_hash: u64 = 0,

    hovered_scroll_hash: u64 = 0,

    layout_cache: std.AutoHashMap(u64, [4]f32),
    scroll_state: std.AutoHashMap(u64, [2]f32),

    focused_hash: u64 = 0,
    focused_cursor_index: usize = 0,

    opened_dropdown_hash: u64 = 0,
    deferred_popups: std.ArrayList(*Box),

    window_width: f32 = 0.0,
    window_height: f32 = 0.0,

    current_window_hash: u64 = 0,
    top_window_z: u32 = 10,

    pub fn init(allocator: std.mem.Allocator) !UI {
        return UI{
            .allocator = allocator,
            .frame_arena = std.heap.ArenaAllocator.init(allocator),
            .retained_state = std.AutoHashMap(u64, BoxState).init(allocator),
            .layout_cache = std.AutoHashMap(u64, [4]f32).init(allocator),
            .scroll_state = std.AutoHashMap(u64, [2]f32).init(allocator),
            .deferred_popups = std.ArrayList(*Box){},
        };
    }

    pub fn deinit(self: *UI) void {
        self.retained_state.deinit();
        self.frame_arena.deinit();
        self.layout_cache.deinit();
        self.scroll_state.deinit();
        self.deferred_popups.deinit(self.allocator);
        self.font_map.deinit();
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
        self.deferred_popups.clearRetainingCapacity();
        _ = self.frame_arena.reset(.retain_capacity);
        self.input = input;
        self.current_frame_index += 1;
        self.parent_stack_top = 0;
        self.submit_counter = 0;
        self.root = null;

        if (!input.mouse_left_down and !input.mouse_left_released) {
            self.active_hash = 0;
        }

        // 1. Z-Sorted Input Resolution
        self.hot_hash_this_frame = 0;
        self.hovered_scroll_hash = 0;

        var highest_z: u32 = 0;
        var highest_submit: u32 = 0;

        var highest_scroll_z: u32 = 0;
        var highest_scroll_submit: u32 = 0;

        var it = self.retained_state.iterator();
        while (it.next()) |entry| {
            const state = entry.value_ptr;
            if (state.last_frame_touched != self.current_frame_index - 1) continue;

            const rx = state.last_frame_rect;
            const cx = state.last_frame_clip;

            const in_rect = input.mouse_x >= rx.pos[0] and input.mouse_x <= rx.pos[0] + rx.size[0] and
                input.mouse_y >= rx.pos[1] and input.mouse_y <= rx.pos[1] + rx.size[1];

            const in_clip = input.mouse_x >= cx[0] and input.mouse_y >= cx[1] and
                input.mouse_x <= cx[2] and input.mouse_y <= cx[3];

            if (in_rect and in_clip) {

                // 1. Resolve Click Priority
                if (state.clickable) {
                    // Tie-breaker: If Z-Indexes are equal, the higher submit index wins!
                    if (self.hot_hash_this_frame == 0 or
                        state.last_frame_z_index > highest_z or
                        (state.last_frame_z_index == highest_z and state.last_frame_submit_index > highest_submit))
                    {
                        self.hot_hash_this_frame = entry.key_ptr.*;
                        highest_z = state.last_frame_z_index;
                        highest_submit = state.last_frame_submit_index;
                    }
                }

                // 2. Resolve Scroll Priority
                if (state.scrollable_y) {
                    if (self.hovered_scroll_hash == 0 or
                        state.last_frame_z_index > highest_scroll_z or
                        (state.last_frame_z_index == highest_scroll_z and state.last_frame_submit_index > highest_scroll_submit))
                    {
                        self.hovered_scroll_hash = entry.key_ptr.*;
                        highest_scroll_z = state.last_frame_z_index;
                        highest_scroll_submit = state.last_frame_submit_index;
                    }
                }
            }
        }

        // --- BUBBLE-UP Z-INDEX BUMP ---
        if (self.input.mouse_left_pressed and self.hot_hash_this_frame != 0) {
            if (self.retained_state.get(self.hot_hash_this_frame)) |hot_state| {
                if (hot_state.root_window_hash != 0) {
                    if (self.retained_state.getPtr(hot_state.root_window_hash)) |win_state| {
                        // Only bump if it isn't ALREADY the top window!
                        if (win_state.persistent_z < self.top_window_z) {
                            self.top_window_z += 10;
                            win_state.persistent_z = self.top_window_z;
                        }
                    }
                }
            }
        }
        // ------------------------------

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
            box.z_index = parent.z_index;
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

        box.submit_index = self.submit_counter;

        // Sync State
        var state_entry = self.retained_state.getOrPut(hash) catch unreachable;
        if (!state_entry.found_existing) {
            state_entry.value_ptr.* = BoxState{};
        }
        state_entry.value_ptr.last_frame_touched = self.current_frame_index;
        state_entry.value_ptr.clickable = flags.clickable;
        state_entry.value_ptr.scrollable_y = flags.scrollable_y;

        state_entry.value_ptr.last_frame_submit_index = self.submit_counter;
        self.submit_counter += 1;

        box.hot_t = state_entry.value_ptr.hot_t;
        box.active_t = state_entry.value_ptr.active_t;

        state_entry.value_ptr.root_window_hash = self.current_window_hash;

        // Interaction
        if (flags.clickable) {
            if (self.hot_hash_this_frame == hash) {
                if (self.input.mouse_left_pressed) {
                    self.active_hash = hash;
                }
            }
        }
        return box;
    }

    pub fn popBox(self: *UI) void {
        const node = self.parent_stack[self.parent_stack_top - 1];

        // --- INJECT VISUAL SCROLLBAR ---
        if (node.flags.scrollable_y) {
            if (self.layout_cache.get(node.hash)) |rect| {
                if (self.scroll_state.get(node.hash)) |state| {
                    var scroll_offset = state[0];
                    const content_height = state[1];
                    const visible_height = rect[3];

                    // If content overflows the container, we draw a scrollbar!
                    if (content_height > visible_height and visible_height > 0.0) {
                        var thumb = self.pushBox("_scrollbar_thumb_", BoxFlags{
                            .is_popup = true,
                            .floating = true, // Force absolute coordinates
                            .clickable = true,
                            .draw_background = true,
                        });

                        // 1. Calculate Thumb Size
                        const thumb_w: f32 = 8.0;
                        const min_thumb_h: f32 = 20.0;
                        const thumb_h = @max(min_thumb_h, visible_height * (visible_height / content_height));

                        // 2. Calculate Thumb Position
                        const max_scroll = content_height - visible_height;
                        const scroll_pct = scroll_offset / max_scroll;
                        const track_h = @max(0.0, visible_height - thumb_h);

                        thumb.fixed_x = rect[0] + rect[2] - thumb_w - 4.0;
                        thumb.fixed_y = rect[1] + (scroll_pct * track_h);

                        thumb.pref_size = .{ .{ .kind = .pixels, .value = thumb_w }, .{ .kind = .pixels, .value = thumb_h } };
                        thumb.corner_radius = 4.0;
                        thumb.z_index += 5; // Float over the content

                        // 3. Handle Drag Interaction
                        if (self.active_hash == thumb.hash) {
                            thumb.bg_color = .{ 0.4, 0.4, 0.4, 1.0 };

                            if (self.retained_state.getPtr(thumb.hash)) |thumb_state| {
                                // Cache exact pixel offset on initial click!
                                if (self.input.mouse_left_pressed) {
                                    thumb_state.drag_offset_y = self.input.mouse_y - thumb.fixed_y;
                                }

                                // Drag Math
                                const target_y = self.input.mouse_y - thumb_state.drag_offset_y;
                                const mouse_local_y = target_y - rect[1];

                                var new_pct: f32 = 0.0;
                                if (track_h > 0.0) new_pct = mouse_local_y / track_h;
                                new_pct = @max(0.0, @min(1.0, new_pct)); // Clamp to bounds

                                scroll_offset = new_pct * max_scroll;
                                // Save state immediately so layout phase sees it!
                                self.scroll_state.put(node.hash, .{ scroll_offset, content_height }) catch {};
                            }
                        } else if (self.hot_hash_this_frame == thumb.hash) {
                            thumb.bg_color = .{ 0.5, 0.5, 0.5, 0.8 }; // Hover
                        } else {
                            thumb.bg_color = .{ 0.3, 0.3, 0.3, 0.5 }; // Idle
                        }

                        self.popBox(); // Close the thumb
                    }
                }
            }
        }
        self.parent_stack_top -= 1;
    }

    // --- Layout Algorithms ---
    pub fn endFrame(self: *UI, app: *AppState, window_width: f32, window_height: f32) void {
        if (self.root) |root| {
            // Force the root container to exactly match the OS window
            root.pref_size = .{ .{ .kind = .pixels, .value = window_width }, .{ .kind = .pixels, .value = window_height } };
            root.rect.pos = .{ 0.0, 0.0 };
            root.clip_rect = .{ 0.0, 0.0, window_width, window_height };

            // Execute the Solver
            self.computeSizes(root);
            self.computeLayout(root);

            // Extract the draw commands based on the solved boxes
            var instances = std.ArrayList(InstanceData){};
            defer instances.deinit(self.allocator);

            var draw_cmds = std.ArrayList(DrawCmd){};
            defer draw_cmds.deinit(self.allocator);

            var current_bg = app.font.bind_group;
            draw_cmds.append(self.allocator, .{
                .bind_group = current_bg,
                .instance_offset = 0,
                .instance_count = 0,
            }) catch unreachable;

            self.buildRenderCommands(root, &instances, &draw_cmds, &current_bg, &app.font);

            // --- SORT POPUPS BY Z-INDEX ---
            const SortCtx = struct {
                fn lessThan(context: void, a: *Box, b: *Box) bool {
                    _ = context;
                    // If Z-indexes match, fall back to submission order for perfect stability!
                    if (a.z_index == b.z_index) return a.submit_index < b.submit_index;
                    return a.z_index < b.z_index;
                }
            };
            std.mem.sort(*Box, self.deferred_popups.items, {}, SortCtx.lessThan);

            // 2. NEW: Render popups perfectly over the top of everything else!
            // We use a dynamic while loop so that popups spawned INSIDE of popups
            // (like resize handles) are appended to the queue and drawn!
            var p_i: usize = 0;
            while (p_i < self.deferred_popups.items.len) : (p_i += 1) {
                const popup = self.deferred_popups.items[p_i];

                popup.flags.is_popup = false;
                self.buildRenderCommands(popup, &instances, &draw_cmds, &current_bg, &app.font);
                popup.flags.is_popup = true;
            }

            var final_cmd = &draw_cmds.items[draw_cmds.items.len - 1];
            final_cmd.instance_count = @intCast(instances.items.len - final_cmd.instance_offset);
            app.renderUI(instances.items, draw_cmds.items);
        }
    }

    pub fn beginWindow(self: *UI, title: []const u8, start_x: f32, start_y: f32, start_w: f32, start_h: f32) void {
        const hash = self.generateId(title);

        // 1. Fetch or Initialize Persistent State
        var state_entry = self.retained_state.getOrPut(hash) catch unreachable;
        if (!state_entry.found_existing) {
            state_entry.value_ptr.* = BoxState{};
            state_entry.value_ptr.window_x = start_x;
            state_entry.value_ptr.window_y = start_y;
            state_entry.value_ptr.window_width = start_w; // Initialize width!
            state_entry.value_ptr.window_height = start_h; // Initialize height!
            self.top_window_z += 10;
            state_entry.value_ptr.persistent_z = self.top_window_z;
        }

        self.current_window_hash = hash;
        var state = state_entry.value_ptr;

        // 2. The Floating Master Container
        var win = self.pushBox(title, BoxFlags{ .is_popup = true, .floating = true, .clickable = true, .draw_background = true, .layout_horizontal = false });
        win.z_index = state.persistent_z;

        win.fixed_x = state.window_x;
        win.fixed_y = state.window_y;

        // Use the persistent width and height!
        win.pref_size = .{ .{ .kind = .pixels, .value = state.window_width }, .{ .kind = .pixels, .value = state.window_height } };
        win.bg_color = .{ 0.1, 0.1, 0.12, 1.0 };
        win.corner_radius = 8.0;
        win.padding = 2.0;

        // 3. The Draggable Title Bar
        var title_bar = self.pushBox("title_bar", BoxFlags{ .clickable = true, .draw_background = true });
        title_bar.pref_size = .{ .{ .kind = .percent_of_parent, .value = 100.0 }, .{ .kind = .pixels, .value = 28.0 } };
        title_bar.bg_color = .{ 0.15, 0.25, 0.45, 1.0 };
        title_bar.corner_radius = 6.0;

        self.label(title);

        // --- TITLE BAR DRAG MATH ---
        if (self.active_hash == title_bar.hash) {
            title_bar.bg_color = .{ 0.2, 0.3, 0.5, 1.0 };

            if (self.input.mouse_left_pressed) {
                state.drag_offset_x = self.input.mouse_x - state.window_x;
                state.drag_offset_y = self.input.mouse_y - state.window_y;
            }

            state.window_x = self.input.mouse_x - state.drag_offset_x;
            state.window_y = self.input.mouse_y - state.drag_offset_y;

            const snap_dist: f32 = 30.0;
            if (state.window_x < snap_dist) state.window_x = 0.0;
            if (state.window_x + state.window_width > self.window_width - snap_dist) state.window_x = self.window_width - state.window_width;
            if (state.window_y < snap_dist) state.window_y = 0.0;
            if (state.window_y + state.window_height > self.window_height - snap_dist) state.window_y = self.window_height - state.window_height;
        }
        self.popBox(); // Close Title Bar

        // 5. The Content Area
        var content = self.pushBox("content", BoxFlags{ .scrollable_y = true });
        content.pref_size = .{ .{ .kind = .percent_of_parent, .value = 100.0 }, .{ .kind = .percent_of_parent, .value = 100.0 } };
        content.padding = 10.0;
        content.gap = 10.0;
    }

    pub fn endWindow(self: *UI) void {
        self.popBox(); // Close Content Area
        // --- THE RESIZE HANDLE FIX ---
        // Fetch the state using the context hash we saved in beginWindow!
        if (self.retained_state.getPtr(self.current_window_hash)) |state| {
            var resize_handle = self.pushBox("resize_handle", BoxFlags{
                .floating = true, // Break layout!
                // Notice: NO .is_popup = true! This binds it to the window's Z-layer!
                .clickable = true,
                .draw_background = true,
            });

            const handle_size = 15.0;
            resize_handle.fixed_x = state.window_x + state.window_width - handle_size;
            resize_handle.fixed_y = state.window_y + state.window_height - handle_size;
            resize_handle.pref_size = .{ .{ .kind = .pixels, .value = handle_size }, .{ .kind = .pixels, .value = handle_size } };
            resize_handle.corner_radius = 4.0;
            resize_handle.z_index = state.persistent_z + 5;

            if (self.active_hash == resize_handle.hash) {
                resize_handle.bg_color = .{ 0.5, 0.5, 0.5, 1.0 };

                if (self.input.mouse_left_pressed) {
                    state.drag_offset_x = self.input.mouse_x - state.window_width;
                    state.drag_offset_y = self.input.mouse_y - state.window_height;
                }

                state.window_width = self.input.mouse_x - state.drag_offset_x;
                state.window_height = self.input.mouse_y - state.drag_offset_y;

                state.window_width = @max(50.0, state.window_width);
                state.window_height = @max(50.0, state.window_height);
            } else if (self.hot_hash_this_frame == resize_handle.hash) {
                resize_handle.bg_color = .{ 0.4, 0.4, 0.4, 0.8 };
            } else {
                resize_handle.bg_color = .{ 0.2, 0.2, 0.2, 0.5 };
            }
            self.popBox(); // Close Resize Handle
        }
        // -----------------------------
        self.popBox(); // Close Master Container
        self.current_window_hash = 0;
    }

    fn computeSizes(self: *UI, node: *Box) void {
        // 1. Recurse deepest children FIRST (Bottom-Up)
        var child_it = node.first;
        while (child_it) |child| : (child_it = child.next) {
            self.computeSizes(child);
        }

        // 2. Compute our own requested size
        for (0..2) |axis| {
            switch (node.pref_size[axis].kind) {
                .pixels => node.calculated_size[axis] = node.pref_size[axis].value,

                .text_content => {
                    // A fast estimation. For pixel-perfect boxes, you would run
                    // STB quad logic here to get the exact bounding box.
                    if (axis == 0) node.calculated_size[0] = @as(f32, @floatFromInt(node.text.len)) * 16.0;
                    if (axis == 1) node.calculated_size[1] = 32.0;
                },

                .children_sum => {
                    var sum: f32 = 0;
                    var max: f32 = 0;
                    var count: f32 = 0;

                    var it = node.first;
                    const is_row = node.flags.layout_horizontal;
                    const main_axis: usize = if (is_row) 0 else 1;

                    while (it) |b| : (it = b.next) {
                        if (axis == main_axis) {
                            sum += b.calculated_size[axis];
                        } else {
                            max = @max(max, b.calculated_size[axis]);
                        }
                        count += 1.0;
                    }

                    // Add gaps between elements and padding around the container
                    if (axis == main_axis) {
                        if (count > 1.0) sum += (count - 1.0) * node.gap;
                        sum += node.padding * 2.0;
                        node.calculated_size[axis] = sum;
                    } else {
                        max += node.padding * 2.0;
                        node.calculated_size[axis] = max;
                    }
                },

                .percent_of_parent => {
                    // We cannot solve percentages until the parent's size is locked.
                    // Leave it at 0; it will be solved in Pass 2.
                    node.calculated_size[axis] = 0;
                },
            }
        }
    }

    fn computeLayout(self: *UI, node: *Box) void {
        // 1. Lock in the final size
        node.rect.size = node.calculated_size;

        self.layout_cache.put(node.hash, .{ node.rect.pos[0], node.rect.pos[1], node.rect.size[0], node.rect.size[1] }) catch {};

        // --- 2. HANDLE SCROLL STATE ---
        var scroll_offset: f32 = 0.0;
        var prev_content_height: f32 = 0.0; // Track the height from last frame

        if (node.flags.scrollable_y) {
            // Read both the offset and the previous height from the cache
            if (self.scroll_state.get(node.hash)) |state| {
                scroll_offset = state[0];
                prev_content_height = state[1];
            }

            // Read input
            if (self.hovered_scroll_hash == node.hash) {
                scroll_offset -= self.input.scroll_y * 20.0;
            }

            // CLAMP IMMEDIATELY! (Using last frame's content height)
            const max_scroll = @max(0.0, prev_content_height - (node.rect.size[1] - (node.padding * 2.0)));
            scroll_offset = @max(0.0, @min(max_scroll, scroll_offset));
        }

        // --- 3. APPLY THE OFFSET ---
        var cursor_x = node.rect.pos[0] + node.padding;
        var cursor_y = node.rect.pos[1] + node.padding - scroll_offset;

        var max_child_y = cursor_y;

        var child_it = node.first;
        while (child_it) |child| : (child_it = child.next) {
            if (child.flags.is_popup or child.flags.floating) {
                if (child.flags.floating) {
                    // Scrollbars: Pin to absolute screen coordinates!
                    child.rect.pos = .{ child.fixed_x, child.fixed_y };
                } else {
                    // Dropdowns: Drop inline with the layout cursor
                    child.rect.pos = .{ cursor_x, cursor_y };
                }

                // Copy literal pixel sizes over immediately
                if (child.pref_size[0].kind == .pixels) child.calculated_size[0] = child.pref_size[0].value;
                if (child.pref_size[1].kind == .pixels) child.calculated_size[1] = child.pref_size[1].value;

                child.clip_rect = .{ 0.0, 0.0, 10000.0, 10000.0 };

                // Recursively calculate the popup's children, then SKIP the flex math!
                self.computeLayout(child);

                // Only let inline dropdowns expand the scroll boundaries!
                if (!child.flags.floating) {
                    const bottom_edge = child.rect.pos[1] + child.rect.size[1];
                    if (bottom_edge > max_child_y) {
                        max_child_y = bottom_edge;
                    }
                }
                continue;
            }

            // 2. Resolve percentages now that we know our own size
            for (0..2) |axis| {
                if (child.pref_size[axis].kind == .percent_of_parent) {
                    var available = node.calculated_size[axis] - (node.padding * 2.0);

                    // Shrink available space based on siblings that already rendered!
                    if (node.flags.layout_horizontal and axis == 0) {
                        available = (node.rect.pos[0] + node.calculated_size[0] - node.padding) - cursor_x;
                    } else if (!node.flags.layout_horizontal and axis == 1) {
                        available = (node.rect.pos[1] + node.calculated_size[1] - node.padding) - cursor_y;
                    }

                    available = @max(0.0, available); // Prevent negative sizes

                    child.calculated_size[axis] = available * (child.pref_size[axis].value / 100.0);
                }
            }

            // 3. Position the child
            child.rect.pos = .{ cursor_x, cursor_y };

            // 4. Inherit clip rects (prevents children from drawing outside their parents)
            child.clip_rect = .{
                @max(node.clip_rect[0], child.rect.pos[0]),
                @max(node.clip_rect[1], child.rect.pos[1]),
                @min(node.clip_rect[2], child.rect.pos[0] + child.calculated_size[0]),
                @min(node.clip_rect[3], child.rect.pos[1] + child.calculated_size[1]),
            };

            // 5. Advance the cursor for the next sibling
            if (node.flags.layout_horizontal) {
                cursor_x += child.calculated_size[0] + node.gap;
            } else {
                cursor_y += child.calculated_size[1] + node.gap;
            }

            // 6. Recurse down the tree
            self.computeLayout(child);

            const flex_bottom = child.rect.pos[1] + child.calculated_size[1];
            if (flex_bottom > max_child_y) {
                max_child_y = flex_bottom;
            }
        }

        // --- 3. CLAMP AND SAVE SCROLL ---
        if (node.flags.scrollable_y) {
            // Calculate actual content height based on where the cursor ended up
            const content_height = (max_child_y + scroll_offset) - (node.rect.pos[1] + node.padding);

            // Save both the offset and the new height to the map
            self.scroll_state.put(node.hash, .{ scroll_offset, content_height }) catch {};
        }
    }

    fn buildRenderCommands(self: *UI, node: *Box, instances: *std.ArrayList(InstanceData), draw_cmds: *std.ArrayList(DrawCmd), current_bg: *c.WGPUBindGroup, font: *Font) void {
        const target_bg = if (node.texture) |tex| tex.bind_group else font.bind_group;

        if (current_bg.* != target_bg) {
            // 1. Lock in the exact count for the PREVIOUS batch
            var last_cmd = &draw_cmds.items[draw_cmds.items.len - 1];
            last_cmd.instance_count = @intCast(instances.items.len - last_cmd.instance_offset);

            // 2. Start the NEW batch
            draw_cmds.append(self.allocator, DrawCmd{
                .bind_group = target_bg,
                .instance_offset = @intCast(instances.items.len),
                .instance_count = 0,
            }) catch unreachable;

            current_bg.* = target_bg;
        }

        // --- DEFER POPUPS TO THE END ---
        if (node.flags.is_popup) {
            self.deferred_popups.append(self.allocator, node) catch {};
            return; // Stop processing this branch! It will be drawn later.
        }

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
            //draw_cmds.items[draw_cmds.items.len - 1].instance_count += 1; // <-- ADD THIS AFTER EVERY APPEND!
        }

        // --- TEXTURE BATCH BREAKING ---
        if (node.texture != null) {
            instances.append(self.allocator, InstanceData{
                .rect_pos = node.rect.pos,
                .rect_size = node.rect.size,
                .color = .{ 1.0, 1.0, 1.0, 1.0 },
                .clip_rect = node.clip_rect,
                .corner_radius = node.corner_radius,
                .edge_softness = 0.0,
                .type_flag = 2, // 2 = Image Texture!
                .uv_min = .{ 0.0, 0.0 },
                .uv_max = .{ 1.0, 1.0 },
            }) catch unreachable;
        }

        // --- DRAW LINE GRAPH SEGMENTS ---
        if (node.graph_data) |data| {
            if (data.len > 1) {
                const pad: f32 = 4.0; // Extra quad padding so lines don't clip at the edges
                const width = node.rect.size[0];
                const height = node.rect.size[1];
                const range = @max(0.001, node.graph_max - node.graph_min);
                const x_step = width / @as(f32, @floatFromInt(data.len - 1));

                for (0..data.len - 1) |i| {
                    const v1 = data[i];
                    const v2 = data[i + 1];

                    // Normalize height from 0.0 to 1.0
                    const n1 = @max(0.0, @min(1.0, (v1 - node.graph_min) / range));
                    const n2 = @max(0.0, @min(1.0, (v2 - node.graph_min) / range));

                    // Calculate P1 and P2 in absolute UI coordinates
                    const p1_x = node.rect.pos[0] + (x_step * @as(f32, @floatFromInt(i)));
                    const p1_y = node.rect.pos[1] + height - (n1 * height);
                    const p2_x = node.rect.pos[0] + (x_step * @as(f32, @floatFromInt(i + 1)));
                    const p2_y = node.rect.pos[1] + height - (n2 * height);

                    // Create a bounding box that completely surrounds the line segment
                    const min_x = @min(p1_x, p2_x);
                    const min_y = @min(p1_y, p2_y);
                    const max_x = @max(p1_x, p2_x);
                    const max_y = @max(p1_y, p2_y);

                    const q_pos = [2]f32{ min_x - pad, min_y - pad };
                    const q_size = [2]f32{ (max_x - min_x) + (pad * 2.0), (max_y - min_y) + (pad * 2.0) };

                    // Convert P1 and P2 into local coordinates relative to the bounding box
                    const local_1 = [2]f32{ p1_x - q_pos[0], p1_y - q_pos[1] };
                    const local_2 = [2]f32{ p2_x - q_pos[0], p2_y - q_pos[1] };

                    instances.append(self.allocator, InstanceData{
                        .rect_pos = q_pos,
                        .rect_size = q_size,
                        .color = .{ 0.2, 0.8, 0.5, 1.0 }, // Bright green line!
                        .clip_rect = node.clip_rect, // Seamlessly respects scroll boundaries
                        .corner_radius = 0.0,
                        .edge_softness = 0.0,
                        .type_flag = 3, // 3 = SDF Line Segment
                        .uv_min = local_1, // Pass P1
                        .uv_max = local_2, // Pass P2
                    }) catch unreachable;
                }
            }
        }

        var text_width: f32 = 0.0;
        const font_scale: f32 = 24.0;
        const scale: f32 = font_scale / 32.0;

        if (node.text.len > 0) {
            var j: usize = 0;
            while (j < node.text.len) {
                // Check for markup tags and SKIP them!
                if (node.text[j] == '[' and j + 1 < node.text.len) {
                    if (std.mem.startsWith(u8, node.text[j..], "[/]")) {
                        j += 3;
                        continue;
                    }
                    if (std.mem.startsWith(u8, node.text[j..], "[b]")) {
                        j += 3;
                        continue;
                    }
                    if (node.text.len >= j + 9 and node.text[j + 1] == '#' and node.text[j + 8] == ']') {
                        j += 9;
                        continue;
                    }
                }

                const char = node.text[j];
                // Lookup the MSDF glyph advance!
                if (self.font_map.get(char)) |glyph| {
                    text_width += glyph.xadvance * scale;
                }
                j += 1;
            }
        }

        //var text_width: f32 = 0.0;
        //if (node.text.len > 0) {
        //    var dummy_y: f32 = 0.0;
        //    var j: usize = 0;
        //    while (j < node.text.len) {
        //        // Check for markup tags and SKIP them!
        //        if (node.text[j] == '[' and j + 1 < node.text.len) {
        //            if (std.mem.startsWith(u8, node.text[j..], "[/]")) {
        //                j += 3;
        //                continue;
        //            }
        //            if (std.mem.startsWith(u8, node.text[j..], "[b]")) {
        //                j += 3;
        //                continue;
        //            }
        //            if (node.text.len >= j + 9 and node.text[j + 1] == '#' and node.text[j + 8] == ']') {
        //                j += 9;
        //                continue;
        //            }
        //        }

        //        const char = node.text[j];
        //        if (char >= 32 and char < 128) {
        //            var q: c.stbtt_aligned_quad = undefined;
        //            c.stbtt_GetBakedQuad(&font.cdata, 512, 512, @intCast(char - 32), &text_width, &dummy_y, &q, 1);
        //        }
        //        j += 1;
        //    }
        //}

        // 2. Establish our baseline coordinates
        var start_x: f32 = node.rect.pos[0];
        switch (node.text_align) {
            .center => start_x += (node.rect.size[0] - text_width) / 2.0,
            .right => start_x += (node.rect.size[0] - text_width) - node.padding,
            .left => start_x += node.padding,
        }
        const start_y = node.rect.pos[1] + (node.rect.size[1] / 2.0) + 8.0;

        var cursor_x = start_x;
        const cursor_y = start_y;
        var edit_cursor_x: f32 = start_x; // This will track where our blinking line goes

        // --- 2. MARKUP RENDERING & FAUX BOLD ---
        if (node.text.len > 0) {
            var current_color = [4]f32{ 1.0, 1.0, 1.0, 1.0 }; // Default White
            var is_bold = false;
            var i: usize = 0;

            while (i < node.text.len) {
                // Parse Tags
                if (node.text[i] == '[' and i + 1 < node.text.len) {
                    // Reset Tag
                    if (std.mem.startsWith(u8, node.text[i..], "[/]")) {
                        current_color = .{ 1.0, 1.0, 1.0, 1.0 };
                        is_bold = false;
                        i += 3;
                        continue;
                    }
                    // Bold Tag
                    if (std.mem.startsWith(u8, node.text[i..], "[b]")) {
                        is_bold = true;
                        i += 3;
                        continue;
                    }
                    // Hex Color Tag (e.g., [#FF0000])
                    if (node.text.len >= i + 9 and node.text[i + 1] == '#' and node.text[i + 8] == ']') {
                        const hex = node.text[i + 2 .. i + 8];
                        if (std.fmt.parseInt(u32, hex, 16)) |val| {
                            current_color[0] = @as(f32, @floatFromInt((val >> 16) & 0xFF)) / 255.0;
                            current_color[1] = @as(f32, @floatFromInt((val >> 8) & 0xFF)) / 255.0;
                            current_color[2] = @as(f32, @floatFromInt(val & 0xFF)) / 255.0;
                            i += 9;
                            continue;
                        } else |_| {} // Ignore invalid hex
                    }
                }

                // If we reach the cursor index, save the X coordinate!
                if (node.is_focused and node.text_cursor_index == i) {
                    edit_cursor_x = cursor_x;
                }

                const char = node.text[i];
                if (self.font_map.get(char)) |glyph| {

                    // --- BMFont SCREEN PIXEL MATH ---
                    const q_x = cursor_x + (glyph.xoffset * scale);
                    // Base pushes the cursor to the baseline, yoffset pushes it back down to the character top
                    const q_y = cursor_y - (self.font_metrics.base * scale) + (glyph.yoffset * scale);
                    const q_w = glyph.width * scale;
                    const q_h = glyph.height * scale;

                    // --- BMFont TEXTURE UV MATH ---
                    const u_min = glyph.x / self.font_metrics.scaleW;
                    const u_max = (glyph.x + glyph.width) / self.font_metrics.scaleW;
                    const v_min = glyph.y / self.font_metrics.scaleH;
                    const v_max = (glyph.y + glyph.height) / self.font_metrics.scaleH;

                    // 1. Draw Normal Character
                    instances.append(self.allocator, InstanceData{
                        .rect_pos = .{ q_x, q_y },
                        .rect_size = .{ q_w, q_h },
                        .color = current_color,
                        .clip_rect = node.clip_rect,
                        .corner_radius = 0.0,
                        .edge_softness = 0.0,
                        .type_flag = 4,
                        .uv_min = .{ u_min, v_min },
                        .uv_max = .{ u_max, v_max },
                    }) catch unreachable;

                    // 2. Faux Bold
                    if (is_bold) {
                        instances.append(self.allocator, InstanceData{
                            .rect_pos = .{ q_x + 1.0, q_y }, // +1.0 X offset!
                            .rect_size = .{ q_w, q_h },
                            .color = current_color,
                            .clip_rect = node.clip_rect,
                            .corner_radius = 0.0,
                            .edge_softness = 0.0,
                            .type_flag = 4,
                            .uv_min = .{ u_min, v_min },
                            .uv_max = .{ u_max, v_max },
                        }) catch unreachable;
                    }

                    cursor_x += glyph.xadvance * scale;
                }
                i += 1;

                //const char = node.text[i];
                //if (self.font_map.get(char)) |glyph| {
                //    if (glyph.planeBounds != null and glyph.atlasBounds != null) {
                //        const pb = glyph.planeBounds.?;
                //        const ab = glyph.atlasBounds.?;

                //        // MSDF plane Y points UP, but screen Y points DOWN!
                //        const q_x = cursor_x + (pb.left * font_scale);
                //        const q_y = cursor_y - (pb.top * font_scale);
                //        const q_w = (pb.right - pb.left) * font_scale;
                //        const q_h = (pb.top - pb.bottom) * font_scale;

                //        // Image mapping in WGPU starts from top-left
                //        const atlas_w: f32 = 512.0;
                //        const atlas_h: f32 = 512.0;
                //        const u_min = ab.left / atlas_w;
                //        const u_max = ab.right / atlas_w;
                //        const v_min = 1.0 - (ab.top / atlas_h);
                //        const v_max = 1.0 - (ab.bottom / atlas_h);

                //        // 1. Draw Normal Character
                //        instances.append(self.allocator, InstanceData{
                //            .rect_pos = .{ q_x, q_y },
                //            .rect_size = .{ q_w, q_h },
                //            .color = current_color,
                //            .clip_rect = node.clip_rect,
                //            .corner_radius = 0.0,
                //            .edge_softness = 0.0,
                //            .type_flag = 4, // MSDF Shader Branch!
                //            .uv_min = .{ u_min, v_min },
                //            .uv_max = .{ u_max, v_max },
                //        }) catch unreachable;

                //        // 2. Faux Bold
                //        if (is_bold) {
                //            instances.append(self.allocator, InstanceData{
                //                .rect_pos = .{ q_x + 1.0, q_y }, // +1.0 X offset!
                //                .rect_size = .{ q_w, q_h },
                //                .color = current_color,
                //                .clip_rect = node.clip_rect,
                //                .corner_radius = 0.0,
                //                .edge_softness = 0.0,
                //                .type_flag = 4,
                //                .uv_min = .{ u_min, v_min },
                //                .uv_max = .{ u_max, v_max },
                //            }) catch unreachable;
                //        }
                //    }
                //    cursor_x += glyph.advance * font_scale;
                //}

                //const char = node.text[i];
                //if (char >= 32 and char < 128) {
                //    var q: c.stbtt_aligned_quad = undefined;
                //    c.stbtt_GetBakedQuad(&font.cdata, 512, 512, @intCast(char - 32), &cursor_x, &cursor_y, &q, 1);

                //    // 1. Draw Normal Character
                //    instances.append(self.allocator, InstanceData{
                //        .rect_pos = .{ q.x0, q.y0 },
                //        .rect_size = .{ q.x1 - q.x0, q.y1 - q.y0 },
                //        .color = current_color, // Apply dynamic color!
                //        .clip_rect = node.clip_rect,
                //        .corner_radius = 0.0,
                //        .edge_softness = 0.0,
                //        .type_flag = 1,
                //        .uv_min = .{ q.s0, q.t0 },
                //        .uv_max = .{ q.s1, q.t1 },
                //    }) catch unreachable;

                //    // 2. Faux Bold (Draw a second time, shifted right by 1 pixel)
                //    if (is_bold) {
                //        instances.append(self.allocator, InstanceData{
                //            .rect_pos = .{ q.x0 + 1.0, q.y0 }, // +1.0 X offset!
                //            .rect_size = .{ q.x1 - q.x0, q.y1 - q.y0 },
                //            .color = current_color,
                //            .clip_rect = node.clip_rect,
                //            .corner_radius = 0.0,
                //            .edge_softness = 0.0,
                //            .type_flag = 1,
                //            .uv_min = .{ q.s0, q.t0 },
                //            .uv_max = .{ q.s1, q.t1 },
                //        }) catch unreachable;
                //    }
                //}
                //i += 1;
            }
        }

        // If the cursor index is at the very end of the string (or the string is empty)
        if (node.is_focused and node.text_cursor_index == node.text.len) {
            edit_cursor_x = cursor_x;
        }

        // 4. Draw the blinking edit line
        if (node.is_focused) {
            const time_ms = std.time.milliTimestamp();
            if (@mod(time_ms, 1000) > 500) {
                const cursor_height: f32 = 18.0;
                const centered_y = node.rect.pos[1] + (node.rect.size[1] - cursor_height) / 2.0;
                instances.append(self.allocator, InstanceData{
                    // Use the stable start_y minus an offset to center it vertically
                    .rect_pos = .{ edit_cursor_x + 1.0, centered_y },
                    .rect_size = .{ 2.0, cursor_height },
                    .color = .{ 1.0, 1.0, 1.0, 1.0 },
                    .clip_rect = node.clip_rect,
                    .corner_radius = 0.0,
                    .edge_softness = 0.0,
                    .type_flag = 0,
                    .uv_min = .{ 0.0, 0.0 },
                    .uv_max = .{ 0.0, 0.0 },
                }) catch unreachable;
                //draw_cmds.items[draw_cmds.items.len - 1].instance_count += 1; // <-- ADD THIS AFTER EVERY APPEND!
            }
        }

        var iter = node.first;
        while (iter) |child| : (iter = child.next) {
            self.buildRenderCommands(child, instances, draw_cmds, current_bg, font);
        }
    }

    // --- High Level API ---
    pub fn button(self: *UI, text: []const u8, theme: ButtonTheme) bool {
        var box = self.pushBox(text, BoxFlags{ .clickable = true, .draw_background = true });

        box.text = text;
        box.text_align = .center;
        box.pref_size = .{ .{ .kind = .pixels, .value = 150.0 }, .{ .kind = .pixels, .value = 40.0 } };
        box.corner_radius = 0.0;

        // Blend colors using the _t values!
        for (0..3) |i| {
            box.bg_color[i] = theme.base[i] +
                (theme.hover[i] - theme.base[i]) * box.hot_t +
                (theme.active[i] - theme.hover[i]) * box.active_t;
        }
        box.bg_color[3] = theme.base[3]; // Keep alpha consistent

        self.popBox();
        return self.active_hash == box.hash and self.input.mouse_left_released and self.hot_hash_this_frame == box.hash;
    }

    //pub fn label(self: *UI, text: []const u8) void {
    //    const node = self.getCurrentNode();

    //    // This is your desired font size in screen pixels
    //    const font_scale: f32 = 24.0;

    //    // The exact dimensions of the PNG you generated!
    //    const atlas_w: f32 = 512.0;
    //    const atlas_h: f32 = 512.0;

    //    // We start drawing from the top-left of the UI box, but fonts draw from a baseline.
    //    // We push the starting Y down so the letters don't render outside the top of the box!
    //    var cursor_x: f32 = node.rect.pos[0];
    //    var cursor_y: f32 = node.rect.pos[1] + font_scale;

    //    for (text) |char| {
    //        // Handle simple newlines
    //        if (char == '\n') {
    //            cursor_x = node.rect.pos[0];
    //            cursor_y += font_scale * 1.2; // 1.2 is a standard line-height multiplier
    //            continue;
    //        }

    //        if (self.font_map.get(char)) |glyph| {
    //            // Some characters (like spaces) don't have physical geometry to draw!
    //            if (glyph.planeBounds != null and glyph.atlasBounds != null) {
    //                const pb = glyph.planeBounds.?;
    //                const ab = glyph.atlasBounds.?;

    //                // --- 1. CALCULATE SCREEN RECTANGLE ---
    //                // pb.left/right/top/bottom are normalized values (usually around -0.2 to +1.0).
    //                // We multiply them by our desired font_scale to get actual screen pixels.
    //                // Note: We subtract pb.top from cursor_y because MSDF plane Y points UP, but our screen Y points DOWN!
    //                const q_x = cursor_x + (pb.left * font_scale);
    //                const q_y = cursor_y - (pb.top * font_scale);
    //                const q_w = (pb.right - pb.left) * font_scale;
    //                const q_h = (pb.top - pb.bottom) * font_scale;

    //                // --- 2. CALCULATE WEBGPU UVs ---
    //                // Convert the pixel coordinates from the JSON into 0.0 -> 1.0 space
    //                // We invert the Y coordinates because image mapping in WGPU starts from the top-left!
    //                const u_min = ab.left / atlas_w;
    //                const u_max = ab.right / atlas_w;
    //                const v_min = 1.0 - (ab.top / atlas_h);
    //                const v_max = 1.0 - (ab.bottom / atlas_h);

    //                // --- 3. PUSH TO THE GPU BUFFER ---
    //                self.commands.append(self.allocator, InstanceData{
    //                    .rect_pos = .{ q_x, q_y },
    //                    .rect_size = .{ q_w, q_h },
    //                    .color = node.color, // Inherit color from the UI block
    //                    .clip_rect = node.clip_rect,
    //                    .corner_radius = 0.0,
    //                    .edge_softness = 0.0,

    //                    .type_flag = 4, // Your new MSDF shader branch!

    //                    .uv_min = .{ u_min, v_min },
    //                    .uv_max = .{ u_max, v_max },
    //                }) catch unreachable;
    //            }

    //            // Move the cursor forward for the next letter
    //            cursor_x += glyph.advance * font_scale;
    //        }
    //    }
    //}

    pub fn label(self: *UI, text: []const u8) void {
        var box = self.pushBox(text, BoxFlags{}); // No background, not clickable
        box.text = text;

        // Optional: Force the box size to wrap the text somewhat tightly
        // (In a full engine, you'd calculate this exactly using the STB font metrics)
        //box.pref_size = .{ .{ .kind = .pixels, .value = @as(f32, @floatFromInt(text.len)) * 16.0 }, .{ .kind = .pixels, .value = 32.0 } };
        box.pref_size = .{ .{ .kind = .text_content, .value = 0.0 }, .{ .kind = .pixels, .value = 32.0 } };

        self.popBox();
    }

    pub fn buttonFullWidth(self: *UI, text: []const u8, theme: ButtonTheme) bool {
        var box = self.pushBox(text, BoxFlags{ .clickable = true, .draw_background = true });

        box.text = text;
        box.text_align = .center;

        // Width: 100% of available parent space. Height: 40 pixels.
        box.pref_size = .{ .{ .kind = .percent_of_parent, .value = 100.0 }, .{ .kind = .pixels, .value = 40.0 } };

        box.corner_radius = 0.0;

        // Your exact interpolation math, now driven by the theme!
        for (0..3) |i| {
            box.bg_color[i] = theme.base[i] +
                (theme.hover[i] - theme.base[i]) * box.hot_t +
                (theme.active[i] - theme.hover[i]) * box.active_t;
        }
        box.bg_color[3] = theme.base[3]; // Keep alpha consistent

        self.popBox();
        return self.active_hash == box.hash and self.input.mouse_left_released and self.hot_hash_this_frame == box.hash;
    }

    pub fn checkbox(self: *UI, text: []const u8, state: *bool) bool {
        var changed = false;

        // 1. A clickable horizontal row that tightly wraps its children
        var row = self.pushBox(text, BoxFlags{ .layout_horizontal = true, .clickable = true });
        row.pref_size = .{ .{ .kind = .children_sum, .value = 0.0 }, .{ .kind = .children_sum, .value = 0.0 } };
        row.gap = 10.0; // Space between the square and the text

        // 2. The outer square box
        var box = self.pushBox("box", BoxFlags{ .draw_background = true });
        box.pref_size = .{ .{ .kind = .pixels, .value = 24.0 }, .{ .kind = .pixels, .value = 24.0 } };
        box.corner_radius = 4.0;
        box.padding = 6.0; // This perfectly insets our 100% width checkmark!

        // Color interpolation based on the ROW's interaction state
        if (self.active_hash == row.hash) {
            box.bg_color = .{ 0.2, 0.4, 0.8, 1.0 };
        } else if (self.hot_hash_this_frame == row.hash) {
            box.bg_color = .{ 0.3, 0.5, 0.9, 1.0 };
        } else {
            box.bg_color = .{ 0.15, 0.25, 0.45, 1.0 };
        }

        // 3. The inner checkmark (only drawn if state is true)
        if (state.*) {
            var check = self.pushBox("check", BoxFlags{ .draw_background = true });
            check.pref_size = .{ .{ .kind = .percent_of_parent, .value = 100.0 }, .{ .kind = .percent_of_parent, .value = 100.0 } };
            check.bg_color = .{ 1.0, 1.0, 1.0, 1.0 }; // White square
            check.corner_radius = 2.0;
            self.popBox(); // pop check
        }
        self.popBox(); // pop box

        // 4. The text label
        self.label(text);

        // 5. Trigger the toggle
        if (self.active_hash == row.hash and self.input.mouse_left_released and self.hot_hash_this_frame == row.hash) {
            state.* = !state.*;
            changed = true;
        }

        self.popBox(); // pop row
        return changed;
    }

    // We use usize here, but you can easily change this to support Enums!
    pub fn radioButton(self: *UI, text: []const u8, active_value: *usize, this_value: usize) bool {
        var changed = false;

        var row = self.pushBox(text, BoxFlags{ .layout_horizontal = true, .clickable = true });
        row.pref_size = .{ .{ .kind = .children_sum, .value = 0.0 }, .{ .kind = .children_sum, .value = 0.0 } };
        row.gap = 10.0;

        var box = self.pushBox("radio", BoxFlags{ .draw_background = true });
        box.pref_size = .{ .{ .kind = .pixels, .value = 24.0 }, .{ .kind = .pixels, .value = 24.0 } };
        box.corner_radius = 12.0; // 12 is half of 24 = Perfect Circle!
        box.padding = 6.0;

        if (self.active_hash == row.hash) {
            box.bg_color = .{ 0.2, 0.4, 0.8, 1.0 };
        } else if (self.hot_hash_this_frame == row.hash) {
            box.bg_color = .{ 0.3, 0.5, 0.9, 1.0 };
        } else {
            box.bg_color = .{ 0.15, 0.25, 0.45, 1.0 };
        }

        // Draw the inner circle if this is the currently active value
        if (active_value.* == this_value) {
            var dot = self.pushBox("dot", BoxFlags{ .draw_background = true });
            dot.pref_size = .{ .{ .kind = .percent_of_parent, .value = 100.0 }, .{ .kind = .percent_of_parent, .value = 100.0 } };
            dot.bg_color = .{ 1.0, 1.0, 1.0, 1.0 };
            dot.corner_radius = 6.0; // Half of the 12x12 inner size
            self.popBox();
        }
        self.popBox();

        self.label(text);

        if (self.active_hash == row.hash and self.input.mouse_left_released and self.hot_hash_this_frame == row.hash) {
            if (active_value.* != this_value) {
                active_value.* = this_value;
                changed = true;
            }
        }

        self.popBox();
        return changed;
    }

    pub fn slider(self: *UI, text: []const u8, value: *f32, min_val: f32, max_val: f32) bool {
        var changed = false;

        // 1. The outer row container
        var row = self.pushBox(text, BoxFlags{ .layout_horizontal = true });
        row.pref_size = .{ .{ .kind = .percent_of_parent, .value = 100.0 }, .{ .kind = .children_sum, .value = 0.0 } };
        row.gap = 15.0;

        // 2. Format the dynamic label text using the Frame Arena!
        // We cannot use a local stack buffer like bufPrint here because this function
        // returns immediately, destroying the stack memory before endFrame renders it.
        const display_text = std.fmt.allocPrint(self.frame_arena.allocator(), "{s}: {d:.2}", .{ text, value.* }) catch text;

        // Label on the left
        var label_box = self.pushBox("label", BoxFlags{});
        label_box.text = display_text;
        label_box.pref_size = .{ .{ .kind = .text_content, .value = 0.0 }, .{ .kind = .pixels, .value = 32.0 } };
        self.popBox();

        // 3. The interactive track
        var track = self.pushBox("track", BoxFlags{ .clickable = true, .draw_background = true });
        track.pref_size = .{ .{ .kind = .percent_of_parent, .value = 100.0 }, .{ .kind = .pixels, .value = 32.0 } };
        track.corner_radius = 6.0;
        track.bg_color = .{ 0.1, 0.1, 0.15, 1.0 }; // Dark track background

        // --- THE SLIDER MATH ---
        if (self.active_hash == track.hash) {
            // Read the cached dimensions from the previous frame!
            if (self.layout_cache.get(track.hash)) |cached_rect| {
                const track_x = cached_rect[0];
                const track_w = cached_rect[2];

                if (track_w > 0.0) {
                    var t = (self.input.mouse_x - track_x) / track_w;
                    t = @max(0.0, @min(1.0, t)); // Clamp

                    const new_val = min_val + t * (max_val - min_val);
                    if (value.* != new_val) {
                        value.* = new_val;
                        changed = true;
                    }
                }
            }
        }
        // -----------------------

        // 4. The colored Fill portion inside the track
        const fill_pct = (value.* - min_val) / (max_val - min_val);

        var fill = self.pushBox("fill", BoxFlags{ .draw_background = true });
        fill.pref_size = .{ .{ .kind = .percent_of_parent, .value = fill_pct * 100.0 }, .{ .kind = .percent_of_parent, .value = 100.0 } };
        fill.corner_radius = 6.0;

        // Smooth interaction colors
        if (self.active_hash == track.hash) {
            fill.bg_color = .{ 0.3, 0.6, 1.0, 1.0 }; // Active Blue
        } else if (self.hot_hash_this_frame == track.hash) {
            fill.bg_color = .{ 0.4, 0.7, 1.0, 1.0 }; // Hover Blue
        } else {
            fill.bg_color = .{ 0.2, 0.5, 0.9, 1.0 }; // Idle Blue
        }

        self.popBox(); // pop fill
        self.popBox(); // pop track
        self.popBox(); // pop row

        return changed;
    }

    pub fn textInput(self: *UI, id_str: []const u8, buffer: []u8, text_len: *usize) bool {
        var changed = false;

        var box = self.pushBox(id_str, BoxFlags{ .clickable = true, .draw_background = true });
        box.pref_size = .{ .{ .kind = .percent_of_parent, .value = 100.0 }, .{ .kind = .pixels, .value = 36.0 } };
        box.corner_radius = 6.0;
        box.padding = 10.0;
        box.text_align = .left;

        // 1. Handle Focus State
        if (self.input.mouse_left_released) {
            if (self.hot_hash_this_frame == box.hash) {
                if (self.focused_hash != box.hash) {
                    self.focused_hash = box.hash;
                    self.focused_cursor_index = text_len.*; // Jump cursor to the end when clicked
                }
            } else if (self.focused_hash == box.hash) {
                self.focused_hash = 0;
            }
        }

        box.is_focused = (self.focused_hash == box.hash);

        // 2. Visual Styling
        if (box.is_focused) {
            box.bg_color = .{ 0.15, 0.15, 0.2, 1.0 }; // Brighter background when typing
        } else if (self.hot_hash_this_frame == box.hash) {
            box.bg_color = .{ 0.1, 0.1, 0.15, 1.0 }; // Hover color
        } else {
            box.bg_color = .{ 0.05, 0.05, 0.1, 1.0 }; // Idle color
        }

        // 3. Process Keystrokes & Navigation
        if (box.is_focused) {
            // Failsafe: keep cursor within bounds
            if (self.focused_cursor_index > text_len.*) self.focused_cursor_index = text_len.*;

            // Navigation
            if (self.input.left_arrow_pressed and self.focused_cursor_index > 0) {
                self.focused_cursor_index -= 1;
            }
            if (self.input.right_arrow_pressed and self.focused_cursor_index < text_len.*) {
                self.focused_cursor_index += 1;
            }

            // Backspace (Delete at cursor)
            if (self.input.backspace_pressed and self.focused_cursor_index > 0) {
                // Shift everything to the right of the cursor ONE slot to the left
                std.mem.copyForwards(u8, buffer[self.focused_cursor_index - 1 .. text_len.* - 1], buffer[self.focused_cursor_index..text_len.*]);
                text_len.* -= 1;
                self.focused_cursor_index -= 1;
                changed = true;
            }
            // Insert typed character at cursor
            else if (self.input.typed_char != 0 and text_len.* < buffer.len) {
                // Shift everything to the right of the cursor ONE slot to the right
                std.mem.copyBackwards(u8, buffer[self.focused_cursor_index + 1 .. text_len.* + 1], buffer[self.focused_cursor_index..text_len.*]);
                buffer[self.focused_cursor_index] = self.input.typed_char;
                text_len.* += 1;
                self.focused_cursor_index += 1;
                changed = true;
            }

            // Tell the box where the cursor is so the renderer can find it!
            box.text_cursor_index = self.focused_cursor_index;
        }

        // 4. Assign the slice
        box.text = buffer[0..text_len.*];

        self.popBox();
        return changed;
    }

    pub fn dropdown(self: *UI, id_str: []const u8, options: []const []const u8, selected_index: *usize) bool {
        var changed = false;

        // 1. The Main Button
        const display_text = std.fmt.allocPrint(self.frame_arena.allocator(), "{s}: {s}", .{ id_str, options[selected_index.*] }) catch id_str;

        var btn = self.pushBox(id_str, BoxFlags{ .clickable = true, .draw_background = true });
        btn.text = display_text;
        btn.pref_size = .{ .{ .kind = .percent_of_parent, .value = 100.0 }, .{ .kind = .pixels, .value = 36.0 } };

        if (self.hot_hash_this_frame == btn.hash) {
            btn.bg_color = .{ 0.2, 0.2, 0.25, 1.0 };
        } else {
            btn.bg_color = .{ 0.15, 0.15, 0.2, 1.0 };
        }

        // Toggle state
        if (self.active_hash == btn.hash and self.input.mouse_left_released) {
            if (self.opened_dropdown_hash == btn.hash) {
                self.opened_dropdown_hash = 0; // Close
            } else {
                self.opened_dropdown_hash = btn.hash; // Open
            }
        }

        self.popBox(); // pop btn
        // 2. The Floating Popup Menu
        if (self.opened_dropdown_hash == btn.hash) {
            if (self.layout_cache.get(btn.hash)) |rect| {
                const item_height: f32 = 32.0;
                const padding: f32 = 8.0;
                const total_height = (@as(f32, @floatFromInt(options.len)) * item_height) + padding;
                var spawn_y = rect[1] + rect[2];

                // If it hangs off the bottom of the window, flip it ABOVE the button!
                if (spawn_y + total_height > self.window_height) {
                    spawn_y = rect[1] - total_height;
                }

                var popup = self.pushBox("popup", BoxFlags{
                    .is_popup = true, // Force absolute positioning and top-layer rendering!
                    .draw_background = true,
                    .layout_horizontal = false,
                });

                // Match the button's width, let height grow based on items
                popup.pref_size = .{ .{ .kind = .pixels, .value = rect[2] }, .{ .kind = .pixels, .value = total_height } };
                popup.bg_color = .{ 0.1, 0.1, 0.15, 1.0 };
                popup.padding = 4.0;
                popup.z_index += 10;

                for (options, 0..) |opt, i| {
                    var item = self.pushBox(opt, BoxFlags{ .clickable = true, .draw_background = true });
                    item.text = opt;
                    item.pref_size = .{ .{ .kind = .percent_of_parent, .value = 100.0 }, .{ .kind = .pixels, .value = 32.0 } };
                    item.z_index += 10;

                    if (self.hot_hash_this_frame == item.hash) {
                        item.bg_color = .{ 0.3, 0.5, 0.9, 1.0 }; // Hover highlight
                    } else {
                        item.bg_color = .{ 0.1, 0.1, 0.15, 1.0 };
                    }

                    if (self.active_hash == item.hash and self.input.mouse_left_released) {
                        selected_index.* = i;
                        changed = true;
                    }
                    self.popBox(); // pop item
                }
                self.popBox(); // pop popup
            }

            // 3. Auto-close logic
            // If the mouse was clicked anywhere, and it wasn't on the toggle button, close it.
            if (self.input.mouse_left_released and self.hot_hash_this_frame != btn.hash) {
                self.opened_dropdown_hash = 0;
            }
        }

        return changed;
    }

    pub fn image(self: *UI, tex: Texture, width: f32, height: f32) void {
        var box = self.pushBox("image", BoxFlags{});
        box.pref_size = .{ .{ .kind = .pixels, .value = width }, .{ .kind = .pixels, .value = height } };

        // --- CUSTOM RENDER CALLBACK ---
        // Instead of writing the rendering logic inside buildRenderCommands,
        // we can store the texture pointer directly on the box!
        // (You will need to add `texture: ?Texture = null` to your Box struct!)
        box.texture = tex;

        self.popBox();
    }

    pub fn graph(self: *UI, id_str: []const u8, data: []const f32, min_val: f32, max_val: f32, width: f32, height: f32) void {
        var box = self.pushBox(id_str, BoxFlags{ .draw_background = true, .clickable = true });

        // Give the graph an explicit height, let it fill available width
        box.pref_size = .{ .{ .kind = .pixels, .value = width }, .{ .kind = .pixels, .value = height } };
        box.bg_color = .{ 0.05, 0.05, 0.08, 1.0 }; // Dark graph background
        box.corner_radius = 4.0;

        // Attach the data!
        box.graph_data = data;
        box.graph_min = min_val;
        box.graph_max = max_val;

        // --- 2. INTERACTIVITY & TOOLTIPS ---
        if (self.hot_hash_this_frame == box.hash and data.len > 1) {
            // Read the screen coordinates of the graph from the layout cache
            if (self.layout_cache.get(box.hash)) |rect| {

                // Math: Find which data index the mouse is currently hovering over
                const local_x = self.input.mouse_x - rect[0];
                const hover_pct = @max(0.0, @min(1.0, local_x / rect[2]));

                const float_idx = hover_pct * @as(f32, @floatFromInt(data.len - 1));
                const nearest_index = @as(usize, @intFromFloat(@round(float_idx))); // Snap to nearest point

                // Math: Calculate the exact screen X coordinate of that data point
                const point_x = rect[0] + (@as(f32, @floatFromInt(nearest_index)) / @as(f32, @floatFromInt(data.len - 1)) * rect[2]);

                // A. Draw a Vertical Scrubber Line
                var scrubber = self.pushBox("scrubber", BoxFlags{
                    .is_popup = true,
                    .floating = true, // Force absolute coordinates
                    .draw_background = true,
                });
                scrubber.fixed_x = point_x;
                scrubber.fixed_y = rect[1];
                scrubber.pref_size = .{ .{ .kind = .pixels, .value = 2.0 }, .{ .kind = .pixels, .value = rect[3] } };
                scrubber.bg_color = .{ 1.0, 1.0, 1.0, 0.2 }; // Semi-transparent white line
                scrubber.z_index = 15;
                self.popBox();

                // B. Draw the Floating Tooltip
                const val = data[nearest_index];
                const tip_text = std.fmt.allocPrint(self.frame_arena.allocator(), "Index {d}: {d:.2}", .{ nearest_index, val }) catch "Error";

                var tip = self.pushBox("tooltip", BoxFlags{ .is_popup = true, .floating = true, .draw_background = true });
                tip.text = tip_text;

                // Position it offset slightly from the mouse cursor so it doesn't block the line!
                tip.fixed_x = self.input.mouse_x + 15.0;
                tip.fixed_y = self.input.mouse_y - 15.0;

                tip.pref_size = .{ .{ .kind = .text_content, .value = 0.0 }, .{ .kind = .pixels, .value = 24.0 } };
                tip.bg_color = .{ 0.2, 0.2, 0.2, 0.95 }; // Dark grey, mostly opaque
                tip.padding = 6.0;
                tip.corner_radius = 4.0;
                tip.z_index = 20; // Ensure it renders on top of everything

                self.popBox(); // pop tip
            }
        }

        self.popBox();
    }

    pub fn modelViewer(self: *UI, id_str: []const u8, render_target: Texture, width: f32, height: f32, yaw: *f32, pitch: *f32, zoom: *f32) void {
        const hash = self.generateId(id_str);

        // 1. Create an interactive box
        var box = self.pushBox(id_str, BoxFlags{ .clickable = true, .draw_background = true, .scrollable_y = true });

        box.pref_size = .{ .{ .kind = .pixels, .value = width }, .{ .kind = .pixels, .value = height } };
        box.bg_color = .{ 0.0, 0.0, 0.0, 1.0 }; // Black background for the 3D scene
        box.corner_radius = 4.0;

        // 2. Display the offscreen 3D texture!
        box.texture = render_target;

        // --- ADD ZOOM MATH ---
        if (self.hovered_scroll_hash == box.hash) {
            // Apply mouse wheel delta
            zoom.* -= self.input.scroll_y * 0.5; // 0.5 is the zoom speed sensitivity

            // Clamp it so the camera doesn't fly through the object or too far away!
            zoom.* = @max(1.0, @min(50.0, zoom.*));
        }
        // ---------------------

        // 3. Handle 3D Camera Orbiting
        if (self.active_hash == box.hash) {
            if (self.retained_state.getPtr(hash)) |state| {
                // On the exact frame we click, cache the mouse position
                if (self.input.mouse_left_pressed) {
                    state.drag_offset_x = self.input.mouse_x;
                    state.drag_offset_y = self.input.mouse_y;
                }

                // Calculate how far the mouse moved since last frame
                const dx = self.input.mouse_x - state.drag_offset_x;
                const dy = self.input.mouse_y - state.drag_offset_y;

                // Apply sensitivity and update the camera angles
                const sensitivity = 0.01;
                yaw.* += dx * sensitivity;
                pitch.* += dy * sensitivity;

                // Clamp pitch so the camera doesn't flip upside down!
                const pitch_limit = std.math.pi / 2.0 - 0.1;
                pitch.* = @max(-pitch_limit, @min(pitch_limit, pitch.*));

                // Reset the tracker so we get continuous deltas while dragging
                state.drag_offset_x = self.input.mouse_x;
                state.drag_offset_y = self.input.mouse_y;
            }
        }

        // Draw a subtle border when hovering
        //if (self.hot_hash_this_frame == box.hash) {
        //    box.bg_color = .{ 0.2, 0.2, 0.2, 1.0 };
        //}

        self.popBox();
    }

    pub fn colorPicker(self: *UI, _label: []const u8, color: *[4]f32) void {
        self.label(_label);

        // 1. The Color Swatch (A simple box with its background set to the current color!)
        var swatch = self.pushBox(_label, BoxFlags{ .draw_background = true });
        swatch.pref_size = .{ .{ .kind = .percent_of_parent, .value = 100.0 }, .{ .kind = .pixels, .value = 24.0 } };
        swatch.bg_color = color.*; // Dereference the pointer to read the current array values
        swatch.corner_radius = 4.0;
        self.popBox();

        // 2. The Sliders
        // (Note: In a massive application, you would concatenate the label string with
        // "Red", "Green", etc., to prevent ID hash collisions between multiple color pickers)
        _ = self.slider("Red", &color[0], 0.0, 1.0);
        _ = self.slider("Green", &color[1], 0.0, 1.0);
        _ = self.slider("Blue", &color[2], 0.0, 1.0);
        _ = self.slider("Alpha", &color[3], 0.0, 1.0);
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
    \\     @location(8) @interpolate(flat) raw_uv_min: vec2<f32>,
    \\     @location(9) @interpolate(flat) raw_uv_max: vec2<f32>,
    \\ };
    \\
    \\ @group(0) @binding(0) var diffuse_tex: texture_2d<f32>;
    \\ @group(0) @binding(1) var diffuse_sampler: sampler;
    \\ @group(0) @binding(2) var<uniform> screen_size: vec2<f32>;
    \\
    \\ @vertex fn vs_main(model: VertexInput, instance: InstanceInput) -> VertexOutput {
    \\     var out: VertexOutput;
    \\     out.uv = model.pos;
    \\     let pixel_pos = instance.rect_pos + (model.pos * instance.rect_size);
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
    \\     out.raw_uv_min = instance.uv_min;
    \\     out.raw_uv_max = instance.uv_max;
    \\     return out;
    \\ }
    \\ @fragment fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    \\     // If the pixel is outside the inherited clip bounds, throw it away!
    \\     if (in.clip_pos.x < in.clip_rect.x || in.clip_pos.y < in.clip_rect.y || in.clip_pos.x > in.clip_rect.z || in.clip_pos.y > in.clip_rect.w) {
    \\         discard;
    \\     }
    \\
    \\     // WGPU automatically converts @builtin(position) to framebuffer pixel coordinates here
    \\     let pixel_x = in.clip_pos.x;
    \\     let pixel_y = in.clip_pos.y;
    \\     
    \\     if (pixel_x < in.clip_rect[0] || pixel_y < in.clip_rect[1] || 
    \\         pixel_x > in.clip_rect[2] || pixel_y > in.clip_rect[3]) { discard; }
    \\     if (in.type_flag == 1u) {
    \\         let alpha = textureSample(diffuse_tex, diffuse_sampler, in.tex_uv).r;
    \\         if (alpha <= 0.01) { discard; }
    \\         return vec4<f32>(in.color.rgb, in.color.a * alpha);
    \\     } else if (in.type_flag == 2u) {
    \\         let tex_color = textureSample(diffuse_tex, diffuse_sampler, in.tex_uv);
    \\         if (tex_color.a <= 0.01) { discard; }
    \\         return tex_color * in.color;
    \\     } else if (in.type_flag == 3u) {
    \\         let p = in.uv * in.box_size;
    \\         let a = in.raw_uv_min;
    \\         let b = in.raw_uv_max;
    \\         
    \\         let pa = p - a;
    \\         let ba = b - a;
    \\         
    \\         let h = clamp(dot(pa, ba) / max(dot(ba, ba), 0.0001), 0.0, 1.0);
    \\         let d = length(pa - ba * h);
    \\         
    \\         let thickness = 2.0;
    \\         let alpha = 1.0 - smoothstep(thickness - 1.0, thickness + 0.5, d);
    \\         
    \\         if (alpha <= 0.01) { discard; }
    \\         return vec4<f32>(in.color.rgb, in.color.a * alpha);
    \\     } else if (in.type_flag == 4u) {
    \\         // --- THE NEW MSDF SHADER ---
    \\         let msd = textureSample(diffuse_tex, diffuse_sampler, in.tex_uv).rgb;
    \\         
    \\         // Find the median of the 3 channels
    \\         let sd = max(min(msd.r, msd.g), min(max(msd.r, msd.g), msd.b)) - 0.5;
    \\         
    \\         // fwidth calculates the anti-aliasing gradient perfectly at any zoom level
    \\         let screen_px_dist = sd / max(fwidth(sd), 0.0001);
    \\         
    \\         let alpha = clamp(screen_px_dist + 0.5, 0.0, 1.0);
    \\         
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

const wgsl_shader_3d =
    \\ struct Uniforms { 
    \\     mvp: mat4x4<f32>, 
    \\     light_dir: vec3<f32>,
    \\     ambient: f32,
    \\     wobble: f32,
    \\     time: f32,
    \\     padding: vec2<f32>,
    \\ };
    \\ @group(0) @binding(0) var<uniform> uniforms: Uniforms;
    \\ @group(0) @binding(1) var t_diffuse: texture_2d<f32>;
    \\ @group(0) @binding(2) var s_diffuse: sampler;
    \\
    \\ struct VertexInput {
    \\     @location(0) pos: vec3<f32>,
    \\     @location(1) normal: vec3<f32>,
    \\     @location(2) uv: vec2<f32>,
    \\     @location(3) color: vec3<f32>,
    \\ };
    \\ struct VertexOutput {
    \\     @builtin(position) clip_pos: vec4<f32>,
    \\     @location(0) normal: vec3<f32>,
    \\     @location(1) color: vec3<f32>,
    \\     @location(2) uv: vec2<f32>,
    \\ };
    \\
    \\ @vertex fn vs_main(model: VertexInput) -> VertexOutput {
    \\     var out: VertexOutput;
    \\     
    \\     // --- THE WOBBLE EFFECT ---
    \\     // Calculate a wave based on the Y position and Time
    \\     let wave = sin(model.pos.y * 10.0 + uniforms.time * 5.0);
    \\     // Push the vertex outward along its normal
    \\     let displaced_pos = model.pos + (model.normal * wave * uniforms.wobble);
    \\     
    \\     out.clip_pos = uniforms.mvp * vec4<f32>(displaced_pos, 1.0);
    \\     out.normal = model.normal;
    \\     out.color = model.color;
    \\     out.uv = model.uv;
    \\     return out;
    \\ }
    \\
    \\ @fragment fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    \\     let light_dir = normalize(uniforms.light_dir);
    \\     let n = normalize(in.normal);
    \\     
    \\     // Apply dynamic ambient lighting
    \\     let diffuse_light = max(dot(n, light_dir), uniforms.ambient); 
    \\     
    \\     let tex_color = textureSample(t_diffuse, s_diffuse, in.uv);
    \\     let safe_color = max(in.color, vec3<f32>(0.01, 0.01, 0.01)) + step(length(in.color), 0.0) * vec3<f32>(1.0);
    \\     
    \\     let final_color = tex_color.rgb * safe_color * diffuse_light;
    \\     
    \\     return vec4<f32>(final_color, tex_color.a);
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
    screen_uniform_buf: c.WGPUBuffer,

    bind_group_layout: c.WGPUBindGroupLayout,

    // --- 3D Pipeline Additions ---
    bind_group_layout_3d: c.WGPUBindGroupLayout,
    pipeline_3d: c.WGPURenderPipeline,
    vbo_3d: c.WGPUBuffer,
    num_3d_verts: u32,
    mvp_uniform_buf: c.WGPUBuffer,
    bind_group_3d: c.WGPUBindGroup,

    offscreen_tex: Texture,
    offscreen_view: c.WGPUTextureView, // Needed for the render pass
    depth_tex: c.WGPUTexture,
    depth_view: c.WGPUTextureView,

    model_tex: c.WGPUTexture,
    model_tex_view: c.WGPUTextureView,
    model_sampler: c.WGPUSampler,

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

        // Create Uniform Buffer for Screen Size
        const uniform_desc = c.WGPUBufferDescriptor{
            .nextInChain = null,
            .label = empty_label,
            .usage = c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst,
            .size = @sizeOf([2]f32),
            .mappedAtCreation = 0,
        };
        const screen_uniform_buf = c.wgpuDeviceCreateBuffer(device, &uniform_desc);

        // Upload initial 800x600
        const initial_screen = [2]f32{ 800.0, 600.0 };
        c.wgpuQueueWriteBuffer(queue, screen_uniform_buf, 0, &initial_screen, @sizeOf([2]f32));

        // 1. Load MSDF Atlas PNG via stb_image
        var font: Font = undefined;
        var img_w: c_int = 0;
        var img_h: c_int = 0;
        var img_channels: c_int = 0;
        const img_data = c.stbi_load("assets/atlas.png", &img_w, &img_h, &img_channels, 4);
        if (img_data == null) return error.ImageLoadFailed;
        defer c.stbi_image_free(img_data);

        // 2. Create WGPU Texture (RGBA8Unorm)
        const tex_desc = c.WGPUTextureDescriptor{
            .nextInChain = null,
            .label = empty_label,
            .usage = c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_CopyDst,
            .dimension = c.WGPUTextureDimension_2D,
            .size = .{ .width = @intCast(img_w), .height = @intCast(img_h), .depthOrArrayLayers = 1 },
            .format = c.WGPUTextureFormat_RGBA8Unorm, // Full color for MSDF channels!
            .mipLevelCount = 1,
            .sampleCount = 1,
            .viewFormatCount = 0,
            .viewFormats = null,
        };
        font.texture = c.wgpuDeviceCreateTexture(device, &tex_desc);

        // Upload to GPU
        const image_copy = c.WGPUTexelCopyTextureInfo{
            .texture = font.texture,
            .mipLevel = 0,
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .aspect = c.WGPUTextureAspect_All,
        };
        const layout = c.WGPUTexelCopyBufferLayout{
            .offset = 0,
            .bytesPerRow = @intCast(img_w * 4),
            .rowsPerImage = @intCast(img_h),
        };
        const copy_size = c.WGPUExtent3D{ .width = @intCast(img_w), .height = @intCast(img_h), .depthOrArrayLayers = 1 };
        c.wgpuQueueWriteTexture(queue, &image_copy, img_data, @intCast(img_w * img_h * 4), &layout, &copy_size);

        font.view = c.wgpuTextureCreateView(font.texture, null);

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
        };
        font.sampler = c.wgpuDeviceCreateSampler(device, &sampler_desc);

        //// 1. Bake the Font
        //const ttf_file = try std.fs.cwd().readFileAlloc(std.heap.page_allocator, "assets/font.otf", 1024 * 1024 * 10);
        //defer std.heap.page_allocator.free(ttf_file);

        //var font: Font = undefined;
        //var temp_bitmap: [512 * 512]u8 = undefined;
        //_ = c.stbtt_BakeFontBitmap(ttf_file.ptr, 0, 32.0, // 32.0 is the pixel height
        //    &temp_bitmap, 512, 512, 32, 96, &font.cdata);

        //// 2. Create WGPU Texture
        //const tex_desc = c.WGPUTextureDescriptor{
        //    .nextInChain = null,
        //    .label = empty_label,
        //    .usage = c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_CopyDst,
        //    .dimension = c.WGPUTextureDimension_2D,
        //    .size = .{ .width = 512, .height = 512, .depthOrArrayLayers = 1 },
        //    .format = c.WGPUTextureFormat_R8Unorm, // Single channel alpha!
        //    .mipLevelCount = 1,
        //    .sampleCount = 1,
        //    .viewFormatCount = 0,
        //    .viewFormats = null,
        //};
        //font.texture = c.wgpuDeviceCreateTexture(device, &tex_desc);

        //// Upload the bitmap bytes
        //const image_copy = c.WGPUTexelCopyTextureInfo{
        //    //.nextInChain = null,
        //    .texture = font.texture,
        //    .mipLevel = 0,
        //    .origin = .{ .x = 0, .y = 0, .z = 0 },
        //    .aspect = c.WGPUTextureAspect_All,
        //};
        //const layout = c.WGPUTexelCopyBufferLayout{
        //    //.nextInChain = null,
        //    .offset = 0,
        //    .bytesPerRow = 512,
        //    .rowsPerImage = 512,
        //};
        //const copy_size = c.WGPUExtent3D{ .width = 512, .height = 512, .depthOrArrayLayers = 1 };
        //c.wgpuQueueWriteTexture(queue, &image_copy, &temp_bitmap, temp_bitmap.len, &layout, &copy_size);

        //const tex_view = c.wgpuTextureCreateView(font.texture, null);
        //defer c.wgpuTextureViewRelease(tex_view);

        //// 3. Create Sampler
        //const sampler_desc = c.WGPUSamplerDescriptor{
        //    .nextInChain = null,
        //    .label = empty_label,
        //    .addressModeU = c.WGPUAddressMode_ClampToEdge,
        //    .addressModeV = c.WGPUAddressMode_ClampToEdge,
        //    .addressModeW = c.WGPUAddressMode_ClampToEdge,
        //    .magFilter = c.WGPUFilterMode_Linear,
        //    .minFilter = c.WGPUFilterMode_Linear,
        //    .mipmapFilter = c.WGPUMipmapFilterMode_Linear,
        //    .lodMinClamp = 0.0,
        //    .lodMaxClamp = 32.0,
        //    .compare = c.WGPUCompareFunction_Undefined,
        //    .maxAnisotropy = 1,
        //    // ... leave remaining as 0 / default
        //};
        //const font_sampler = c.wgpuDeviceCreateSampler(device, &sampler_desc);
        //defer c.wgpuSamplerRelease(font_sampler);

        // --- 4. Define the Bind Group Layout (The "Contract") ---
        var bgl_entries = [_]c.WGPUBindGroupLayoutEntry{
            std.mem.zeroes(c.WGPUBindGroupLayoutEntry),
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

        bgl_entries[2].binding = 2;
        bgl_entries[2].visibility = c.WGPUShaderStage_Vertex;
        bgl_entries[2].buffer.type = c.WGPUBufferBindingType_Uniform;
        bgl_entries[2].buffer.minBindingSize = @sizeOf([2]f32);

        const bgl_desc = c.WGPUBindGroupLayoutDescriptor{
            .nextInChain = null,
            .label = empty_label,
            .entryCount = bgl_entries.len,
            .entries = &bgl_entries,
        };
        const bind_group_layout = c.wgpuDeviceCreateBindGroupLayout(device, &bgl_desc);

        // --- 5. Create the Actual Bind Group (The Data) ---
        var bg_entries = [_]c.WGPUBindGroupEntry{
            std.mem.zeroes(c.WGPUBindGroupEntry),
            std.mem.zeroes(c.WGPUBindGroupEntry),
            std.mem.zeroes(c.WGPUBindGroupEntry),
        };

        bg_entries[0].binding = 0;
        bg_entries[0].textureView = font.view;

        bg_entries[1].binding = 1;
        bg_entries[1].sampler = font.sampler;

        bg_entries[2].binding = 2;
        bg_entries[2].buffer = screen_uniform_buf;
        bg_entries[2].offset = 0;
        bg_entries[2].size = @sizeOf([2]f32);

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

        // 4. Pipeline Configuration
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
            .screen_uniform_buf = screen_uniform_buf,
            .bind_group_layout = bind_group_layout,
            .bind_group_layout_3d = undefined,
            .pipeline_3d = undefined,
            .vbo_3d = undefined,
            .num_3d_verts = 0,
            .mvp_uniform_buf = undefined,
            .bind_group_3d = undefined,
            .offscreen_tex = undefined,
            .offscreen_view = undefined,
            .depth_tex = undefined,
            .depth_view = undefined,
            .model_tex = undefined,
            .model_tex_view = undefined,
            .model_sampler = undefined,
        };
    }

    pub fn deinit(self: *Self) void {
        // Replace the entire AppState.deinit function with:
        c.wgpuBufferRelease(self.vbo);
        c.wgpuBufferRelease(self.ibo);
        c.wgpuRenderPipelineRelease(self.pipeline);

        c.wgpuTextureViewRelease(self.font.view);
        c.wgpuSamplerRelease(self.font.sampler);

        if (self.num_3d_verts > 0) {
            c.wgpuRenderPipelineRelease(self.pipeline_3d);
            c.wgpuBufferRelease(self.vbo_3d);
            c.wgpuBufferRelease(self.mvp_uniform_buf);
            c.wgpuBindGroupRelease(self.bind_group_3d);

            c.wgpuTextureViewRelease(self.offscreen_view);
            c.wgpuTextureRelease(self.offscreen_tex.wgpu_tex);
            c.wgpuTextureViewRelease(self.depth_view);
            c.wgpuTextureRelease(self.depth_tex);

            c.wgpuTextureViewRelease(self.model_tex_view);
            c.wgpuTextureRelease(self.model_tex);
            c.wgpuSamplerRelease(self.model_sampler);
            c.wgpuBindGroupLayoutRelease(self.bind_group_layout_3d);
        }

        c.wgpuQueueRelease(self.queue);
        c.wgpuDeviceRelease(self.device);
        c.wgpuAdapterRelease(self.adapter);
        c.wgpuSurfaceRelease(self.surface);
        c.wgpuInstanceRelease(self.instance);
        c.wgpuBindGroupLayoutRelease(self.bind_group_layout);
        c.RGFW_window_close(self.window);
    }

    pub fn configureSurface(self: *Self, width: u32, height: u32) void {
        const surface_config = c.WGPUSurfaceConfiguration{
            .nextInChain = null,
            .device = self.device,
            .format = self.surface_format,
            .usage = c.WGPUTextureUsage_RenderAttachment,
            .width = width,
            .height = height,
            .presentMode = c.WGPUPresentMode_Fifo,
            .alphaMode = c.WGPUCompositeAlphaMode_Auto,
            .viewFormatCount = 0,
            .viewFormats = null,
        };
        c.wgpuSurfaceConfigure(self.surface, &surface_config);

        // Sync the shader uniform with the new dimensions
        const new_size = [2]f32{ @floatFromInt(width), @floatFromInt(height) };
        c.wgpuQueueWriteBuffer(self.queue, self.screen_uniform_buf, 0, &new_size, @sizeOf([2]f32));
    }

    pub fn renderUI(self: *Self, instances: []const InstanceData, draw_cmds: []const DrawCmd) void {
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

        // --- THE SAFE BATCH EXECUTION ---
        for (draw_cmds) |cmd| {
            if (cmd.instance_count > 0) {
                // Swap the texture bind group
                c.wgpuRenderPassEncoderSetBindGroup(pass, 0, cmd.bind_group, 0, null);

                // Use WebGPU's native firstInstance parameter!
                // (Draw 6 vertices, `cmd.instance_count` times, starting at instance `cmd.instance_offset`)
                c.wgpuRenderPassEncoderDraw(pass, 6, cmd.instance_count, 0, cmd.instance_offset);
            }
        }

        c.wgpuRenderPassEncoderEnd(pass);
        c.wgpuRenderPassEncoderRelease(pass);

        const cmd_buf = c.wgpuCommandEncoderFinish(encoder, null);
        c.wgpuQueueSubmit(self.queue, 1, &cmd_buf);
        _ = c.wgpuSurfacePresent(self.surface);
    }

    pub fn loadTexture(self: *Self, file_path: [*c]const u8) !Texture {
        var width: c_int = 0;
        var height: c_int = 0;
        var channels: c_int = 0;

        // 1. Load image via stb_image (Force 4 channels for RGBA)
        const image_data = c.stbi_load(file_path, &width, &height, &channels, 4);
        if (image_data == null) return error.ImageLoadFailed;
        defer c.stbi_image_free(image_data);

        // 2. Create WGPU Texture
        const tex_desc = c.WGPUTextureDescriptor{
            .nextInChain = null,
            .label = .{ .data = null, .length = 0 },

            .usage = c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_CopyDst,
            .dimension = c.WGPUTextureDimension_2D,
            .size = .{ .width = @intCast(width), .height = @intCast(height), .depthOrArrayLayers = 1 },
            .format = c.WGPUTextureFormat_RGBA8Unorm, // Full color!
            .mipLevelCount = 1,
            .sampleCount = 1,
            .viewFormatCount = 0,
            .viewFormats = null,
        };
        const wgpu_tex = c.wgpuDeviceCreateTexture(self.device, &tex_desc);

        // 3. Upload pixels to GPU
        const image_copy = c.WGPUTexelCopyTextureInfo{
            .texture = wgpu_tex,
            .mipLevel = 0,
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .aspect = c.WGPUTextureAspect_All,
        };
        const layout = c.WGPUTexelCopyBufferLayout{
            .offset = 0,
            .bytesPerRow = @as(u32, @intCast(width)) * 4,
            .rowsPerImage = @intCast(height),
        };
        const copy_size = c.WGPUExtent3D{ .width = @intCast(width), .height = @intCast(height), .depthOrArrayLayers = 1 };
        c.wgpuQueueWriteTexture(self.queue, &image_copy, image_data, @as(usize, @intCast(width * height * 4)), &layout, &copy_size);

        // 4. Create View & Sampler
        const tex_view = c.wgpuTextureCreateView(wgpu_tex, null);
        defer c.wgpuTextureViewRelease(tex_view);

        const sampler_desc = c.WGPUSamplerDescriptor{
            .nextInChain = null,
            .label = .{ .data = null, .length = 0 },
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
        };
        const sampler = c.wgpuDeviceCreateSampler(self.device, &sampler_desc);
        defer c.wgpuSamplerRelease(sampler);

        // 5. Create Bind Group
        var bg_entries = [_]c.WGPUBindGroupEntry{
            std.mem.zeroes(c.WGPUBindGroupEntry),
            std.mem.zeroes(c.WGPUBindGroupEntry),
            std.mem.zeroes(c.WGPUBindGroupEntry),
        };

        bg_entries[0].binding = 0;
        bg_entries[0].textureView = tex_view;

        bg_entries[1].binding = 1;
        bg_entries[1].sampler = sampler;

        bg_entries[2].binding = 2;
        bg_entries[2].buffer = self.screen_uniform_buf;
        bg_entries[2].offset = 0;
        bg_entries[2].size = @sizeOf([2]f32);

        const bg_desc = c.WGPUBindGroupDescriptor{
            .nextInChain = null,
            .label = .{ .data = null, .length = 0 },
            .layout = self.bind_group_layout, // Uses the layout we just saved!
            .entryCount = bg_entries.len,
            .entries = &bg_entries,
        };
        const bind_group = c.wgpuDeviceCreateBindGroup(self.device, &bg_desc);

        return Texture{
            .wgpu_tex = wgpu_tex,
            .bind_group = bind_group,
            .width = @intCast(width),
            .height = @intCast(height),
        };
    }

    pub fn init3DPipeline(self: *Self, verts: []Vertex3D, texture_path: ?[]const u8) !void {
        // 1. Create the 3D VBO
        const vbo_desc = c.WGPUBufferDescriptor{
            .nextInChain = null,
            .label = .{ .data = null, .length = 0 },
            .usage = c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_CopyDst,
            .size = verts.len * @sizeOf(Vertex3D),
            .mappedAtCreation = 0,
        };
        self.vbo_3d = c.wgpuDeviceCreateBuffer(self.device, &vbo_desc);
        c.wgpuQueueWriteBuffer(self.queue, self.vbo_3d, 0, verts.ptr, verts.len * @sizeOf(Vertex3D));
        self.num_3d_verts = @intCast(verts.len);

        // 2. 3D MVP Uniform Buffer & Bind Group
        const ubo_desc = c.WGPUBufferDescriptor{
            .nextInChain = null,
            .label = .{ .data = null, .length = 0 },
            .usage = c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst,
            .size = @sizeOf(UniformData),
            .mappedAtCreation = 0,
        };
        self.mvp_uniform_buf = c.wgpuDeviceCreateBuffer(self.device, &ubo_desc);

        // --- 1. LOAD THE TEXTURE VIA STB_IMAGE ---
        var img_w: c_int = 1;
        var img_h: c_int = 1;
        var img_channels: c_int = 4;
        var img_data: [*c]u8 = null;

        // Fallback: A 1x1 solid white pixel if the model has no texture!
        var default_pixel = [_]u8{ 255, 255, 255, 255 };

        if (texture_path) |path| {
            // C-interop requires a null-terminated string
            const null_term_path = try std.heap.page_allocator.dupeZ(u8, path);
            defer std.heap.page_allocator.free(null_term_path);

            img_data = c.stbi_load(null_term_path.ptr, &img_w, &img_h, &img_channels, 4);
        }

        if (img_data == null) {
            img_data = &default_pixel;
            img_w = 1;
            img_h = 1;
        }

        // Upload to WebGPU
        const m_tex_desc = c.WGPUTextureDescriptor{
            .nextInChain = null,
            .label = .{ .data = null, .length = 0 },
            .usage = c.WGPUTextureUsage_CopyDst | c.WGPUTextureUsage_TextureBinding,
            .dimension = c.WGPUTextureDimension_2D,
            .size = .{ .width = @intCast(img_w), .height = @intCast(img_h), .depthOrArrayLayers = 1 },
            .format = c.WGPUTextureFormat_RGBA8Unorm,
            .mipLevelCount = 1,
            .sampleCount = 1,
            .viewFormatCount = 0,
            .viewFormats = null,
        };
        self.model_tex = c.wgpuDeviceCreateTexture(self.device, &m_tex_desc);

        const m_tex_copy = c.WGPUTexelCopyTextureInfo{
            //.nextInChain = null,
            .texture = self.model_tex,
            .mipLevel = 0,
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .aspect = c.WGPUTextureAspect_All,
        };
        const m_layout = c.WGPUTexelCopyBufferLayout{
            //.nextInChain = null,
            .offset = 0,
            .bytesPerRow = @intCast(img_w * 4),
            .rowsPerImage = @intCast(img_h),
        };
        c.wgpuQueueWriteTexture(self.queue, &m_tex_copy, img_data, @intCast(img_w * img_h * 4), &m_layout, &m_tex_desc.size);

        // Free stb memory
        if (img_data != @as([*c]u8, @ptrCast(&default_pixel))) {
            c.stbi_image_free(img_data);
        }
        // ------------------------------------------------------

        self.model_tex_view = c.wgpuTextureCreateView(self.model_tex, null);

        // Create 3D Sampler (Repeat wrapping for 3D UVs!)
        const m_samp_desc = c.WGPUSamplerDescriptor{
            .nextInChain = null,
            .label = .{ .data = null, .length = 0 },
            .addressModeU = c.WGPUAddressMode_Repeat,
            .addressModeV = c.WGPUAddressMode_Repeat,
            .addressModeW = c.WGPUAddressMode_Repeat,
            .magFilter = c.WGPUFilterMode_Linear,
            .minFilter = c.WGPUFilterMode_Linear,
            .mipmapFilter = c.WGPUMipmapFilterMode_Linear,
            .lodMinClamp = 0.0,
            .lodMaxClamp = 32.0,
            .compare = c.WGPUCompareFunction_Undefined,
            .maxAnisotropy = 1,
        };
        self.model_sampler = c.wgpuDeviceCreateSampler(self.device, &m_samp_desc);

        // --- 2. UPDATE BIND GROUP LAYOUT ---
        var bgl_entries_3d = [_]c.WGPUBindGroupLayoutEntry{ std.mem.zeroes(c.WGPUBindGroupLayoutEntry), std.mem.zeroes(c.WGPUBindGroupLayoutEntry), std.mem.zeroes(c.WGPUBindGroupLayoutEntry) };

        // 0: MVP Matrix
        bgl_entries_3d[0].binding = 0;
        bgl_entries_3d[0].visibility = c.WGPUShaderStage_Vertex | c.WGPUShaderStage_Fragment;
        bgl_entries_3d[0].buffer.type = c.WGPUBufferBindingType_Uniform;
        bgl_entries_3d[0].buffer.minBindingSize = @sizeOf(UniformData);
        // 1: Texture
        bgl_entries_3d[1].binding = 1;
        bgl_entries_3d[1].visibility = c.WGPUShaderStage_Fragment;
        bgl_entries_3d[1].texture.sampleType = c.WGPUTextureSampleType_Float;
        bgl_entries_3d[1].texture.viewDimension = c.WGPUTextureViewDimension_2D;
        // 2: Sampler
        bgl_entries_3d[2].binding = 2;
        bgl_entries_3d[2].visibility = c.WGPUShaderStage_Fragment;
        bgl_entries_3d[2].sampler.type = c.WGPUSamplerBindingType_Filtering;

        const bgl_desc_3d = c.WGPUBindGroupLayoutDescriptor{ .nextInChain = null, .label = .{ .data = null, .length = 0 }, .entryCount = 3, .entries = &bgl_entries_3d };
        const bg_layout_3d = c.wgpuDeviceCreateBindGroupLayout(self.device, &bgl_desc_3d);
        self.bind_group_layout_3d = bg_layout_3d;

        // --- 3. CREATE THE BIND GROUP ---
        var bg_entries_3d = [_]c.WGPUBindGroupEntry{ std.mem.zeroes(c.WGPUBindGroupEntry), std.mem.zeroes(c.WGPUBindGroupEntry), std.mem.zeroes(c.WGPUBindGroupEntry) };
        bg_entries_3d[0].binding = 0;
        bg_entries_3d[0].buffer = self.mvp_uniform_buf;
        bg_entries_3d[0].size = @sizeOf(UniformData);
        bg_entries_3d[1].binding = 1;
        bg_entries_3d[1].textureView = self.model_tex_view;
        bg_entries_3d[2].binding = 2;
        bg_entries_3d[2].sampler = self.model_sampler;

        const bg_desc_3d = c.WGPUBindGroupDescriptor{ .nextInChain = null, .label = .{ .data = null, .length = 0 }, .layout = bg_layout_3d, .entryCount = 3, .entries = &bg_entries_3d };
        self.bind_group_3d = c.wgpuDeviceCreateBindGroup(self.device, &bg_desc_3d);

        // 3. Create Offscreen Color Target (400x400)
        const tex_size = 400;
        const color_desc = c.WGPUTextureDescriptor{
            .nextInChain = null,
            .label = .{ .data = null, .length = 0 },
            .usage = c.WGPUTextureUsage_RenderAttachment | c.WGPUTextureUsage_TextureBinding,
            .dimension = c.WGPUTextureDimension_2D,
            .size = .{ .width = tex_size, .height = tex_size, .depthOrArrayLayers = 1 },
            .format = c.WGPUTextureFormat_BGRA8Unorm, // Same as UI surface format
            .mipLevelCount = 1,
            .sampleCount = 1,
            .viewFormatCount = 0,
            .viewFormats = null,
        };
        const offscreen_wgpu_tex = c.wgpuDeviceCreateTexture(self.device, &color_desc);
        self.offscreen_view = c.wgpuTextureCreateView(offscreen_wgpu_tex, null);

        // 4. Create Depth Buffer Target (400x400)
        const depth_desc = c.WGPUTextureDescriptor{
            .nextInChain = null,
            .label = .{ .data = null, .length = 0 },
            .usage = c.WGPUTextureUsage_RenderAttachment,
            .dimension = c.WGPUTextureDimension_2D,
            .size = .{ .width = tex_size, .height = tex_size, .depthOrArrayLayers = 1 },
            .format = c.WGPUTextureFormat_Depth24Plus,
            .mipLevelCount = 1,
            .sampleCount = 1,
            .viewFormatCount = 0,
            .viewFormats = null,
        };
        self.depth_tex = c.wgpuDeviceCreateTexture(self.device, &depth_desc);
        self.depth_view = c.wgpuTextureCreateView(self.depth_tex, null);

        // 5. Wrap the offscreen texture into a UI Bind Group so the UI can draw it!
        const sampler_desc = c.WGPUSamplerDescriptor{
            .nextInChain = null,
            .label = .{ .data = null, .length = 0 },
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
        };
        const sampler = c.wgpuDeviceCreateSampler(self.device, &sampler_desc);

        var ui_bg_entries = [_]c.WGPUBindGroupEntry{ std.mem.zeroes(c.WGPUBindGroupEntry), std.mem.zeroes(c.WGPUBindGroupEntry), std.mem.zeroes(c.WGPUBindGroupEntry) };
        ui_bg_entries[0].binding = 0;
        ui_bg_entries[0].textureView = self.offscreen_view;
        ui_bg_entries[1].binding = 1;
        ui_bg_entries[1].sampler = sampler;
        ui_bg_entries[2].binding = 2;
        ui_bg_entries[2].buffer = self.screen_uniform_buf;
        ui_bg_entries[2].offset = 0;
        ui_bg_entries[2].size = @sizeOf([2]f32);

        const ui_bg_desc = c.WGPUBindGroupDescriptor{
            .nextInChain = null,
            .label = .{ .data = null, .length = 0 },
            .layout = self.bind_group_layout,
            .entryCount = 3,
            .entries = &ui_bg_entries,
        };
        self.offscreen_tex = Texture{
            .wgpu_tex = offscreen_wgpu_tex,
            .bind_group = c.wgpuDeviceCreateBindGroup(self.device, &ui_bg_desc),
            .width = tex_size,
            .height = tex_size,
        };

        // 6. Create the 3D Render Pipeline
        const wgsl_source = c.WGPUShaderSourceWGSL{ .chain = .{ .next = null, .sType = c.WGPUSType_ShaderSourceWGSL }, .code = .{ .data = wgsl_shader_3d.ptr, .length = wgsl_shader_3d.len } };
        const shader_desc = c.WGPUShaderModuleDescriptor{ .nextInChain = @ptrCast(&wgsl_source), .label = .{ .data = null, .length = 0 } };
        const shader = c.wgpuDeviceCreateShaderModule(self.device, &shader_desc);

        const vertex_attributes = [_]c.WGPUVertexAttribute{
            .{ .format = c.WGPUVertexFormat_Float32x3, .offset = @offsetOf(Vertex3D, "position"), .shaderLocation = 0 },
            .{ .format = c.WGPUVertexFormat_Float32x3, .offset = @offsetOf(Vertex3D, "normal"), .shaderLocation = 1 },
            .{ .format = c.WGPUVertexFormat_Float32x2, .offset = @offsetOf(Vertex3D, "uv"), .shaderLocation = 2 },
            .{ .format = c.WGPUVertexFormat_Float32x3, .offset = @offsetOf(Vertex3D, "color"), .shaderLocation = 3 },
        };
        const vbo_layout = c.WGPUVertexBufferLayout{
            .arrayStride = @sizeOf(Vertex3D),
            .stepMode = c.WGPUVertexStepMode_Vertex,
            .attributeCount = 4,
            .attributes = &vertex_attributes,
        };

        const depth_state = c.WGPUDepthStencilState{
            .nextInChain = null,
            .format = c.WGPUTextureFormat_Depth24Plus,
            .depthWriteEnabled = 1,
            .depthCompare = c.WGPUCompareFunction_Less,
            .stencilFront = .{ .compare = c.WGPUCompareFunction_Always, .failOp = c.WGPUStencilOperation_Keep, .depthFailOp = c.WGPUStencilOperation_Keep, .passOp = c.WGPUStencilOperation_Keep },
            .stencilBack = .{ .compare = c.WGPUCompareFunction_Always, .failOp = c.WGPUStencilOperation_Keep, .depthFailOp = c.WGPUStencilOperation_Keep, .passOp = c.WGPUStencilOperation_Keep },
            .stencilReadMask = 0,
            .stencilWriteMask = 0,
            .depthBias = 0,
            .depthBiasSlopeScale = 0.0,
            .depthBiasClamp = 0.0,
        };

        const color_target = c.WGPUColorTargetState{
            .nextInChain = null,
            .format = c.WGPUTextureFormat_BGRA8Unorm,
            .blend = null,
            .writeMask = c.WGPUColorWriteMask_All,
        };
        const fragment_state = c.WGPUFragmentState{ .nextInChain = null, .module = shader, .entryPoint = .{ .data = "fs_main", .length = 7 }, .constantCount = 0, .constants = null, .targetCount = 1, .targets = &color_target };

        const pipeline_layout_desc = c.WGPUPipelineLayoutDescriptor{ .nextInChain = null, .label = .{ .data = null, .length = 0 }, .bindGroupLayoutCount = 1, .bindGroupLayouts = &bg_layout_3d };
        const pipeline_layout = c.wgpuDeviceCreatePipelineLayout(self.device, &pipeline_layout_desc);

        const pipeline_desc = c.WGPURenderPipelineDescriptor{
            .nextInChain = null,
            .label = .{ .data = null, .length = 0 },
            .layout = pipeline_layout,
            .vertex = .{ .nextInChain = null, .module = shader, .entryPoint = .{ .data = "vs_main", .length = 7 }, .constantCount = 0, .constants = null, .bufferCount = 1, .buffers = &vbo_layout },
            .primitive = .{ .nextInChain = null, .topology = c.WGPUPrimitiveTopology_TriangleList, .stripIndexFormat = c.WGPUIndexFormat_Undefined, .frontFace = c.WGPUFrontFace_CCW, .cullMode = c.WGPUCullMode_None },
            .depthStencil = &depth_state,
            .multisample = .{ .nextInChain = null, .count = 1, .mask = 0xFFFFFFFF, .alphaToCoverageEnabled = 0 },
            .fragment = &fragment_state,
        };
        self.pipeline_3d = c.wgpuDeviceCreateRenderPipeline(self.device, &pipeline_desc);
    }

    pub fn render3DModel(self: *Self, yaw: f32, pitch: f32, zoom: f32, light_x: f32, ambient: f32, wobble: f32, time: f32) void {
        // 1. Calculate MVP Math
        const eye_dist: f32 = zoom;
        const eye_x = @sin(yaw) * @cos(pitch) * eye_dist;
        const eye_y = @sin(pitch) * eye_dist;
        const eye_z = @cos(yaw) * @cos(pitch) * eye_dist;

        const view = Math3D.lookAt(.{ eye_x, eye_y, eye_z }, .{ 0.0, 0.0, 0.0 }, .{ 0.0, 1.0, 0.0 });
        const proj = Math3D.perspective(std.math.pi / 4.0, 1.0, 0.1, 100.0);

        const uniform_data = UniformData{
            .mvp = Math3D.mul(proj, view),
            .light_dir = .{ light_x, 1.0, 0.5 }, // We'll just slide the X axis for now!
            .ambient = ambient,
            .wobble_intensity = wobble,
            .time = time,
            .padding = .{ 0.0, 0.0 },
        };
        //const mvp = Math3D.mul(proj, view);

        c.wgpuQueueWriteBuffer(self.queue, self.mvp_uniform_buf, 0, &uniform_data, @sizeOf(UniformData));

        // 2. Begin Offscreen Pass
        const encoder = c.wgpuDeviceCreateCommandEncoder(self.device, null);

        const color_attachment = c.WGPURenderPassColorAttachment{
            .view = self.offscreen_view,
            .loadOp = c.WGPULoadOp_Clear,
            .storeOp = c.WGPUStoreOp_Store,
            .clearValue = .{ .r = 0.05, .g = 0.05, .b = 0.05, .a = 1.0 }, // Dark grey background
            .depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED,
            .resolveTarget = null,
        };

        const depth_attachment = c.WGPURenderPassDepthStencilAttachment{
            .view = self.depth_view,
            .depthLoadOp = c.WGPULoadOp_Clear,
            .depthStoreOp = c.WGPUStoreOp_Store,
            .depthClearValue = 1.0,
            .depthReadOnly = 0,
            .stencilLoadOp = c.WGPULoadOp_Undefined,
            .stencilStoreOp = c.WGPUStoreOp_Undefined,
            .stencilClearValue = 0,
            .stencilReadOnly = 1,
        };

        const pass_desc = c.WGPURenderPassDescriptor{
            .colorAttachmentCount = 1,
            .colorAttachments = &color_attachment,
            .depthStencilAttachment = &depth_attachment,
            .occlusionQuerySet = null,
            .timestampWrites = null,
            .label = .{ .data = null, .length = 0 },
        };
        const pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &pass_desc);

        // 3. Draw!
        c.wgpuRenderPassEncoderSetPipeline(pass, self.pipeline_3d);
        c.wgpuRenderPassEncoderSetBindGroup(pass, 0, self.bind_group_3d, 0, null);
        c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, self.vbo_3d, 0, c.WGPU_WHOLE_SIZE);
        c.wgpuRenderPassEncoderDraw(pass, self.num_3d_verts, 1, 0, 0);

        c.wgpuRenderPassEncoderEnd(pass);
        c.wgpuRenderPassEncoderRelease(pass);

        const cmd_buf = c.wgpuCommandEncoderFinish(encoder, null);
        c.wgpuQueueSubmit(self.queue, 1, &cmd_buf);
        c.wgpuCommandBufferRelease(cmd_buf);
    }

    pub fn swapModel(self: *Self, allocator: std.mem.Allocator, obj_path: [*c]const u8) !void {
        // 1. Load the new file into Zig memory
        const model_data = loadObjFlat(allocator, obj_path) catch |err| {
            std.debug.print("Failed to load {s}: {}\n", .{ obj_path, err });
            return;
        };
        defer allocator.free(model_data.vertices);
        defer if (model_data.texture_path) |p| allocator.free(p);

        // 2. Clean up old GPU buffers! (Crucial to prevent memory leaks)
        c.wgpuBufferRelease(self.vbo_3d);
        c.wgpuTextureViewRelease(self.model_tex_view);
        c.wgpuTextureRelease(self.model_tex);
        c.wgpuSamplerRelease(self.model_sampler);
        c.wgpuBindGroupRelease(self.bind_group_3d);

        // 3. Create new VBO
        const vbo_desc = c.WGPUBufferDescriptor{
            .nextInChain = null,
            .label = .{ .data = null, .length = 0 },
            .usage = c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_CopyDst,
            .size = model_data.vertices.len * @sizeOf(Vertex3D),
            .mappedAtCreation = 0,
        };
        self.vbo_3d = c.wgpuDeviceCreateBuffer(self.device, &vbo_desc);
        c.wgpuQueueWriteBuffer(self.queue, self.vbo_3d, 0, model_data.vertices.ptr, model_data.vertices.len * @sizeOf(Vertex3D));
        self.num_3d_verts = @intCast(model_data.vertices.len);

        // 4. Load new Texture
        var img_w: c_int = 1;
        var img_h: c_int = 1;
        var img_channels: c_int = 4;
        var img_data: [*c]u8 = null;
        var default_pixel = [_]u8{ 255, 255, 255, 255 };

        if (model_data.texture_path) |path| {
            const null_term_path = try std.heap.page_allocator.dupeZ(u8, path);
            defer std.heap.page_allocator.free(null_term_path);
            img_data = c.stbi_load(null_term_path.ptr, &img_w, &img_h, &img_channels, 4);
        }

        if (img_data == null) {
            img_data = &default_pixel;
            img_w = 1;
            img_h = 1;
        }

        const m_tex_desc = c.WGPUTextureDescriptor{
            .nextInChain = null,
            .label = .{ .data = null, .length = 0 },
            .usage = c.WGPUTextureUsage_CopyDst | c.WGPUTextureUsage_TextureBinding,
            .dimension = c.WGPUTextureDimension_2D,
            .size = .{ .width = @intCast(img_w), .height = @intCast(img_h), .depthOrArrayLayers = 1 },
            .format = c.WGPUTextureFormat_RGBA8Unorm,
            .mipLevelCount = 1,
            .sampleCount = 1,
            .viewFormatCount = 0,
            .viewFormats = null,
        };
        self.model_tex = c.wgpuDeviceCreateTexture(self.device, &m_tex_desc);

        // (Note: Adjust WGPUTexelCopy... or WGPUTextureCopy... to match whatever compiled for you earlier!)
        const m_tex_copy = c.WGPUTexelCopyTextureInfo{ .texture = self.model_tex, .mipLevel = 0, .origin = .{ .x = 0, .y = 0, .z = 0 }, .aspect = c.WGPUTextureAspect_All };
        const m_layout = c.WGPUTexelCopyBufferLayout{ .offset = 0, .bytesPerRow = @intCast(img_w * 4), .rowsPerImage = @intCast(img_h) };
        c.wgpuQueueWriteTexture(self.queue, &m_tex_copy, img_data, @intCast(img_w * img_h * 4), &m_layout, &m_tex_desc.size);

        if (img_data != @as([*c]u8, @ptrCast(&default_pixel))) c.stbi_image_free(img_data);

        self.model_tex_view = c.wgpuTextureCreateView(self.model_tex, null);

        const m_samp_desc = c.WGPUSamplerDescriptor{
            .nextInChain = null,
            .label = .{ .data = null, .length = 0 },
            .addressModeU = c.WGPUAddressMode_Repeat,
            .addressModeV = c.WGPUAddressMode_Repeat,
            .addressModeW = c.WGPUAddressMode_Repeat,
            .magFilter = c.WGPUFilterMode_Linear,
            .minFilter = c.WGPUFilterMode_Linear,
            .mipmapFilter = c.WGPUMipmapFilterMode_Linear,
            .lodMinClamp = 0.0,
            .lodMaxClamp = 32.0,
            .compare = c.WGPUCompareFunction_Undefined,
            .maxAnisotropy = 1,
        };
        self.model_sampler = c.wgpuDeviceCreateSampler(self.device, &m_samp_desc);

        // 5. Create new Bind Group using the saved layout!
        var bg_entries_3d = [_]c.WGPUBindGroupEntry{ std.mem.zeroes(c.WGPUBindGroupEntry), std.mem.zeroes(c.WGPUBindGroupEntry), std.mem.zeroes(c.WGPUBindGroupEntry) };
        bg_entries_3d[0].binding = 0;
        bg_entries_3d[0].buffer = self.mvp_uniform_buf;
        bg_entries_3d[0].size = @sizeOf(UniformData);
        bg_entries_3d[1].binding = 1;
        bg_entries_3d[1].textureView = self.model_tex_view;
        bg_entries_3d[2].binding = 2;
        bg_entries_3d[2].sampler = self.model_sampler;

        const bg_desc_3d = c.WGPUBindGroupDescriptor{ .nextInChain = null, .label = .{ .data = null, .length = 0 }, .layout = self.bind_group_layout_3d, .entryCount = 3, .entries = &bg_entries_3d };
        self.bind_group_3d = c.wgpuDeviceCreateBindGroup(self.device, &bg_desc_3d);
    }
};

// ==========================================
// 4. MAIN LOOP
// ==========================================

fn onWindowResize(window: ?*c.RGFW_window, width: c_int, height: c_int) callconv(.c) void {
    // 1. Prevent WebGPU crash on window minimize
    if (width <= 0 or height <= 0) return;

    // 2. Extract our AppContext from the raw C pointer
    const ptr = c.RGFW_window_getUserPtr(window);
    if (ptr == null) return;
    const ctx: *AppContext = @ptrCast(@alignCast(ptr));

    // 3. Update the global dimensions
    ctx.window_width.* = @intCast(width);
    ctx.window_height.* = @intCast(height);

    // 4. Immediately rebuild the surface and force a render!
    ctx.app.configureSurface(ctx.window_width.*, ctx.window_height.*);

    // We pass a hardcoded 1/60th delta-time because the main loop's timer is paused
    renderAppFrame(ctx.app, ctx.ui, ctx.input.*, 0.016, ctx.window_width.*, ctx.window_height.*);
}

fn renderAppFrame(app: *AppState, ui: *UI, input: InputState, dt: f32, window_width: u32, window_height: u32) void {
    for (0..50) |i| {
        const t = @as(f32, @floatFromInt(i)) * 0.2 + (@as(f32, @floatFromInt(counter)) * 0.1);
        my_graph_data[i] = std.math.sin(t) * 50.0 + 50.0;
    }

    ui.beginFrame(dt, input);

    ui.window_width = @floatFromInt(window_width);
    ui.window_height = @floatFromInt(window_height);

    // --- MAIN CONTAINER ---
    var main_panel = ui.pushBox("Container", BoxFlags{ .draw_background = true, .layout_horizontal = false, .scrollable_y = true });
    main_panel.pref_size = .{ .{ .kind = .percent_of_parent, .value = 100.0 }, .{ .kind = .percent_of_parent, .value = 100.0 } };
    main_panel.bg_color = .{ 0.1, 0.1, 0.1, 1.0 };

    main_panel.padding = 20.0;
    main_panel.gap = 10.0;

    var header_box = ui.pushBox("header_panel", BoxFlags{ .draw_background = true });
    header_box.pref_size = .{ .{ .kind = .percent_of_parent, .value = 100.0 }, .{ .kind = .pixels, .value = 80.0 } };
    header_box.bg_color = my_ui_tint; // Bind the background to our dynamic color!
    header_box.corner_radius = 8.0;
    header_box.padding = 10.0;

    ui.label("Zig WebGPU Engine v1.0"); // This text will sit inside the colored header

    // --- FORMAT AND DRAW THE FPS ---
    // Create a tiny 32-byte temporary buffer on the stack
    var fps_buf: [32]u8 = undefined;
    // Format the string, restricting the float to 1 decimal place ({d:.1})
    if (std.fmt.bufPrint(&fps_buf, "FPS: {d:.1}", .{current_fps})) |fps_str| {
        ui.label(fps_str);
    } else |_| {}

    ui.popBox();

    ui.label("Theme Settings:");
    ui.colorPicker("Window Accent Color", &my_ui_tint);

    ui.label("This GUI supports [#FF0000]Colors[/], [#55FF55]Multiple [#5555FF]Tags[/], and [b]Faux Bold Text[/] inline!");

    var counter_buf: [32]u8 = undefined;
    const counter_text = std.fmt.bufPrint(&counter_buf, "Counter: {d}", .{counter}) catch "Counter: Error";

    ui.label(counter_text);
    // --- BUTTON 1 ---
    if (ui.buttonFullWidth("Increment", .{})) {
        counter += 1;
    }

    // --- INVISIBLE SPACER ---
    //var spacer = ui.pushBox("Spacer1", BoxFlags{});
    //spacer.pref_size = .{ .{ .kind = .pixels, .value = 10.0 }, .{ .kind = .pixels, .value = 20.0 } };
    //ui.popBox();

    // --- BUTTON 2 ---
    if (ui.button("Decrement", .{})) {
        counter -= 1;
    }

    //spacer = ui.pushBox("Spacer2", BoxFlags{});
    //spacer.pref_size = .{ .{ .kind = .pixels, .value = 10.0 }, .{ .kind = .pixels, .value = 20.0 } };
    //ui.popBox();

    ui.label("Settings");

    // Checkboxes
    _ = ui.checkbox("Enable VSync", &vsync_enabled);
    _ = ui.checkbox("Show Debug Stats", &show_debug);

    // Spacer
    //spacer = ui.pushBox("Spacer3", BoxFlags{});
    //spacer.pref_size = .{ .{ .kind = .pixels, .value = 10.0 }, .{ .kind = .pixels, .value = 20.0 } };
    //ui.popBox();

    // Radio Buttons
    ui.label("Graphics Quality:");
    _ = ui.radioButton("Low", &graphics_quality, 0);
    _ = ui.radioButton("Medium", &graphics_quality, 1);
    _ = ui.radioButton("Ultra", &graphics_quality, 2);

    //spacer = ui.pushBox("Spacer4", BoxFlags{});
    //spacer.pref_size = .{ .{ .kind = .pixels, .value = 10.0 }, .{ .kind = .pixels, .value = 20.0 } };
    //ui.popBox();

    ui.label("Audio");

    // The Slider!
    _ = ui.slider("Master Volume", &master_volume, 0.0, 1.0);

    //spacer = ui.pushBox("Spacer5", BoxFlags{});
    //spacer.pref_size = .{ .{ .kind = .pixels, .value = 10.0 }, .{ .kind = .pixels, .value = 20.0 } };
    //ui.popBox();

    ui.label("Name:");
    _ = (ui.textInput("name_input", &my_text_buf, &my_text_len));

    _ = (ui.dropdown("Graphics Quality", &dropdown_options, &my_dropdown_index));

    if (image_loaded) {
        // Draw the image at its native resolution!
        ui.image(my_image, @floatFromInt(my_image.width), @floatFromInt(my_image.height));
    } else {
        ui.label("(Image failed to load)");
    }

    ui.label("Performance Graph:");
    ui.graph("my_chart", &my_graph_data, 0.0, 100.0, 500.0, 150.0);

    // Open a floating window at X: 400, Y: 100
    //ui.beginWindow("Inspector", 400.0, 100.0, 700.0, 400.0);

    //ui.label("[b]Floating Tool Palette[/]");

    //if (ui.buttonFullWidth("Reset Settings", .{})) {
    //    master_volume = 0.5;
    //    graphics_quality = 1;
    //    counter = 0;
    //}

    //_ = ui.slider("Volume Override", &master_volume, 0.0, 1.0);

    //ui.endWindow();

    //ui.beginWindow("Debug Stats", 450.0, 150.0, 300.0, 400.0);
    //ui.label("Frames per second: 60");
    //ui.label("Memory usage: 14MB");
    //ui.endWindow();

    //ui.beginWindow("Model Viewer", 100, 100, 400, 400);

    ui.label("Drag to rotate the model or mousewheel to zoom:");

    // The widget displays the render target, and updates our camera variables!
    if (is_3d_ready) {
        ui.modelViewer("obj_view", app.offscreen_tex, 380, 300, &my_camera_yaw, &my_camera_pitch, &my_camera_zoom);
    } else {
        var empty_box = ui.pushBox("empty_viewport", BoxFlags{ .draw_background = true });
        empty_box.pref_size = .{ .{ .kind = .pixels, .value = 400.0 }, .{ .kind = .pixels, .value = 400.0 } };
        empty_box.bg_color = .{ 0.02, 0.02, 0.02, 1.0 }; // Very dark grey

        ui.label("No model loaded.");
        ui.label("Select a file from the list below.");

        ui.popBox();
    }
    ui.label("Environment Controls:");
    _ = ui.slider("Sun X Direction", &my_light_x, -2.0, 2.0);
    _ = ui.slider("Ambient Brightness", &my_ambient, 0.0, 1.0);
    _ = ui.slider("Wobble Modifier", &my_wobble, 0.0, 0.2);
    //ui.endWindow();

    ui.label("Load Model:");

    // 1. The Refresh Button
    if (ui.buttonFullWidth("Scan for New Models", .{})) {
        refreshModelList(ui.allocator);
    }

    // 2. The Dynamic List
    var list_box = ui.pushBox("model_list", BoxFlags{ .scrollable_y = true, .draw_background = true });
    list_box.pref_size = .{ .{ .kind = .percent_of_parent, .value = 100.0 }, .{ .kind = .pixels, .value = 150.0 } };
    list_box.bg_color = .{ 0.05, 0.05, 0.05, 1.0 };
    list_box.padding = 5.0;

    for (available_models.items) |model_path_z| {
        if (ui.buttonFullWidth(model_path_z, .{})) {
            if (!is_3d_ready) {
                // --- FIRST TIME INITIALIZATION ---
                if (loadObjFlat(ui.allocator, model_path_z.ptr)) |model_data| {
                    app.init3DPipeline(model_data.vertices, model_data.texture_path) catch |err| {
                        std.debug.print("Pipeline init failed: {}\n", .{err});
                    };

                    is_3d_ready = true; // Unlock the viewport!

                    if (model_data.texture_path) |path| ui.allocator.free(path);
                    ui.allocator.free(model_data.vertices);
                } else |err| {
                    std.debug.print("Failed to load {s}: {}\n", .{ model_path_z.ptr, err });
                }
            } else {
                // --- SUBSEQUENT HOT-SWAPS ---
                app.swapModel(ui.allocator, model_path_z.ptr) catch |err| {
                    std.debug.print("Swap failed: {}\n", .{err});
                };
            }

            my_camera_zoom = 5.0;
        }
    }
    ui.popBox();

    ui.popBox();

    ui.endFrame(app, @floatFromInt(window_width), @floatFromInt(window_height));
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var app = try AppState.init();
    defer app.deinit();

    if (app.loadTexture("assets/test.png")) |tex| {
        my_image = tex;
        image_loaded = true;
    } else |err| {
        std.debug.print("Failed to load test.png! Error: {}\n", .{err});
    }

    available_models = std.ArrayList([:0]const u8){};
    defer {
        for (available_models.items) |item| gpa.allocator().free(item);
        available_models.deinit(gpa.allocator());
    }
    refreshModelList(gpa.allocator());

    var window_width: u32 = 800;
    var window_height: u32 = 600;
    app.configureSurface(window_width, window_height);

    var ui = try UI.init(gpa.allocator());
    defer ui.deinit();

    // Create a persistent input state outside the loop
    var current_input = InputState{};
    var running = true;

    var ctx = AppContext{
        .app = &app,
        .ui = &ui,
        .input = &current_input,
        .window_width = &window_width,
        .window_height = &window_height,
    };

    c.RGFW_window_setUserPtr(app.window, &ctx);
    _ = c.RGFW_setWindowResizedCallback(onWindowResize);

    try loadMsdfFont(gpa.allocator(), ctx.ui, "assets/font.json");

    var timer = try std.time.Timer.start();
    while (running and c.RGFW_window_shouldClose(app.window) == 0) {
        const elapsed_ns = timer.lap();

        // Convert nanoseconds to seconds (1 billion ns = 1 second)
        const dt = @as(f32, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        // -------------------------

        // --- FPS SMOOTHING CALCULATION ---
        frame_count += 1;
        fps_timer += dt;

        if (fps_timer >= 0.5) {
            current_fps = @as(f32, @floatFromInt(frame_count)) / fps_timer;
            frame_count = 0;
            fps_timer = 0.0;
        }

        // 1. Reset 1-frame input triggers at the start of every frame
        current_input.mouse_left_pressed = false;
        current_input.mouse_left_released = false;
        current_input.scroll_y = 0.0;
        current_input.typed_char = 0;
        current_input.backspace_pressed = false;
        current_input.left_arrow_pressed = false;
        current_input.right_arrow_pressed = false;

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

                    const key = event.key.value;

                    if (key == c.RGFW_shiftL or key == c.RGFW_shiftR) {
                        current_input.shift_pressed = true;
                    } else if (key == c.RGFW_capsLock) {
                        if (builtin.os.tag == .macos) {
                            current_input.caps_lock_active = true;
                        } else {
                            current_input.caps_lock_active = !current_input.caps_lock_active;
                        }
                    } else if (key == c.RGFW_backSpace) {
                        current_input.backspace_pressed = true;
                    } else if (key == c.RGFW_left) {
                        current_input.left_arrow_pressed = true;
                    } else if (key == c.RGFW_right) {
                        current_input.right_arrow_pressed = true;
                    }
                    // Grab basic printable ASCII characters
                    else if (key >= 32 and key <= 126) {
                        var char: u8 = @intCast(key);

                        const uppercase_letter = current_input.shift_pressed != current_input.caps_lock_active;

                        // 1. If RGFW gives us a lowercase letter, capitalize it if Shift is held
                        if (char >= 'a' and char <= 'z') {
                            if (uppercase_letter) {
                                char -= 32;
                            }
                        }
                        // 2. If RGFW gives us an uppercase letter, lowercase it if Shift is NOT held
                        else if (char >= 'A' and char <= 'Z') {
                            if (!uppercase_letter) {
                                char += 32;
                            }
                        }
                        // 3. Handle Numbers and Symbols
                        else if (current_input.shift_pressed) {
                            char = switch (char) {
                                '1' => '!',
                                '2' => '@',
                                '3' => '#',
                                '4' => '$',
                                '5' => '%',
                                '6' => '^',
                                '7' => '&',
                                '8' => '*',
                                '9' => '(',
                                '0' => ')',
                                '-' => '_',
                                '=' => '+',
                                '[' => '{',
                                ']' => '}',
                                '\\' => '|',
                                ';' => ':',
                                '\'' => '"',
                                ',' => '<',
                                '.' => '>',
                                '/' => '?',
                                '`' => '~',
                                else => char,
                            };
                        }

                        current_input.typed_char = char;
                    }
                },
                c.RGFW_keyReleased => {
                    if (event.key.value == c.RGFW_shiftL or event.key.value == c.RGFW_shiftR) {
                        current_input.shift_pressed = false;
                    } else if (event.key.value == c.RGFW_capsLock) {
                        if (builtin.os.tag == .macos) {
                            current_input.caps_lock_active = false;
                        }
                    }
                },
                c.RGFW_mouseScroll => {
                    current_input.scroll_y = event.scroll.y;
                },
                else => {},
            }
        }

        if (!running) break;

        if (is_3d_ready) {
            total_time += dt;
            app.render3DModel(my_camera_yaw, my_camera_pitch, my_camera_zoom, my_light_x, my_ambient, my_wobble, total_time);
        }

        renderAppFrame(&app, &ui, current_input, dt, window_width, window_height);
    }
}

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

const FileContext = struct {
    allocator: std.mem.Allocator,
    file_buffers: std.ArrayList([]u8),
};

// C-ABI compatible callback for tinyobj_loader
fn tinyObjFileReader(ctx_ptr: ?*anyopaque, filename: [*c]const u8, is_mtl: c_int, obj_filename: [*c]const u8, out_buf: [*c][*c]u8, out_len: [*c]usize) callconv(.c) void {
    _ = obj_filename;
    _ = is_mtl;
    var ctx: *FileContext = @ptrCast(@alignCast(ctx_ptr));

    const path_requested = std.mem.span(filename);

    if (std.fs.cwd().readFileAlloc(ctx.allocator, path_requested, 1024 * 1024 * 50)) |file_data| {
        ctx.file_buffers.append(ctx.allocator, file_data) catch {};
        out_buf.* = file_data.ptr;
        out_len.* = file_data.len;
    } else |_| {
        out_buf.* = null;
        out_len.* = 0;
    }
}

pub fn loadObjFlat(allocator: std.mem.Allocator, filepath: [*c]const u8) !ModelData {
    var attrib: c.tinyobj_attrib_t = undefined;
    var shapes: [*c]c.tinyobj_shape_t = null;
    var num_shapes: usize = 0;
    var materials: [*c]c.tinyobj_material_t = null;
    var num_materials: usize = 0;

    var ctx = FileContext{
        .allocator = allocator,
        .file_buffers = std.ArrayList([]u8){},
    };

    // Force the loader to convert quads/n-gons into triangles!
    const flags = c.TINYOBJ_FLAG_TRIANGULATE;

    const ret = c.tinyobj_parse_obj(
        &attrib,
        &shapes,
        &num_shapes,
        &materials,
        &num_materials,
        filepath,
        tinyObjFileReader,
        &ctx,
        flags,
    );

    // Free the raw text buffer we allocated in the callback
    defer {
        for (ctx.file_buffers.items) |buf| allocator.free(buf);
        ctx.file_buffers.deinit(ctx.allocator);
    }

    if (ret != c.TINYOBJ_SUCCESS) {
        return error.ObjParseFailed;
    }

    // --- EXTRACT THE TEXTURE PATH ---
    var found_tex_path: ?[]u8 = null;

    // Scan the parsed materials for the first diffuse texture it finds
    if (materials != null and num_materials > 0) {
        for (0..num_materials) |m_i| {
            if (materials[m_i].diffuse_texname != null) {
                const tex_slice = std.mem.span(materials[m_i].diffuse_texname);
                const obj_path_slice = std.mem.span(filepath);

                // --- JOIN THE DIRECTORY WITH THE TEXTURE NAME ---
                if (std.fs.path.dirname(obj_path_slice)) |dir| {
                    found_tex_path = std.fs.path.join(allocator, &[_][]const u8{ dir, tex_slice }) catch null;
                } else {
                    found_tex_path = allocator.dupe(u8, tex_slice) catch null;
                }
                // ------------------------------------------------

                break;
            }
        }
    }

    // Free the C-allocations made by tinyobj_loader internally
    defer c.tinyobj_attrib_free(&attrib);
    defer c.tinyobj_shapes_free(shapes, num_shapes);
    defer c.tinyobj_materials_free(materials, num_materials);

    var vertices = std.ArrayList(Vertex3D){};
    errdefer vertices.deinit(allocator);

    // --- UNROLL THE VERTICES ---
    // attrib.num_faces represents the total number of index triplets.
    // --- UNROLL THE VERTICES ---
    for (0..attrib.num_faces) |i| {
        const idx = attrib.faces[i];

        // 1. FETCH MATERIAL COLOR
        const mat_id = attrib.material_ids[i / 3];
        var face_color = [3]f32{ 0.8, 0.8, 0.8 }; // Default to light grey

        // If the face has a valid material, read its diffuse color!
        if (mat_id >= 0 and materials != null) {
            const mat = materials[@intCast(mat_id)];
            face_color[0] = mat.diffuse[0];
            face_color[1] = mat.diffuse[1];
            face_color[2] = mat.diffuse[2];
        }

        var v = Vertex3D{
            .position = .{ 0.0, 0.0, 0.0 },
            .normal = .{ 0.0, 1.0, 0.0 },
            .uv = .{ 0.0, 0.0 },
            .color = face_color, // Assign it here!
        };

        // 1. Extract Position
        if (idx.v_idx >= 0) {
            const v_offset = @as(usize, @intCast(idx.v_idx)) * 3;
            v.position[0] = attrib.vertices[v_offset + 0];
            v.position[1] = attrib.vertices[v_offset + 1];
            v.position[2] = attrib.vertices[v_offset + 2];
        }

        // 2. Extract Normal
        if (idx.vn_idx >= 0) {
            const vn_offset = @as(usize, @intCast(idx.vn_idx)) * 3;
            v.normal[0] = attrib.normals[vn_offset + 0];
            v.normal[1] = attrib.normals[vn_offset + 1];
            v.normal[2] = attrib.normals[vn_offset + 2];
        }

        // 3. Extract UV (and flip V axis for WebGPU)
        if (idx.vt_idx >= 0) {
            const vt_offset = @as(usize, @intCast(idx.vt_idx)) * 2;
            v.uv[0] = attrib.texcoords[vt_offset + 0];
            v.uv[1] = 1.0 - attrib.texcoords[vt_offset + 1];
        }

        try vertices.append(allocator, v);
    }

    return ModelData{ .vertices = try vertices.toOwnedSlice(allocator), .texture_path = found_tex_path };
}

pub fn refreshModelList(allocator: std.mem.Allocator) void {
    // Clear out the old list if we are refreshing
    for (available_models.items) |item| allocator.free(item);
    available_models.clearRetainingCapacity();

    // Open the current working directory as an iterable
    var dir = std.fs.cwd().openDir("assets", .{ .iterate = true }) catch return;
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        // Is it a file, and does it end with .obj?
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".obj")) {
            // Duplicate the string as a null-terminated Z-string for C-interop!
            if (std.fs.path.joinZ(allocator, &[_][]const u8{ "assets", entry.name })) |full_path| {
                available_models.append(allocator, full_path) catch {};
            } else |_| {}
        }
    }
}

pub fn loadMsdfFont(allocator: std.mem.Allocator, ui: *UI, json_path: []const u8) !void {
    // 1. Read the JSON file
    const file_data = try std.fs.cwd().readFileAlloc(allocator, json_path, 1024 * 1024 * 5);
    defer allocator.free(file_data);

    // 2. Parse the JSON directly into our Structs!
    const parsed = try std.json.parseFromSlice(BMFont, allocator, file_data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // 3. Populate the hash map for O(1) character lookups
    ui.font_map = std.AutoHashMap(u32, BMFontChar).init(allocator);
    ui.font_metrics = parsed.value.common;

    for (parsed.value.chars) |char| {
        try ui.font_map.put(char.id, char);
    }

    std.debug.print("Successfully loaded MSDF font with {} glyphs.\n", .{ui.font_map.count()});
}
