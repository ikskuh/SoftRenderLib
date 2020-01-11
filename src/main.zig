const std = @import("std");
const SDL = @import("sdl2");

var screen: [240][320]u8 = undefined;
var palette: [256]u32 = undefined;

fn paintLine(x0: i32, y0: i32, x1: i32, y1: i32, color: u8) void {
    var dx = std.math.absInt(x1 - x0) catch unreachable;
    var sx = if (x0 < x1) @as(i32, 1) else -1;
    var dy = -(std.math.absInt(y1 - y0) catch unreachable);
    var sy = if (y0 < y1) @as(i32, 1) else -1;
    var err = dx + dy; // error value e_xy

    var x = x0;
    var y = y0;

    while (true) {
        if (x >= 0 and y >= 0 and x < 320 and y < 240) {
            screen[@intCast(usize, y)][@intCast(usize, x)] = color;
        }
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
    if (borderColor) |bc| {
        paintLine(points[0].x, points[0].y, points[1].x, points[1].y, bc);
        paintLine(points[1].x, points[1].y, points[2].x, points[2].y, bc);
        paintLine(points[2].x, points[2].y, points[0].x, points[0].y, bc);
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
        "SDL.zig Basic Demo",
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

        const center_x = 160 + 160 * std.math.sin(0.1 * angle);
        const center_y = 120 + 120 * std.math.sin(0.03 * angle);

        var corners: [3]Point = undefined;
        for (corners) |*corner, i| {
            const deg120 = 3.0 * std.math.pi / 2.0;
            const a = angle + deg120 * @intToFloat(f32, i);
            corner.x = @floatToInt(i32, @round(center_x + 48 * std.math.sin(a)));
            corner.y = @floatToInt(i32, @round(center_y + 48 * std.math.cos(a)));
        }

        paintTriangle(
            corners,
            1,
            15,
        );

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
