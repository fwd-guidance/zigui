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

var counter: i32 = 0;
var vsync_enabled: bool = true;
var show_debug: bool = false;
var graphics_quality: usize = 1; // 0=Low, 1=Medium, 2=High
var master_volume: f32 = 0.5;

pub const Rect = struct {
    pos: [2]f32 = .{ 0.0, 0.0 },
    size: [2]f32 = .{ 0.0, 0.0 },
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

    scroll_y: f32 = 0.0,
};

pub const Font = struct {
    cdata: [96]c.stbtt_bakedchar, // ASCII characters 32 through 126
    texture: c.WGPUTexture,
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

    root: ?*Box = null,
    parent_stack: [64]*Box = undefined,
    parent_stack_top: usize = 0,

    input: InputState = .{},
    current_frame_index: u64 = 0,

    hot_hash_this_frame: u64 = 0,
    active_hash: u64 = 0,

    layout_cache: std.AutoHashMap(u64, [4]f32),
    scroll_state: std.AutoHashMap(u64, [2]f32),

    pub fn init(allocator: std.mem.Allocator) !UI {
        return UI{
            .allocator = allocator,
            .frame_arena = std.heap.ArenaAllocator.init(allocator),
            .retained_state = std.AutoHashMap(u64, BoxState).init(allocator),
            .layout_cache = std.AutoHashMap(u64, [4]f32).init(allocator),
            .scroll_state = std.AutoHashMap(u64, [2]f32).init(allocator),
        };
    }

    pub fn deinit(self: *UI) void {
        self.retained_state.deinit();
        self.frame_arena.deinit();
        self.layout_cache.deinit();
        self.scroll_state.deinit();
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
        }
        return box;
    }

    pub fn popBox(self: *UI) void {
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

            self.buildRenderCommands(root, &instances, &app.font);
            app.renderUI(instances.items);
        }
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
            if (self.layout_cache.get(node.hash)) |rect| {
                const mx = self.input.mouse_x;
                const my = self.input.mouse_y;
                if (mx >= rect[0] and mx <= rect[0] + rect[2] and my >= rect[1] and my <= rect[1] + rect[3]) {
                    scroll_offset -= self.input.scroll_y * 20.0;
                }
            }

            // CLAMP IMMEDIATELY! (Using last frame's content height)
            const max_scroll = @max(0.0, prev_content_height - (node.rect.size[1] - (node.padding * 2.0)));
            scroll_offset = @max(0.0, @min(max_scroll, scroll_offset));
        }

        // --- 3. APPLY THE OFFSET ---
        var cursor_x = node.rect.pos[0] + node.padding;
        var cursor_y = node.rect.pos[1] + node.padding - scroll_offset;

        // Start the layout cursor at the top-left, inset by padding
        //var cursor_x = node.rect.pos[0] + node.padding;

        //// --- 1. HANDLE SCROLL STATE ---
        //var scroll_offset: f32 = 0.0;
        //if (node.flags.scrollable_y) {
        //    scroll_offset = self.scroll_state.get(node.hash) orelse 0.0;

        //    // Read input if the mouse is hovering inside this specific container
        //    if (self.layout_cache.get(node.hash)) |rect| {
        //        const mx = self.input.mouse_x;
        //        const my = self.input.mouse_y;
        //        if (mx >= rect[0] and mx <= rect[0] + rect[2] and my >= rect[1] and my <= rect[1] + rect[3]) {
        //            // Multiply by 20.0 for scroll speed. Adjust to your liking!
        //            scroll_offset -= self.input.scroll_y * 20.0;
        //        }
        //    }
        //}

        //var cursor_y = node.rect.pos[1] + node.padding - scroll_offset;

        var child_it = node.first;
        while (child_it) |child| : (child_it = child.next) {

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

            //self.layout_cache.put(child.hash, .{ child.rect.pos[0], child.rect.pos[1], child.calculated_size[0], child.calculated_size[1] }) catch {};

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
        }

        // --- 3. CLAMP AND SAVE SCROLL ---
        //if (node.flags.scrollable_y) {
        //    // How far down did the cursor go?
        //    const content_height = (cursor_y + scroll_offset) - (node.rect.pos[1] + node.padding);

        //    // The maximum amount we are allowed to scroll
        //    const max_scroll = @max(0.0, content_height - (node.rect.size[1] - (node.padding * 2.0)));

        //    // Clamp and save
        //    scroll_offset = @max(0.0, @min(max_scroll, scroll_offset));
        //    self.scroll_state.put(node.hash, scroll_offset) catch {};
        //}

        if (node.flags.scrollable_y) {
            // Calculate actual content height based on where the cursor ended up
            const content_height = (cursor_y + scroll_offset) - (node.rect.pos[1] + node.padding);

            // Save both the offset and the new height to the map
            self.scroll_state.put(node.hash, .{ scroll_offset, content_height }) catch {};
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

        // Draw Text
        if (node.text.len > 0) {
            // 1. Measure the exact pixel width of the string
            var text_width: f32 = 0.0;
            var dummy_y: f32 = 0.0;
            for (node.text) |char| {
                if (char >= 32 and char < 128) {
                    var q: c.stbtt_aligned_quad = undefined;
                    // We just use this to advance the text_width variable
                    c.stbtt_GetBakedQuad(&font.cdata, 512, 512, @intCast(char - 32), &text_width, &dummy_y, &q, 1);
                }
            }

            // 2. Calculate the starting X position based on alignment
            var cursor_x: f32 = node.rect.pos[0];
            switch (node.text_align) {
                .center => cursor_x += (node.rect.size[0] - text_width) / 2.0,
                .right => cursor_x += (node.rect.size[0] - text_width) - node.padding,
                .left => cursor_x += node.padding, // Add a little padding so it doesn't touch the left wall
            }

            // 3. Center the text vertically
            // (Assuming a ~32px font, the baseline is usually offset down by about a quarter of the line height)
            var cursor_y = node.rect.pos[1] + (node.rect.size[1] / 2.0) + 8.0;

            // 4. Actually draw the quads
            for (node.text) |char| {
                if (char >= 32 and char < 128) {
                    var q: c.stbtt_aligned_quad = undefined;
                    c.stbtt_GetBakedQuad(&font.cdata, 512, 512, @intCast(char - 32), &cursor_x, &cursor_y, &q, 1);

                    instances.append(self.allocator, InstanceData{
                        .rect_pos = .{ q.x0, q.y0 },
                        .rect_size = .{ q.x1 - q.x0, q.y1 - q.y0 },
                        .color = .{ 1.0, 1.0, 1.0, 1.0 }, // White text
                        .clip_rect = node.clip_rect,
                        .corner_radius = 0.0,
                        .edge_softness = 0.0,
                        .type_flag = 1,
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

    pub fn label(self: *UI, text: []const u8) void {
        var box = self.pushBox(text, BoxFlags{}); // No background, not clickable
        box.text = text;

        // Optional: Force the box size to wrap the text somewhat tightly
        // (In a full engine, you'd calculate this exactly using the STB font metrics)
        box.pref_size = .{ .{ .kind = .pixels, .value = @as(f32, @floatFromInt(text.len)) * 16.0 }, .{ .kind = .pixels, .value = 32.0 } };

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
    screen_uniform_buf: c.WGPUBuffer,

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
        defer c.wgpuBindGroupLayoutRelease(bind_group_layout);

        // --- 5. Create the Actual Bind Group (The Data) ---
        var bg_entries = [_]c.WGPUBindGroupEntry{
            std.mem.zeroes(c.WGPUBindGroupEntry),
            std.mem.zeroes(c.WGPUBindGroupEntry),
            std.mem.zeroes(c.WGPUBindGroupEntry),
        };

        bg_entries[0].binding = 0;
        bg_entries[0].textureView = tex_view;

        bg_entries[1].binding = 1;
        bg_entries[1].sampler = font_sampler;

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
        };
    }

    pub fn deinit(self: *Self) void {
        // Replace the entire AppState.deinit function with:
        c.wgpuBufferRelease(self.vbo);
        c.wgpuBufferRelease(self.ibo);
        c.wgpuRenderPipelineRelease(self.pipeline);

        c.wgpuQueueRelease(self.queue);
        c.wgpuDeviceRelease(self.device);
        c.wgpuAdapterRelease(self.adapter);
        c.wgpuSurfaceRelease(self.surface);
        c.wgpuInstanceRelease(self.instance);
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
    ui.beginFrame(dt, input);

    // --- MAIN CONTAINER ---
    var main_panel = ui.pushBox("Container", BoxFlags{ .draw_background = true, .layout_horizontal = false, .scrollable_y = true });
    main_panel.pref_size = .{ .{ .kind = .percent_of_parent, .value = 100.0 }, .{ .kind = .percent_of_parent, .value = 100.0 } };
    main_panel.bg_color = .{ 0.1, 0.1, 0.1, 1.0 };

    main_panel.padding = 20.0;
    main_panel.gap = 10.0;

    var counter_buf: [32]u8 = undefined;
    const counter_text = std.fmt.bufPrint(&counter_buf, "Counter: {d}", .{counter}) catch "Counter: Error";

    ui.label(counter_text);
    // --- BUTTON 1 ---
    if (ui.buttonFullWidth("Increment", .{})) {
        counter += 1;
    }

    // --- INVISIBLE SPACER ---
    var spacer = ui.pushBox("Spacer1", BoxFlags{});
    spacer.pref_size = .{ .{ .kind = .pixels, .value = 10.0 }, .{ .kind = .pixels, .value = 20.0 } };
    ui.popBox();

    // --- BUTTON 2 ---
    if (ui.button("Decrement", .{})) {
        counter -= 1;
    }

    spacer = ui.pushBox("Spacer2", BoxFlags{});
    spacer.pref_size = .{ .{ .kind = .pixels, .value = 10.0 }, .{ .kind = .pixels, .value = 20.0 } };
    ui.popBox();

    ui.label("Settings");

    // Checkboxes
    _ = ui.checkbox("Enable VSync", &vsync_enabled);
    _ = ui.checkbox("Show Debug Stats", &show_debug);

    // Spacer
    spacer = ui.pushBox("Spacer3", BoxFlags{});
    spacer.pref_size = .{ .{ .kind = .pixels, .value = 10.0 }, .{ .kind = .pixels, .value = 20.0 } };
    ui.popBox();

    // Radio Buttons
    ui.label("Graphics Quality:");
    _ = ui.radioButton("Low", &graphics_quality, 0);
    _ = ui.radioButton("Medium", &graphics_quality, 1);
    _ = ui.radioButton("Ultra", &graphics_quality, 2);

    spacer = ui.pushBox("Spacer4", BoxFlags{});
    spacer.pref_size = .{ .{ .kind = .pixels, .value = 10.0 }, .{ .kind = .pixels, .value = 20.0 } };
    ui.popBox();

    ui.label("Audio");

    // The Slider!
    if (ui.slider("Master Volume", &master_volume, 0.0, 1.0)) {
        // This block fires every frame the value is actively changing
        // You can use this to update your audio engine in real-time
        //std.debug.print("Volume changed to: {d:.2}\n", .{master_volume});

    }

    ui.popBox();

    ui.endFrame(app, @floatFromInt(window_width), @floatFromInt(window_height));
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var app = try AppState.init();
    defer app.deinit();

    var window_width: u32 = 800;
    var window_height: u32 = 600;
    app.configureSurface(window_width, window_height);

    var ui = try UI.init(gpa.allocator());
    defer ui.deinit();

    const dt: f32 = 0.008; // Simulate 60fps for example

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

    while (running and c.RGFW_window_shouldClose(app.window) == 0) {
        // 1. Reset 1-frame input triggers at the start of every frame
        current_input.mouse_left_pressed = false;
        current_input.mouse_left_released = false;
        current_input.scroll_y = 0.0;

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
                c.RGFW_mouseScroll => {
                    current_input.scroll_y = event.scroll.y;
                },
                else => {},
            }
        }

        if (!running) break;

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
