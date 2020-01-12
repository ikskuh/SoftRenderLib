const std = @import("std");
const SDL = @import("sdl2");
const zgl = @import("zgl");

const Quality = enum {
    fast,
    beautiful,
};

const quality: Quality = .fast;

const DepthType = u32;

const screen = struct {
    const scaler = 1;
    const width = 1280;
    const height = 720;
    var pixels: [height][width]u8 = undefined;
    var depth: [height][width]DepthType = undefined;
};
var palette: [256]u32 = undefined;

const Texture = struct {
    pixels: []const u8,
    width: usize,
    height: usize,

    fn sample(tex: Texture, u: f32, v: f32) u8 {
        const x = @rem(@floatToInt(usize, @floor(@intToFloat(f32, tex.width) * u)), tex.width);
        const y = @rem(@floatToInt(usize, @floor(@intToFloat(f32, tex.height) * v)), tex.height);
        return tex.pixels[x + tex.width * y];
    }
};

var exampleTex = Texture{
    .width = 8,
    .height = 8,
    .pixels = &[_]u8{
        15, 15, 15, 15, 15, 15, 15, 15,
        15, 8,  6,  8,  6,  8,  6,  15,
        15, 6,  8,  6,  8,  6,  8,  15,
        15, 8,  6,  11, 11, 8,  6,  15,
        15, 6,  8,  11, 11, 6,  8,  15,
        15, 8,  6,  8,  6,  8,  6,  15,
        15, 6,  8,  6,  8,  6,  8,  15,
        15, 15, 15, 15, 15, 15, 15, 15,
    },
};

// pre-optimization
// best time:  28.146µs
// avg time:   86.754µs
// worst time: 3445.271µs

// post-optimization
// best time:  22.489µs
// avg time:   70.050µs
// worst time: 305.346µs

// post-optimization 2
// best time:  8.242µs
// avg time:   46.342µs
// worst time: 170.343µs

fn paintPixel(x: i32, y: i32, color: u8) void {
    if (x >= 0 and y >= 0 and x < screen.width and y < screen.height) {
        paintPixelUnsafe(x, y, color);
    }
}

fn paintPixelUnsafe(x: i32, y: i32, color: u8) void {
    screen.pixels[@intCast(usize, y)][@intCast(usize, x)] = color;
}

fn paintLine(x0: i32, y0: i32, x1: i32, y1: i32, color: u8) void {
    var dx = std.math.absInt(x1 - x0) catch unreachable;
    var sx = if (x0 < x1) @as(i32, 1) else -1;
    var dy = -(std.math.absInt(y1 - y0) catch unreachable);
    var sy = if (y0 < y1) @as(i32, 1) else -1;
    var err = dx + dy; // error value e_xy

    var x = x0;
    var y = y0;

    while (true) {
        paintPixel(x, y, color);
        if (x == x1 and y == y1)
            break;
        const e2 = 2 * err;
        if (e2 > dy) { // e_xy+e_x > 0
            err += dy;
            x += sx;
        }
        if (e2 < dx) { // e_xy+e_y < 0
            err += dx;
            y += sy;
        }
    }
}

const Point = struct {
    x: i32,
    y: i32,
};

fn paintTriangle(points: [3]Point, context: var, painter: fn (x: i32, y: i32, ctx: @TypeOf(context)) void) void {
    var localPoints = points;
    std.sort.sort(
        Point,
        &localPoints,
        struct {
            fn lessThan(lhs: Point, rhs: Point) bool {
                return lhs.y < rhs.y;
            }
        }.lessThan,
    );

    // Implements two special versions
    // of painting an up-facing or down-facing triangle with one perfectly horizontal side.
    const Helper = struct {
        const Mode = enum {
            growing,
            shrinking,
        };
        fn paintHalfTriangle(comptime mode: Mode, x_left: i32, x_right: i32, x_low: i32, y0: i32, y1: i32, context0: var, painter0: fn (x: i32, y: i32, ctx: @TypeOf(context0)) void) void {
            if (y0 >= screen.height or y1 < 0)
                return;
            const totalY = y1 - y0;
            std.debug.assert(totalY > 0);

            var xa = if (mode == .shrinking) std.math.min(x_left, x_right) else x_low;
            var xb = if (mode == .shrinking) std.math.max(x_left, x_right) else x_low;

            const dx_a = if (mode == .shrinking) x_low - xa else std.math.min(x_left, x_right) - x_low;
            const dx_b = if (mode == .shrinking) x_low - xb else std.math.max(x_left, x_right) - x_low;

            const sx_a = if (dx_a < 0) @as(i32, -1) else 1;
            const sx_b = if (dx_b < 0) @as(i32, -1) else 1;

            const de_a = std.math.fabs(@intToFloat(f32, dx_a) / @intToFloat(f32, totalY));
            const de_b = std.math.fabs(@intToFloat(f32, dx_b) / @intToFloat(f32, totalY));

            var e_a: f32 = 0;
            var e_b: f32 = 0;

            var sy = y0;
            while (sy <= std.math.min(screen.height - 1, y1)) : (sy += 1) {
                if (sy >= 0) {
                    var x_s = std.math.max(xa, 0);
                    const x_e = std.math.min(xb, screen.width - 1);
                    while (x_s <= x_e) : (x_s += 1) {
                        painter0(x_s, sy, context0);
                    }
                }

                e_a += de_a;
                e_b += de_b;

                if (e_a >= 0.5) {
                    const d = @floor(e_a);
                    xa += @floatToInt(i32, d) * sx_a;
                    e_a -= d;
                }

                if (e_b >= 0.5) {
                    const d = @floor(e_b);
                    xb += @floatToInt(i32, d) * sx_b;
                    e_b -= d;
                }
            }
        }

        fn paintUpperTriangle(x00: i32, x01: i32, x1: i32, y0: i32, y1: i32, ctx: var, painter0: fn (x: i32, y: i32, _ctx: @TypeOf(ctx)) void) void {
            paintHalfTriangle(.shrinking, x00, x01, x1, y0, y1, ctx, painter0);
        }
        fn paintLowerTriangle(x0: i32, x10: i32, x11: i32, y0: i32, y1: i32, ctx: var, painter0: fn (x: i32, y: i32, _ctx: @TypeOf(ctx)) void) void {
            paintHalfTriangle(.growing, x10, x11, x0, y0, y1, ctx, painter0);
        }
    };

    if (localPoints[0].y == localPoints[1].y and localPoints[0].y == localPoints[2].y) {
        // this is actually a flat line, nothing to draw here
        return;
    }

    if (localPoints[0].y == localPoints[1].y) {
        // triangle shape:
        // o---o
        //  \ /
        //   o
        Helper.paintUpperTriangle(
            localPoints[0].x,
            localPoints[1].x,
            localPoints[2].x,
            localPoints[0].y,
            localPoints[2].y,
            context,
            painter,
        );
    } else if (localPoints[1].y == localPoints[2].y) {
        // triangle shape:
        //   o
        //  / \
        // o---o
        Helper.paintLowerTriangle(
            localPoints[0].x,
            localPoints[1].x,
            localPoints[2].x,
            localPoints[0].y,
            localPoints[1].y,
            context,
            painter,
        );
    } else {
        // non-straightline triangle
        //    o
        //   / \
        //  o---\
        //   \  |
        //    \ \
        //     \|
        //      o
        const y0 = localPoints[0].y;
        const y1 = localPoints[1].y;
        const y2 = localPoints[2].y;

        const deltaY01 = y1 - y0;
        const deltaY12 = y2 - y1;
        const deltaY02 = y2 - y0;
        std.debug.assert(deltaY01 > 0);
        std.debug.assert(deltaY12 > 0);

        // std.debug.warn("{d} * ({d} - {d}) / {d}\n", .{ deltaY01, localPoints[2].x, localPoints[0].x, deltaY02 });
        const pHelp: Point = .{
            .x = localPoints[0].x + @divFloor(deltaY01 * (localPoints[2].x - localPoints[0].x), deltaY02),
            .y = y1,
        };

        Helper.paintLowerTriangle(
            localPoints[0].x,
            localPoints[1].x,
            pHelp.x,
            localPoints[0].y,
            localPoints[1].y,
            context,
            painter,
        );

        Helper.paintUpperTriangle(
            localPoints[1].x,
            pHelp.x,
            localPoints[2].x,
            localPoints[1].y,
            localPoints[2].y,
            context,
            painter,
        );
    }
}

const Vertex = struct {
    x: i32,
    y: i32,
    z: f32 = 0,
    u: f32 = 0,
    v: f32 = 0,
    color: u8 = 0,
};

fn makePolygon(points: var) [3]Point {
    return [3]Point{
        .{ .x = points[0].x, .y = points[0].y },
        .{ .x = points[1].x, .y = points[1].y },
        .{ .x = points[2].x, .y = points[2].y },
    };
}

const TexturedPainter = struct {
    fn clamp(v: f32, min: f32, max: f32) f32 {
        return std.math.min(max, std.math.max(min, v));
    }

    fn paint(x: i32, y: i32, p: [3]Vertex) void {
        const p1 = &p[0];
        const p2 = &p[1];
        const p3 = &p[2];

        // std.debug.warn("{} {}\n", .{ (p2.y - p3.y), (p1.x - p3.x) });
        const divisor = (p2.y - p3.y) * (p1.x - p3.x) + (p3.x - p2.x) * (p1.y - p3.y);
        if (divisor == 0)
            return;

        var v1 = clamp(@intToFloat(f32, (p2.y - p3.y) * (x - p3.x) + (p3.x - p2.x) * (y - p3.y)) / @intToFloat(f32, divisor), 0.0, 1.0);

        var v2 = clamp(@intToFloat(f32, (p3.y - p1.y) * (x - p3.x) + (p1.x - p3.x) * (y - p3.y)) / @intToFloat(f32, divisor), 0.0, 1.0);

        var v3 = clamp(1.0 - v2 - v1, 0.0, 1.0);

        if (quality != .fast) {
            var sum = v1 + v2 + v3;
            v1 /= sum;
            v2 /= sum;
            v3 /= sum;
        }

        const z = p1.z * v1 + p2.z * v2 + p3.z * v3;
        if (z < 0.0 or z > 1.0)
            return;

        const int_z = @floatToInt(DepthType, @floor(@floatToInt(f32, std.math.maxInt(DepthType) - 1) * z));

        const depth = &screen.depth[@intCast(usize, y)][@intCast(usize, x)];

        if (@atomicLoad(DepthType, depth, .Acquire) < int_z)
            return;

        const pixCol = exampleTex.sample(
            p1.u * v1 + p2.u * v2 + p3.u * v3,
            p1.v * v1 + p2.v * v2 + p3.v * v3,
        );
        if (pixCol == 0x00)
            return;

        _ = @atomicRmw(DepthType, depth, .Min, int_z, .SeqCst); // we don't care for the previous value
        if (@atomicLoad(DepthType, depth, .Acquire) != int_z)
            return;

        // if (depth.* < int_z)
        //     return;
        // depth.* = int_z;

        paintPixelUnsafe(x, y, pixCol);
    }
};

fn angleToVec3(pan: f32, tilt: f32) zgl.math3d.Vec3 {
    return .{
        .x = std.math.sin(pan) * std.math.cos(tilt),
        .y = std.math.sin(tilt),
        .z = -std.math.cos(pan) * std.math.cos(tilt),
    };
}

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
        var file = try std.fs.cwd().openRead("assets/lost_empire.pcx");
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

    var model = try zgl.wavefrontObj.load(std.heap.c_allocator, "assets/lost_empire.obj");

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

    var plenty_of_memory = try std.heap.page_allocator.alloc(u8, model.faces.len * 1024);
    defer std.heap.page_allocator.free(plenty_of_memory);

    var queue = std.atomic.Queue([3]Vertex).init();

    var polyCounter: usize = 0;

    const RenderWorker = struct {
        queue: *std.atomic.Queue([3]Vertex),
        thread: *std.Thread,
        shutdown: bool,
        counter: *usize,
    };

    var workers: [8]RenderWorker = undefined;

    for (workers) |*loop_worker| {
        loop_worker.* = RenderWorker{
            .queue = &queue,
            .thread = undefined,
            .shutdown = false,
            .counter = &polyCounter,
        };
        loop_worker.thread = try std.Thread.spawn(loop_worker, struct {
            fn doWork(worker: *RenderWorker) void {
                while (!worker.shutdown) {
                    while (worker.queue.get()) |job| {
                        paintTriangle(makePolygon(job.data), job.data, TexturedPainter.paint);
                        _ = @atomicRmw(usize, worker.counter, .Add, 1, .SeqCst);
                    }
                    std.time.sleep(1);
                }
            }
        }.doWork);
    }

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

        for (screen.pixels) |*row| {
            for (row) |*pix| {
                pix.* = 0;
            }
        }
        for (screen.depth) |*row| {
            for (row) |*depth| {
                @atomicStore(DepthType, depth, std.math.maxInt(DepthType), .Release);
            }
        }

        const persp = zgl.math3d.Mat4.createPerspective(
            60.0 * std.math.tau / 360.0,
            4.0 / 3.0,
            0.01,
            10000.0,
        );

        const view = zgl.math3d.Mat4.createLookAt(camera.position, camera.position.add(camdir), zgl.math3d.Vec3.unitY);

        var timer = try std.time.Timer.start();

        _ = screen.pixels;

        // {
        //     var i: usize = 0;
        //     while (i < indices.len) : (i += 3) {
        //         var poly = [_]Vertex{
        //             corners[indices[i + 0]],
        //             corners[indices[i + 1]],
        //             corners[indices[i + 2]],
        //         };
        //         paintTriangle(makePolygon(poly), poly, TexturedPainter.paint);
        //     }
        // }

        var visible_polycount: usize = 0;
        var total_polycount: usize = 0;

        {
            @atomicStore(usize, &polyCounter, 0, .Release);

            var fixed_buffer_allocator = std.heap.ThreadSafeFixedBufferAllocator.init(plenty_of_memory);
            var allocator = &fixed_buffer_allocator.allocator;

            const world = zgl.math3d.Mat4.identity; // (5.0 * worldX, 0.0, 5.0 * worldZ); // createAngleAxis(.{ .x = 0, .y = 1, .z = 0 }, angle);

            const mvp = world.mul(view).mul(persp);

            const faces = model.faces.toSliceConst();
            const positions = model.positions.toSliceConst();
            const uvCoords = model.textureCoordinates.toSliceConst();

            for (model.objects.toSliceConst()) |obj| {
                var i: usize = 0;
                face: while (i < obj.count) : (i += 1) {
                    const face = faces[obj.start + i];
                    if (face.count != 3)
                        continue;

                    total_polycount += 1;

                    var poly: [3]Vertex = undefined;
                    for (poly) |*vert, j| {
                        const vtx = face.vertices[j];

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
                        .x = @intToFloat(f32, poly[1].x - poly[0].x),
                        .y = @intToFloat(f32, poly[1].y - poly[0].y),
                        .z = 0,
                    }, .{
                        .x = @intToFloat(f32, poly[2].x - poly[0].x),
                        .y = @intToFloat(f32, poly[2].y - poly[0].y),
                        .z = 0,
                    });
                    if (winding.z < 0)
                        continue;

                    visible_polycount += 1;

                    const node = allocator.create(std.atomic.Queue([3]Vertex).Node) catch unreachable;
                    node.* = std.atomic.Queue([3]Vertex).Node{
                        .prev = undefined,
                        .next = undefined,
                        .data = poly,
                    };
                    queue.put(node);

                    // paintTriangle(makePolygon(poly), poly, TexturedPainter.paint);
                }
            }

            while (@atomicLoad(usize, &polyCounter, .Acquire) != visible_polycount) {
                std.time.sleep(1);
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
                    pix.* = palette[screen.pixels[y][x]];
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

/// wraps gameMain, so we can react to an SdlError and print
/// its error message
pub fn main() !void {
    // gameMain() catch |err| switch (err) {
    //     error.SdlError => {
    //         std.debug.warn("SDL Failure: {}\n", .{SDL.getError()});
    //         return err;
    //     },
    //     else => return err,
    // };
    try gameMain();
}
