const std = @import("std");

pub const Quality = enum {
    fast,
    beautiful,
};

const Point = struct {
    x: i32,
    y: i32,
};

const Rectangle = struct {
    /// inclusive left bound
    left: i32,

    /// inclusive upper bound
    top: i32,

    /// exlusive right bound
    right: i32,

    /// exlusive lower bound
    bottom: i32,
};

pub fn Texture(comptime Pixel: type) type {
    return struct {
        const Self = @This();

        allocator: *std.mem.Allocator,
        pixels: []Pixel,
        width: usize,
        height: usize,

        pub fn init(allocator: *std.mem.Allocator, width: usize, height: usize) !Self {
            return Self{
                .allocator = allocator,
                .width = width,
                .height = height,
                .pixels = try allocator.alloc(Pixel, width * height),
            };
        }

        pub fn deinit(self: Self) void {
            self.allocator.free(self.pixels);
        }

        pub fn sample(tex: Self, u: f32, v: f32) Pixel {
            const x = @rem(@floatToInt(usize, @floor(@intToFloat(f32, tex.width) * u)), tex.width);
            const y = @rem(@floatToInt(usize, @floor(@intToFloat(f32, tex.height) * v)), tex.height);
            return tex.pixels[x + tex.width * y];
        }

        pub fn getPixel(tex: Self, x: usize, y: usize) Pixel {
            return tex.pixels[x + tex.width * y];
        }

        pub fn setPixel(tex: *Self, x: usize, y: usize, color: Pixel) void {
            tex.pixels[x + tex.width * y] = color;
        }

        pub fn getPixelPtr(tex: *Self, x: usize, y: usize) *Pixel {
            return &tex.pixels[x + tex.width * y];
        }

        pub fn fill(tex: *Self, color: Pixel) void {
            for (tex.pixels) |*pix| {
                pix.* = color;
            }
        }
    };
}

pub fn Vertex(comptime PixelType: type) type {
    return struct {
        x: i32,
        y: i32,
        z: f32 = 0,
        u: f32 = 0,
        v: f32 = 0,
        color: PixelType = 0,
    };
}
pub fn Face(comptime PixelType: type) type {
    return struct {
        const Self = @This();

        texture: *Texture(PixelType),
        vertices: [3]Vertex(PixelType),

        pub fn toPolygon(face: Self) [3]Point {
            return [3]Point{
                .{ .x = face.vertices[0].x, .y = face.vertices[0].y },
                .{ .x = face.vertices[1].x, .y = face.vertices[1].y },
                .{ .x = face.vertices[2].x, .y = face.vertices[2].y },
            };
        }
    };
}

fn clamp(v: f32, min: f32, max: f32) f32 {
    return std.math.min(max, std.math.max(min, v));
}

pub fn Context(comptime PixelType: type, quality: Quality, comptime numThreads: ?comptime_int) type {
    return struct {
        const Self = @This();

        const DepthType = u32;
        const ColorTexture = Texture(PixelType);
        const DepthTexture = Texture(DepthType);

        const RenderJob = struct {
            context: *Self,
            face: Face(PixelType),
        };

        colorTarget: ?*ColorTexture,
        depthTarget: ?*DepthTexture,
        renderSystem: RenderSystem,

        targetWidth: usize,
        targetHeight: usize,

        pub fn init(context: *Self) !void {
            context.* = .{
                .colorTarget = null,
                .depthTarget = null,
                .renderSystem = undefined,
                .targetWidth = 0,
                .targetHeight = 0,
            };
            try RenderSystem.init(&context.renderSystem);
        }

        pub fn deinit(self: Self) void {
            self.renderSystem.deinit();
        }

        pub fn setRenderTarget(self: *Self, colorTarget: ?*ColorTexture, depthTarget: ?*DepthTexture) error{SizeMismatch}!void {
            if (colorTarget != null and depthTarget == null) {
                if (colorTarget.?.width != depthTarget.?.width)
                    return error.SizeMismatch;
                if (colorTarget.?.height != depthTarget.?.height)
                    return error.SizeMismatch;
            }
            if (colorTarget) |ct| {
                self.targetWidth = ct.width;
                self.targetHeight = ct.height;
            }
            if (depthTarget) |dt| {
                self.targetWidth = dt.width;
                self.targetHeight = dt.height;
            }
            self.colorTarget = colorTarget;
            self.depthTarget = depthTarget;
        }

        pub fn beginFrame(self: *Self) void {
            self.renderSystem.beginFrame();
        }

        pub fn renderPolygonTextured(self: *Self, face: Face(PixelType)) !void {
            try self.renderSystem.renderPolygonTextured(.{
                .context = self,
                .face = face,
            });
        }

        pub fn endFrame(self: *Self) void {
            self.renderSystem.endFrame();
        }

        const RenderSystem = if (numThreads) |unwrapped_core_count|
            struct {
                const RS = @This();
                const Queue = std.atomic.Queue(RenderJob);

                const RenderWorker = struct {
                    queue: *Queue,
                    thread: *std.Thread,
                    shutdown: bool,
                    processedPolyCount: *usize,
                };

                plenty_of_memory: []u8,
                queue: Queue = undefined,
                processedPolyCount: usize,
                expectedPolyCount: usize,

                workers: [unwrapped_core_count]RenderWorker = undefined,

                fixed_buffer_allocator: std.heap.ThreadSafeFixedBufferAllocator = undefined,

                fn init(rs: *RS) !void {
                    rs.* = .{
                        .queue = Queue.init(),
                        .fixed_buffer_allocator = undefined,
                        .plenty_of_memory = undefined,
                        .processedPolyCount = 0,
                        .expectedPolyCount = 0,
                    };

                    rs.plenty_of_memory = try std.heap.page_allocator.alloc(u8, 8 * 1024 * 1024); // 16 MB polygon space
                    errdefer std.heap.page_allocator.free(rs.plenty_of_memory);

                    rs.fixed_buffer_allocator = std.heap.ThreadSafeFixedBufferAllocator.init(rs.plenty_of_memory);

                    for (rs.workers) |*loop_worker| {
                        loop_worker.* = RenderWorker{
                            .queue = &rs.queue,
                            .thread = undefined,
                            .shutdown = false,
                            .processedPolyCount = &rs.processedPolyCount,
                        };
                        loop_worker.thread = try std.Thread.spawn(loop_worker, struct {
                            fn doWork(worker: *RenderWorker) void {
                                while (!worker.shutdown) {
                                    while (worker.queue.get()) |job| {
                                        paintTriangle(.{
                                            .left = 0,
                                            .top = 0,
                                            .right = @intCast(i32, job.data.context.targetWidth),
                                            .bottom = @intCast(i32, job.data.context.targetHeight),
                                        }, job.data.face.toPolygon(), job.data, paintTextured);
                                        _ = @atomicRmw(usize, worker.processedPolyCount, .Add, 1, .SeqCst);
                                    }
                                    std.time.sleep(1);
                                }
                            }
                        }.doWork);
                    }
                }

                fn beginFrame(renderSystem: *RS) void {
                    @atomicStore(usize, &renderSystem.processedPolyCount, 0, .Release);
                    renderSystem.expectedPolyCount = 0;
                    @atomicStore(usize, &renderSystem.fixed_buffer_allocator.end_index, 0, .Release);
                }

                fn renderPolygonTextured(renderSystem: *RS, job: RenderJob) !void {
                    const node = try renderSystem.fixed_buffer_allocator.allocator.create(Queue.Node);
                    node.* = Queue.Node{
                        .prev = undefined,
                        .next = undefined,
                        .data = job,
                    };
                    renderSystem.queue.put(node);

                    renderSystem.expectedPolyCount += 1;
                }

                fn endFrame(renderSystem: RS) void {
                    while (@atomicLoad(usize, &renderSystem.processedPolyCount, .Acquire) != renderSystem.expectedPolyCount) {
                        std.time.sleep(1);
                    }
                }

                fn deinit(renderSystem: RS) void {
                    std.heap.page_allocator.free(renderSystem.plenty_of_memory);
                }
            }
        else
            struct {
                const RS = @This();
                fn init(rs: *RS) error{Dummy}!void {}

                fn beginFrame(renderSystem: RS) void {}

                fn renderPolygonTextured(renderSystem: RS, job: RenderJob) error{OutOfMemory}!void {
                    paintTriangle(.{
                        .left = 0,
                        .top = 0,
                        .right = @intCast(i32, job.context.targetWidth),
                        .bottom = @intCast(i32, job.context.targetHeight),
                    }, job.face.toPolygon(), job, paintTextured);
                }

                fn endFrame(renderSystem: RS) void {}

                fn deinit(renderSystem: RS) void {}
            };

        pub fn paintTextured(x: i32, y: i32, job: RenderJob) void {
            const p1 = &job.face.vertices[0];
            const p2 = &job.face.vertices[1];
            const p3 = &job.face.vertices[2];

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

            var depth: *DepthType = undefined;
            var int_z: DepthType = undefined;
            if (job.context.depthTarget) |depthTarget| {
                int_z = @floatToInt(DepthType, @floor(@floatToInt(f32, std.math.maxInt(DepthType) - 1) * @as(f64, z)));
                depth = depthTarget.getPixelPtr(@intCast(usize, x), @intCast(usize, y));

                if (@atomicLoad(DepthType, depth, .Acquire) < int_z)
                    return;
            }

            var u: f32 = undefined;
            var v: f32 = undefined;
            if (quality == .beautiful) {
                u = z * ((p1.u / z) * v1 + (p2.u / z) * v2 + (p3.u / z) * v3);
                v = z * ((p1.v / z) * v1 + (p2.v / z) * v2 + (p3.v / z) * v3);
            } else {
                u = p1.u * v1 + p2.u * v2 + p3.u * v3;
                v = p1.v * v1 + p2.v * v2 + p3.v * v3;
            }

            const pixCol = job.face.texture.sample(u, v);
            if (pixCol == 0x00)
                return;

            if (job.context.depthTarget) |depthTarget| {
                _ = @atomicRmw(DepthType, depth, .Min, int_z, .SeqCst); // we don't care for the previous value
                if (@atomicLoad(DepthType, depth, .Acquire) != int_z)
                    return;
            }

            // if (depth.* < int_z)
            //     return;
            // depth.* = int_z;

            if (job.context.colorTarget) |colorTarget| {
                colorTarget.setPixel(@intCast(usize, x), @intCast(usize, y), pixCol);
            }
        }
    };
}

fn paintTriangle(bounds: Rectangle, points: [3]Point, context: var, painter: fn (x: i32, y: i32, ctx: @TypeOf(context)) void) void {
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
        fn paintHalfTriangle(comptime mode: Mode, x_left: i32, x_right: i32, x_low: i32, y0: i32, y1: i32, bounds0: Rectangle, context0: var, painter0: fn (x: i32, y: i32, ctx: @TypeOf(context0)) void) void {

            // early-discard when triangle is fully out of bounds
            if (y0 >= bounds0.bottom or y1 < bounds0.top)
                return;
            if (std.math.max(x_left, std.math.max(x_right, x_low)) < bounds0.left)
                return;
            if (std.math.min(x_left, std.math.min(x_right, x_low)) >= bounds0.right)
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
            while (sy <= std.math.min(bounds0.bottom - 1, y1)) : (sy += 1) {
                if (sy >= 0) {
                    var x_s = std.math.max(xa, bounds0.left);
                    const x_e = std.math.min(xb, bounds0.right - 1);
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

        fn paintUpperTriangle(x00: i32, x01: i32, x1: i32, y0: i32, y1: i32, bounds0: Rectangle, ctx: var, painter0: fn (x: i32, y: i32, _ctx: @TypeOf(ctx)) void) void {
            paintHalfTriangle(.shrinking, x00, x01, x1, y0, y1, bounds0, ctx, painter0);
        }
        fn paintLowerTriangle(x0: i32, x10: i32, x11: i32, y0: i32, y1: i32, bounds0: Rectangle, ctx: var, painter0: fn (x: i32, y: i32, _ctx: @TypeOf(ctx)) void) void {
            paintHalfTriangle(.growing, x10, x11, x0, y0, y1, bounds0, ctx, painter0);
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
            bounds,
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
            bounds,
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
            bounds,
            context,
            painter,
        );

        Helper.paintUpperTriangle(
            localPoints[1].x,
            pHelp.x,
            localPoints[2].x,
            localPoints[1].y,
            localPoints[2].y,
            bounds,
            context,
            painter,
        );
    }
}

// legacy code:

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
