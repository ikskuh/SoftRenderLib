const std = @import("std");
const SDL = @import("sdl2");

var screen: [240][320]u8 = undefined;
var palette: [256]u32 = undefined;

fn paintPixel(x: i32, y: i32, color: u8) void {
    if (x >= 0 and y >= 0 and x < 320 and y < 240) {
        screen[@intCast(usize, y)][@intCast(usize, x)] = color;
    }
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

fn paintTriangle(points: [3]Point, fillColor: u8, borderColor: ?u8) void {
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

    const Helper = struct {
        fn paintUpperTriangle(x00: i32, x01: i32, x1: i32, y0: i32, y1: i32, color: u8) void {
            const totalY = y1 - y0;
            std.debug.assert(totalY > 0);

            var sy = y0;
            var ly: i32 = 0;
            while (sy <= y1) {
                const xa = x00 + @divFloor(ly * (x1 - x00), totalY);
                const xb = x01 + @divFloor(ly * (x1 - x01), totalY);

                var x = std.math.min(xa, xb);
                while (x <= std.math.max(xa, xb)) : (x += 1) {
                    paintPixel(x, sy, color);
                }

                sy += 1;
                ly += 1;
            }
        }
        fn paintLowerTriangle(x0: i32, x10: i32, x11: i32, y0: i32, y1: i32, color: u8) void {
            const totalY = y1 - y0;
            std.debug.assert(totalY > 0);

            var sy = y0;
            var ly: i32 = 0;
            while (sy <= y1) {
                var xa = x0 + @divFloor(ly * (x10 - x0), totalY);
                var xb = x0 + @divFloor(ly * (x11 - x0), totalY);

                var x = std.math.min(xa, xb);
                while (x <= std.math.max(xa, xb)) : (x += 1) {
                    paintPixel(x, sy, color);
                }

                sy += 1;
                ly += 1;
            }
        }
    };

    if (localPoints[0].y == localPoints[1].y and localPoints[0].y == localPoints[2].y) {
        // this is actually a flat line m(
        unreachable; // TODO: Fix this later some day
        // return;
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
            fillColor,
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
            fillColor,
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
            fillColor,
        );

        Helper.paintUpperTriangle(
            localPoints[1].x,
            pHelp.x,
            localPoints[2].x,
            localPoints[1].y,
            localPoints[2].y,
            fillColor,
        );
    }

    if (borderColor) |bc| {
        paintLine(localPoints[0].x, localPoints[0].y, localPoints[1].x, localPoints[1].y, bc);
        paintLine(localPoints[1].x, localPoints[1].y, localPoints[2].x, localPoints[2].y, bc);
        paintLine(localPoints[2].x, localPoints[2].y, localPoints[0].x, localPoints[0].y, bc);
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
        604,
        480,
        .{ .shown = true },
    );
    defer window.destroy();

    var renderer = try SDL.createRenderer(window, null, .{ .accelerated = true, .presentVSync = true });
    defer renderer.destroy();

    var texture = try SDL.createTexture(renderer, .rgbx8888, .streaming, 320, 240);
    defer texture.destroy();

    var prng = std.rand.DefaultPrng.init(0);

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

    var bestTime: f64 = 10000;
    var worstTime: f64 = 0;

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

        for (screen) |*row| {
            for (row) |*pix| {
                pix.* = 0;
            }
        }

        var timer = try std.time.Timer.start();

        paintTriangle(
            corners,
            9,
            15,
        );

        {
            var time = @intToFloat(f64, timer.read()) / 1000.0;

            bestTime = std.math.min(bestTime, time);
            worstTime = std.math.max(worstTime, time);
            std.debug.warn("triangle time: {d: >10.3}µs\n", .{time});
        }

        // Update the screen buffer
        {
            var rgbaScreen: [240][320]u32 = undefined;
            for (rgbaScreen) |*row, y| {
                for (row) |*pix, x| {
                    pix.* = palette[screen[y][x]];
                }
            }
            try texture.update(@sliceToBytes(rgbaScreen[0..]), 320 * 4, null);
        }

        try renderer.setColorRGB(0, 0, 0);
        try renderer.clear();

        try renderer.copy(texture, null, null);

        // try renderer.setColor(SDL.Color.parse("#FF8080") catch unreachable);
        // try renderer.drawRect(SDL.Rectangle{
        //     .x = 10,
        //     .y = 20,
        //     .width = 100,
        //     .height = 50,
        // });

        renderer.present();
    }
    std.debug.warn("best time:  {d: >10.3}µs\n", .{bestTime});
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
