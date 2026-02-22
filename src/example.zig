const std = @import("std");

const c = @cImport({
    @cDefine("RGFW_WEBGPU", {});
    @cInclude("RGFW.h");
    @cInclude("webgpu/webgpu.h");
});

const AppState = struct {
    window: ?*c.RGFW_window,
    instance: c.WGPUInstance,
    surface: c.WGPUSurface,
    adapter: c.WGPUAdapter,
    device: c.WGPUDevice,
    queue: c.WGPUQueue,
    surface_format: c.WGPUTextureFormat,
    clear_color: [3]f32,

    const Self = @This();

    pub fn init() !Self {
        const window = c.RGFW_createWindow(
            "title",
            100,
            100,
            800,
            600,
            0,
        );
        if (window == null) return error.WindowCreationFailed;

        // Process initial events
        var event: c.RGFW_event = undefined;
        while (c.RGFW_window_checkEvent(window, &event) != 0) {}

        const instance = c.wgpuCreateInstance(null);
        if (instance == null) return error.NoInstance;

        const surface = c.RGFW_window_createSurface_WebGPU(window, instance);
        if (surface == null) return error.NoSurface;

        const adapter = requestAdapter(instance, surface);
        if (adapter == null) return error.NoAdapter;

        const device = requestDevice(adapter);
        if (device == null) return error.NoDevice;

        const queue = c.wgpuDeviceGetQueue(device);

        // Get surface format
        var caps: c.WGPUSurfaceCapabilities = undefined;
        _ = c.wgpuSurfaceGetCapabilities(surface, adapter, &caps);
        defer c.wgpuSurfaceCapabilitiesFreeMembers(caps);

        const surface_format = if (caps.formatCount > 0)
            caps.formats[0]
        else
            c.WGPUTextureFormat_BGRA8Unorm;

        return Self{
            .window = window,
            .instance = instance,
            .surface = surface,
            .adapter = adapter,
            .device = device,
            .queue = queue,
            .surface_format = surface_format,
            .clear_color = [3]f32{ 1.0, 0.0, 0.0 }, // Start with red
        };
    }

    pub fn deinit(self: *Self) void {
        c.wgpuQueueRelease(self.queue);
        c.wgpuDeviceRelease(self.device);
        c.wgpuAdapterRelease(self.adapter);
        c.wgpuSurfaceRelease(self.surface);
        c.wgpuInstanceRelease(self.instance);
        c.RGFW_window_close(self.window);
    }

    pub fn configureSurface(self: *Self) void {
        const surface_config = c.WGPUSurfaceConfiguration{
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

    pub fn handleInput(self: *Self) bool {
        var event: c.RGFW_event = undefined;
        const step: f32 = 0.05;

        while (c.RGFW_window_checkEvent(self.window, &event) != 0) {
            if (event.type == c.RGFW_keyPressed) {
                switch (event.key.value) {
                    c.RGFW_escape => c.RGFW_window_setShouldClose(self.window, 1),
                    'q', 'Q' => {
                        self.clear_color[0] = @min(1.0, self.clear_color[0] + step);
                        std.debug.print("Red: {d:.2}\n", .{self.clear_color[0]});
                    },
                    'a', 'A' => {
                        self.clear_color[0] = @max(0.0, self.clear_color[0] - step);
                        std.debug.print("Red: {d:.2}\n", .{self.clear_color[0]});
                    },
                    'w', 'W' => {
                        self.clear_color[1] = @min(1.0, self.clear_color[1] + step);
                        std.debug.print("Green: {d:.2}\n", .{self.clear_color[1]});
                    },
                    's', 'S' => {
                        self.clear_color[1] = @max(0.0, self.clear_color[1] - step);
                        std.debug.print("Green: {d:.2}\n", .{self.clear_color[1]});
                    },
                    'e', 'E' => {
                        self.clear_color[2] = @min(1.0, self.clear_color[2] + step);
                        std.debug.print("Blue: {d:.2}\n", .{self.clear_color[2]});
                    },
                    'd', 'D' => {
                        self.clear_color[2] = @max(0.0, self.clear_color[2] - step);
                        std.debug.print("Blue: {d:.2}\n", .{self.clear_color[2]});
                    },
                    else => {},
                }
            }
        }

        return c.RGFW_window_shouldClose(self.window) == 0;
    }

    pub fn render(self: *Self) void {
        var surface_texture: c.WGPUSurfaceTexture = undefined;
        c.wgpuSurfaceGetCurrentTexture(self.surface, &surface_texture);

        if (surface_texture.texture == null) return;

        const texture_view = c.wgpuTextureCreateView(surface_texture.texture, null);
        defer {
            c.wgpuTextureViewRelease(texture_view);
            c.wgpuTextureRelease(surface_texture.texture);
        }

        const encoder = c.wgpuDeviceCreateCommandEncoder(self.device, null);
        defer c.wgpuCommandEncoderRelease(encoder);

        const color_attachment = c.WGPURenderPassColorAttachment{
            .view = texture_view,
            .loadOp = c.WGPULoadOp_Clear,
            .storeOp = c.WGPUStoreOp_Store,
            .clearValue = .{
                .r = self.clear_color[0],
                .g = self.clear_color[1],
                .b = self.clear_color[2],
                .a = 1.0,
            },
            .depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED,
            .resolveTarget = null,
        };

        const empty_label = c.WGPUStringView{
            .data = null,
            .length = 0,
        };

        const render_pass_desc = c.WGPURenderPassDescriptor{
            .colorAttachmentCount = 1,
            .colorAttachments = &color_attachment,
            .depthStencilAttachment = null,
            .occlusionQuerySet = null,
            .timestampWrites = null,
            .label = empty_label,
        };

        const render_pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &render_pass_desc);
        c.wgpuRenderPassEncoderEnd(render_pass);
        c.wgpuRenderPassEncoderRelease(render_pass);

        const command_buffer = c.wgpuCommandEncoderFinish(encoder, null);
        defer c.wgpuCommandBufferRelease(command_buffer);

        c.wgpuQueueSubmit(self.queue, 1, &command_buffer);
        _ = c.wgpuSurfacePresent(self.surface);
    }
};

pub fn main() !void {
    var app = try AppState.init();
    defer app.deinit();

    app.configureSurface();

    std.debug.print("Controls:\n", .{});
    std.debug.print("  Q/A - Red up/down\n", .{});
    std.debug.print("  W/S - Green up/down\n", .{});
    std.debug.print("  E/D - Blue up/down\n", .{});

    while (app.handleInput()) {
        app.render();
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
