const std = @import("std");
const SDL = @import("sdl2");

const screen = struct {
    const width = 320;
    const height = 240;
    var pixels: [height][width]u8 = undefined;
};
var palette: [256]u32 = undefined;

const Texture = struct {
    pixels: []const u8,
    width: usize,
    height: usize,

    fn sample(tex: Texture, u: f32, v: f32) u8 {
        const x = @floatToInt(usize, @round(@intToFloat(f32, tex.width - 1) * @rem(u, 1.0)));
        const y = @floatToInt(usize, @round(@intToFloat(f32, tex.height - 1) * @rem(v, 1.0)));
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
        15, 8,  6,  8,  6,  8,  6,  15,
        15, 6,  8,  6,  8,  6,  8,  15,
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
        3 * screen.width,
        3 * screen.height,
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

    // for (palette) |*pal, i| {
    //     const v = @intCast(u8, i);
    //     // render 232 colors here

    //     const C = packed struct {
    //         r: u3,
    //         g: u3,
    //         b: u2,
    //     };
    //     std.debug.assert(@sizeOf(C) == 1);

    //     const c = @bitCast(C, v);

    //     const r = (@as(u32, c.r) << 5) | (@as(u32, c.r) << 2) | (@as(u32, c.r) >> 1);
    //     const g = (@as(u32, c.g) << 5) | (@as(u32, c.g) << 2) | (@as(u32, c.g) >> 1);
    //     const b = (@as(u32, c.b) << 6) | (@as(u32, c.b) << 4) | (@as(u32, c.b) << 2) | @as(u32, c.b);

    //     pal.* = 0xFF | (b << 8) | (g << 16) | (r << 24);
    // }

    var bestTime: f64 = 10000;
    var worstTime: f64 = 0;
    var totalTime: f64 = 0;
    var totalFrames: f64 = 0;

    var perfStats: [256]f64 = [_]f64{0} ** 256;
    var perfPtr: u8 = 0;

    mainLoop: while (true) {
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

        const angle = 0.0007 * @intToFloat(f32, SDL.getTicks());

        const center_x = 160 + 160 * std.math.sin(2.1 * angle);
        const center_y = 120 + 120 * std.math.sin(1.03 * angle);

        var corners: [3]Point = undefined;

        // downfacing triangle ( v-form )
        // corners[0] = .{ .x = 160 - 40, .y = 100 };
        // corners[1] = .{ .x = 160 + 40, .y = 100 };
        // corners[2] = .{ .x = 160, .y = 140 };

        // upfacing triangle ( ^-form )
        // corners[0] = .{ .x = 160 - 40, .y = 140 };
        // corners[1] = .{ .x = 160 + 40, .y = 140 };
        // corners[2] = .{ .x = 160, .y = 100 };

        // rotating triangle
        for (corners) |*corner, i| {
            const deg120 = 3.0 * std.math.pi / 2.0;
            const a = angle + deg120 * @intToFloat(f32, i);
            corner.x = @floatToInt(i32, @round(center_x + 48 * std.math.sin(a)));
            corner.y = @floatToInt(i32, @round(center_y + 48 * std.math.cos(a)));
        }

        for (screen.pixels) |*row| {
            for (row) |*pix| {
                pix.* = 0;
            }
        }

        var timer = try std.time.Timer.start();

        paintTriangle(corners, corners, struct {
            fn clamp(v: f32, min: f32, max: f32) f32 {
                return std.math.min(max, std.math.max(min, v));
            }

            fn paint(x: i32, y: i32, p: [3]Point) void {
                const p1 = p[0];
                const p2 = p[1];
                const p3 = p[2];

                var v1 = clamp(@intToFloat(f32, (p2.y - p3.y) * (x - p3.x) + (p3.x - p2.x) * (y - p3.y)) /
                    @intToFloat(f32, (p2.y - p3.y) * (p1.x - p3.x) + (p3.x - p2.x) * (p1.y - p3.y)), 0.0, 1.0);

                var v2 = clamp(@intToFloat(f32, (p3.y - p1.y) * (x - p3.x) + (p1.x - p3.x) * (y - p3.y)) /
                    @intToFloat(f32, (p2.y - p3.y) * (p1.x - p3.x) + (p3.x - p2.x) * (p1.y - p3.y)), 0.0, 1.0);

                var v3 = clamp(1.0 - v2 - v1, 0.0, 1.0);

                var sum = v1 + v2 + v3;
                v1 /= sum;
                v2 /= sum;
                v3 /= sum;

                const uvs_x = [_]f32{ 0.0, 1.0, 1.0 };
                const uvs_y = [_]f32{ 0.0, 0.0, 1.0 };

                paintPixelUnsafe(x, y, exampleTex.sample(
                    uvs_x[0] * v1 + uvs_x[1] * v2 + uvs_x[2] * v3,
                    uvs_y[0] * v1 + uvs_y[1] * v2 + uvs_y[2] * v3,
                ));

                // if (v1 > 1 or v2 > 1 or v3 < 0)
                //     std.debug.warn("{d} {d} {d}\n", .{ v1, v2, v3 });

                // const C = packed struct {
                //     r: u3,
                //     g: u3,
                //     b: u2,
                // };

                // const c = C{
                //     .r = @floatToInt(u3, @round(7 * v1)),
                //     .g = @floatToInt(u3, @round(7 * v2)),
                //     .b = @floatToInt(u2, @round(3 * v3)),
                // };

                // paintPixelUnsafe(x, y, @bitCast(u8, c));
            }
        }.paint);

        {
            var time = @intToFloat(f64, timer.read()) / 1000.0;

            totalTime += time;
            totalFrames += 1;
            bestTime = std.math.min(bestTime, time);
            worstTime = std.math.max(worstTime, time);
            std.debug.warn("triangle time: {d: >10.3}µs\n", .{time});

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

        {
            const getY = struct {
                fn getY(v: f64) i32 {
                    return 256 - @floatToInt(i32, @round(256 * v / 1000));
                }
            }.getY;

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
    gameMain() catch |err| switch (err) {
        error.SdlError => {
            std.debug.warn("SDL Failure: {}\n", .{SDL.getError()});
            return err;
        },
        else => return err,
    };
}
