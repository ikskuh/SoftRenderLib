const std = @import("std");
const SDL = @import("sdl2");
const zgl = @import("zgl");

const rasterizer = @import("rasterizer.zig");

const quality: Quality = .fast;
const multithreading: ?comptime_int = 8;

const level_file = "assets/terrain";

const DepthType = u32;

const PixelType = u8;

const screen = struct {
    const scaler = 1;
    const width = 800;
    const height = 480;
};
var palette: [256]u32 = undefined;

var exampleTex: rasterizer.Texture(PixelType) = undefined;

pub fn gameMain() !void {
    try SDL.init(.{
        .video = true,
        .events = true,
        .audio = true,
    });
    defer SDL.quit();

    var window = try SDL.createWindow(
        "SoftRender: Triangle",
        .{ .centered = {} },
        .{ .centered = {} },
        screen.scaler * screen.width,
        screen.scaler * screen.height,
        .{ .shown = true },
    );
    defer window.destroy();

    var renderer = try SDL.createRenderer(window, null, .{ .accelerated = true, .presentVSync = true });
    defer renderer.destroy();

    var texture = try SDL.createTexture(renderer, .rgbx8888, .streaming, screen.width, screen.height);
    defer texture.destroy();

    // initialized by https://lospec.com/palette-list/dawnbringer-16
    palette[0] = 0x140c1cFF; // black
    palette[1] = 0x442434FF; // dark purple
    palette[2] = 0x30346dFF; // blue
    palette[3] = 0x4e4a4eFF; // gray
    palette[4] = 0x854c30FF; // brown
    palette[5] = 0x346524FF; // green
    palette[6] = 0xd04648FF; // tomato
    palette[7] = 0x757161FF; // khaki
    palette[8] = 0x597dceFF; // baby blue
    palette[9] = 0xd27d2cFF; // orange
    palette[10] = 0x8595a1FF; // silver
    palette[11] = 0x6daa2cFF; // lime
    palette[12] = 0xd2aa99FF; // skin
    palette[13] = 0x6dc2caFF; // sky
    palette[14] = 0xdad45eFF; // piss
    palette[15] = 0xdeeed6FF; // white

    {
        var file = try std.fs.cwd().openRead(level_file ++ ".pcx");
        defer file.close();

        var img = try zgl.pcx.load(std.heap.c_allocator, &file);
        errdefer img.deinit();

        if (img == .bpp8) {
            exampleTex.width = img.bpp8.width;
            exampleTex.height = img.bpp8.height;
            exampleTex.pixels = img.bpp8.pixels;
            if (img.bpp8.palette) |pal| {
                for (palette) |*col, i| {
                    const RGBA = packed struct {
                        x: u8 = 0,
                        b: u8,
                        g: u8,
                        r: u8,
                    };
                    var c: RGBA = .{
                        .r = pal[i].r,
                        .g = pal[i].g,
                        .b = pal[i].b,
                    };

                    col.* = @bitCast(u32, c);
                }
            }
        } else {
            img.deinit();
            return error.InvalidTexture;
        }
    }

    var model = try zgl.wavefrontObj.load(std.heap.c_allocator, level_file ++ ".obj");

    std.debug.warn("model size: {}\n", .{model.faces.len});

    var bestTime: f64 = 10000;
    var worstTime: f64 = 0;
    var totalTime: f64 = 0;
    var totalFrames: f64 = 0;

    var perfStats: [256]f64 = [_]f64{0} ** 256;
    var perfPtr: u8 = 0;

    const Camera = struct {
        pan: f32,
        tilt: f32,
        position: zgl.math3d.Vec3,
    };

    var camera: Camera = .{
        .pan = 0,
        .tilt = 0,
        .position = .{ .x = 0, .y = 0, .z = 0 },
    };

    var backBuffer = try rasterizer.Texture(u8).init(std.heap.c_allocator, screen.width, screen.height);
    defer backBuffer.deinit();

    var depthBuffer = try rasterizer.Texture(u32).init(std.heap.c_allocator, screen.width, screen.height);
    defer depthBuffer.deinit();

    const Context = rasterizer.Context(u8, .beautiful, null);

    // a bit weird construct, but this is required because
    // result location isn't working right yet.
    var softwareRenderer: Context = undefined;
    try softwareRenderer.init();
    defer softwareRenderer.deinit();

    try softwareRenderer.setRenderTarget(&backBuffer, &depthBuffer);

    var fcount: usize = 0;
    mainLoop: while (true) : (fcount += 1) {
        while (SDL.pollEvent()) |ev| {
            switch (ev) {
                .quit => {
                    break :mainLoop;
                },
                .keyDown => |key| {
                    switch (key.keysym.scancode) {
                        .SDL_SCANCODE_ESCAPE => break :mainLoop,
                        else => std.debug.warn("key pressed: {}\n", .{key.keysym.scancode}),
                    }
                },

                else => {},
            }
        }

        const kbd = SDL.getKeyboardState();

        var speed = if (kbd.isPressed(.SDL_SCANCODE_LSHIFT)) @as(f32, 100.0) else @as(f32, 1);

        if (kbd.isPressed(.SDL_SCANCODE_LEFT))
            camera.pan += 0.015;
        if (kbd.isPressed(.SDL_SCANCODE_RIGHT))
            camera.pan -= 0.015;
        if (kbd.isPressed(.SDL_SCANCODE_PAGEUP))
            camera.tilt += 0.015;
        if (kbd.isPressed(.SDL_SCANCODE_PAGEDOWN))
            camera.tilt -= 0.015;

        const camdir = angleToVec3(camera.pan, camera.tilt);

        if (kbd.isPressed(.SDL_SCANCODE_UP))
            camera.position = camera.position.add(camdir.scale(speed * 0.01));
        if (kbd.isPressed(.SDL_SCANCODE_DOWN))
            camera.position = camera.position.add(camdir.scale(speed * -0.01));

        const angle = 0.0007 * @intToFloat(f32, SDL.getTicks());

        backBuffer.fill(0); // Fill with "background/transparent"

        depthBuffer.fill(std.math.maxInt(u32));

        const persp = zgl.math3d.Mat4.createPerspective(
            60.0 * std.math.tau / 360.0,
            4.0 / 3.0,
            0.01,
            10000.0,
        );

        const view = zgl.math3d.Mat4.createLookAt(camera.position, camera.position.add(camdir), zgl.math3d.Vec3.unitY);

        var timer = try std.time.Timer.start();

        var visible_polycount: usize = 0;
        var total_polycount: usize = 0;

        {
            softwareRenderer.beginFrame();

            defer softwareRenderer.endFrame();

            const world = zgl.math3d.Mat4.identity; // (5.0 * worldX, 0.0, 5.0 * worldZ); // createAngleAxis(.{ .x = 0, .y = 1, .z = 0 }, angle);

            const mvp = world.mul(view).mul(persp);

            const faces = model.faces.toSliceConst();
            const positions = model.positions.toSliceConst();
            const uvCoords = model.textureCoordinates.toSliceConst();

            for (model.objects.toSliceConst()) |obj| {
                var i: usize = 0;
                face: while (i < obj.count) : (i += 1) {
                    const src_face = faces[obj.start + i];
                    if (src_face.count != 3)
                        continue;

                    total_polycount += 1;

                    var face = rasterizer.Face(u8){
                        .vertices = undefined,
                        .texture = &exampleTex,
                    };
                    for (face.vertices) |*vert, j| {
                        const vtx = src_face.vertices[j];

                        const local_pos = positions[vtx.position];

                        var screen_pos = local_pos.swizzle("xyz1").transform(mvp);
                        if (std.math.fabs(screen_pos.w) <= 1e-9)
                            continue :face;

                        var linear_screen_pos = screen_pos.swizzle("xyz").scale(1.0 / screen_pos.w);

                        if (screen_pos.w < 0)
                            continue :face;
                        if (std.math.fabs(linear_screen_pos.x) > 3.0)
                            continue :face;
                        if (std.math.fabs(linear_screen_pos.y) > 3.0)
                            continue :face;

                        // std.debug.warn("{d} {d}\n", .{ linear_screen_pos.x, linear_screen_pos.y });

                        vert.x = @floatToInt(i32, @floor(screen.width * (0.5 + 0.5 * linear_screen_pos.x)));
                        vert.y = @floatToInt(i32, @floor(screen.height * (0.5 - 0.5 * linear_screen_pos.y)));
                        vert.z = linear_screen_pos.z;

                        vert.u = uvCoords[vtx.textureCoordinate.?].x;
                        vert.v = 1.0 - uvCoords[vtx.textureCoordinate.?].y;
                    }

                    // (B - A) x (C - A)
                    var winding = zgl.math3d.Vec3.cross(.{
                        .x = @intToFloat(f32, face.vertices[1].x - face.vertices[0].x),
                        .y = @intToFloat(f32, face.vertices[1].y - face.vertices[0].y),
                        .z = 0,
                    }, .{
                        .x = @intToFloat(f32, face.vertices[2].x - face.vertices[0].x),
                        .y = @intToFloat(f32, face.vertices[2].y - face.vertices[0].y),
                        .z = 0,
                    });
                    if (winding.z < 0)
                        continue;

                    visible_polycount += 1;

                    try softwareRenderer.renderPolygonTextured(face);
                }
            }
        }

        {
            var time = @intToFloat(f64, timer.read()) / 1000.0;

            totalTime += time;
            totalFrames += 1;
            bestTime = std.math.min(bestTime, time);
            worstTime = std.math.max(worstTime, time);
            std.debug.warn("total time: {d: >10.3}µs\ttriangle time: {d: >10.3}µs\tpoly count: {}/{}\n", .{
                time,
                time / @intToFloat(f64, visible_polycount),
                visible_polycount,
                total_polycount,
            });

            perfStats[perfPtr] = time;
            perfPtr +%= 1;
        }

        // Update the screen buffer
        {
            var rgbaScreen: [screen.height][screen.width]u32 = undefined;
            for (rgbaScreen) |*row, y| {
                for (row) |*pix, x| {
                    pix.* = palette[backBuffer.getPixel(x, y)];
                }
            }
            try texture.update(@sliceToBytes(rgbaScreen[0..]), screen.width * 4, null);
        }

        try renderer.setColorRGB(0, 0, 0);
        try renderer.clear();

        try renderer.copy(texture, null, null);

        try renderer.setDrawBlendMode(.SDL_BLENDMODE_BLEND);

        {
            const getY = struct {
                fn getY(v: f64) i32 {
                    return 256 - @floatToInt(i32, @round(256 * v / 17000));
                }
            }.getY;

            try renderer.setColor(SDL.Color.parse("#FFFFFF40") catch unreachable);
            try renderer.fillRect(.{
                .x = 0,
                .y = 0,
                .width = 256,
                .height = 256,
            });

            try renderer.setColor(SDL.Color.parse("#00000080") catch unreachable);
            var ms: f64 = 1;
            while (ms <= 16) : (ms += 1) {
                try renderer.drawLine(0, getY(ms * 1000), 256, getY(ms * 1000));
            }
            try renderer.drawLine(0, getY(0), 256, getY(0));

            try renderer.setColor(SDL.Color.parse("#FF8000") catch unreachable);
            {
                var i: u8 = 0;
                while (i < 255) : (i += 1) {
                    var t0 = perfStats[perfPtr +% i +% 0];
                    var t1 = perfStats[perfPtr +% i +% 1];
                    try renderer.drawLine(i + 0, getY(t0), i + 1, getY(t1));
                }
            }

            try renderer.setColor(SDL.Color.parse("#00FF00") catch unreachable);
            try renderer.drawLine(0, getY(bestTime), 256, getY(bestTime));

            try renderer.setColor(SDL.Color.parse("#FF0000") catch unreachable);
            try renderer.drawLine(0, getY(worstTime), 256, getY(worstTime));

            try renderer.setColor(SDL.Color.parse("#FFFFFF") catch unreachable);
            try renderer.drawLine(0, getY(totalTime / totalFrames), 256, getY(totalTime / totalFrames));
        }

        renderer.present();
    }
    std.debug.warn("best time:  {d: >10.3}µs\n", .{bestTime});
    std.debug.warn("avg time:   {d: >10.3}µs\n", .{totalTime / totalFrames});
    std.debug.warn("worst time: {d: >10.3}µs\n", .{worstTime});
}

fn angleToVec3(pan: f32, tilt: f32) zgl.math3d.Vec3 {
    return .{
        .x = std.math.sin(pan) * std.math.cos(tilt),
        .y = std.math.sin(tilt),
        .z = -std.math.cos(pan) * std.math.cos(tilt),
    };
}

/// wraps gameMain, so we can react to an SdlError and print
/// its error message
pub fn main() !void {
    gameMain() catch |err| switch (err) {
        error.SdlError => {
            std.debug.warn("SDL Failure: {}\n", .{SDL.getError()});
            return err;
        },
        else => return err,
    };
}
