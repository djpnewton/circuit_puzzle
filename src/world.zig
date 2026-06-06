const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");

pub const WIDTH: usize = 5;
pub const DEPTH: usize = 5;
pub const BLOCK_SIZE: f32 = 1.0;
const BLOCK_HALF: f32 = BLOCK_SIZE * 0.5;

const is_web = builtin.target.cpu.arch == .wasm32;
const lighting_vs = if (is_web) @embedFile("shaders/lighting_es.vs") else @embedFile("shaders/lighting.vs");
const lighting_fs = if (is_web) @embedFile("shaders/lighting_es.fs") else @embedFile("shaders/lighting.fs");
pub const MAX_HEIGHT: usize = 1; // safe upper bound for terrain heights

// --- terrain types -------------------------------------------------------

pub const TerrainType = enum { grass, dirt, rock, coal };

pub fn typeColor(t: TerrainType) rl.Color {
    return switch (t) {
        .grass => rl.Color.init(91, 163, 75, 255),
        .dirt => rl.Color.init(121, 85, 52, 255),
        .rock => rl.Color.init(130, 130, 130, 255),
        .coal => rl.Color.init(45, 42, 48, 255),
    };
}

pub fn typeName(t: TerrainType) [:0]const u8 {
    return switch (t) {
        .grass => "Grass",
        .dirt => "Dirt",
        .rock => "Rock",
        .coal => "Coal",
    };
}

// --- colours + shading ---------------------------------------------------

const COLOR_GRASS_TOP = rl.Color.init(91, 163, 75, 255);
const COLOR_GRASS_SIDE = rl.Color.init(119, 96, 58, 255);
const COLOR_DIRT = rl.Color.init(121, 85, 52, 255);
const COLOR_STONE = rl.Color.init(120, 120, 120, 255);
const COLOR_COAL = rl.Color.init(45, 42, 48, 255);

const SH_TOP: f32 = 1.00; // +Y
const SH_NS: f32 = 0.80; // ±Z
const SH_EW: f32 = 0.65; // ±X

fn mulU8(v: u8, f: f32) u8 {
    const r = @as(f32, @floatFromInt(v)) * f;
    if (r >= 255.0) return 255;
    return @intFromFloat(r);
}

fn tint(c: rl.Color, f: f32) rl.Color {
    return rl.Color.init(mulU8(c.r, f), mulU8(c.g, f), mulU8(c.b, f), c.a);
}

// --- mesh builder --------------------------------------------------------

/// Write-head over pre-allocated slices -- no dynamic allocations needed.
const Writer = struct {
    verts: []f32,
    cols: []u8,
    idxs: []u16,
    vi: usize = 0,
    ci: usize = 0,
    ii: usize = 0,

    fn addQuad(
        w: *Writer,
        v0: [3]f32,
        v1: [3]f32,
        v2: [3]f32,
        v3: [3]f32,
        c0: rl.Color,
        c1: rl.Color,
        c2: rl.Color,
        c3: rl.Color,
    ) void {
        const base: u16 = @intCast(w.vi / 3);
        for (&[_][3]f32{ v0, v1, v2, v3 }) |v| {
            w.verts[w.vi + 0] = v[0];
            w.verts[w.vi + 1] = v[1];
            w.verts[w.vi + 2] = v[2];
            w.vi += 3;
        }
        for (&[_]rl.Color{ c0, c1, c2, c3 }) |c| {
            w.cols[w.ci + 0] = c.r;
            w.cols[w.ci + 1] = c.g;
            w.cols[w.ci + 2] = c.b;
            w.cols[w.ci + 3] = c.a;
            w.ci += 4;
        }
        const tri_idxs = [6]u16{ base, base + 1, base + 2, base, base + 2, base + 3 };
        @memcpy(w.idxs[w.ii .. w.ii + 6], &tri_idxs);
        w.ii += 6;
    }
};

// --- ambient occlusion ---------------------------------------------------

const AO_DARK: f32 = 0.55;
const AO_MED: f32 = 0.72;
const AO_LITE: f32 = 0.86;

/// Is there a solid block at the given (possibly out-of-bounds) coordinate?
fn solid(h: *const [WIDTH][DEPTH]usize, x: i64, y: i64, z: i64) bool {
    if (x < 0 or z < 0 or y < 0) return false;
    if (x >= @as(i64, @intCast(WIDTH)) or z >= @as(i64, @intCast(DEPTH))) return false;
    return y <= @as(i64, @intCast(h[@intCast(x)][@intCast(z)]));
}

/// Classic voxel corner ambient-occlusion weight from the two edge
/// neighbours and the diagonal corner neighbour.
fn aoMul(s1: bool, s2: bool, cor: bool) f32 {
    if (s1 and s2) return AO_DARK;
    const n: u8 = @as(u8, @intFromBool(s1)) + @intFromBool(s2) + @intFromBool(cor);
    return switch (n) {
        0 => 1.0,
        1 => AO_LITE,
        else => AO_MED,
    };
}

fn aoTop(h: *const [WIDTH][DEPTH]usize, ix: i64, iy: i64, iz: i64) [4]f32 {
    const ny = iy + 1;
    return .{
        aoMul(solid(h, ix - 1, ny, iz), solid(h, ix, ny, iz - 1), solid(h, ix - 1, ny, iz - 1)),
        aoMul(solid(h, ix - 1, ny, iz), solid(h, ix, ny, iz + 1), solid(h, ix - 1, ny, iz + 1)),
        aoMul(solid(h, ix + 1, ny, iz), solid(h, ix, ny, iz + 1), solid(h, ix + 1, ny, iz + 1)),
        aoMul(solid(h, ix + 1, ny, iz), solid(h, ix, ny, iz - 1), solid(h, ix + 1, ny, iz - 1)),
    };
}

fn aoNegZ(h: *const [WIDTH][DEPTH]usize, ix: i64, iy: i64, iz: i64) [4]f32 {
    const nz = iz - 1;
    return .{
        aoMul(solid(h, ix + 1, iy, nz), solid(h, ix, iy - 1, nz), solid(h, ix + 1, iy - 1, nz)),
        aoMul(solid(h, ix - 1, iy, nz), solid(h, ix, iy - 1, nz), solid(h, ix - 1, iy - 1, nz)),
        aoMul(solid(h, ix - 1, iy, nz), solid(h, ix, iy + 1, nz), solid(h, ix - 1, iy + 1, nz)),
        aoMul(solid(h, ix + 1, iy, nz), solid(h, ix, iy + 1, nz), solid(h, ix + 1, iy + 1, nz)),
    };
}

fn aoPosZ(h: *const [WIDTH][DEPTH]usize, ix: i64, iy: i64, iz: i64) [4]f32 {
    const nz = iz + 1;
    return .{
        aoMul(solid(h, ix - 1, iy, nz), solid(h, ix, iy - 1, nz), solid(h, ix - 1, iy - 1, nz)),
        aoMul(solid(h, ix + 1, iy, nz), solid(h, ix, iy - 1, nz), solid(h, ix + 1, iy - 1, nz)),
        aoMul(solid(h, ix + 1, iy, nz), solid(h, ix, iy + 1, nz), solid(h, ix + 1, iy + 1, nz)),
        aoMul(solid(h, ix - 1, iy, nz), solid(h, ix, iy + 1, nz), solid(h, ix - 1, iy + 1, nz)),
    };
}

fn aoNegX(h: *const [WIDTH][DEPTH]usize, ix: i64, iy: i64, iz: i64) [4]f32 {
    const nx = ix - 1;
    return .{
        aoMul(solid(h, nx, iy, iz - 1), solid(h, nx, iy - 1, iz), solid(h, nx, iy - 1, iz - 1)),
        aoMul(solid(h, nx, iy, iz + 1), solid(h, nx, iy - 1, iz), solid(h, nx, iy - 1, iz + 1)),
        aoMul(solid(h, nx, iy, iz + 1), solid(h, nx, iy + 1, iz), solid(h, nx, iy + 1, iz + 1)),
        aoMul(solid(h, nx, iy, iz - 1), solid(h, nx, iy + 1, iz), solid(h, nx, iy + 1, iz - 1)),
    };
}

fn aoPosX(h: *const [WIDTH][DEPTH]usize, ix: i64, iy: i64, iz: i64) [4]f32 {
    const nx = ix + 1;
    return .{
        aoMul(solid(h, nx, iy, iz + 1), solid(h, nx, iy - 1, iz), solid(h, nx, iy - 1, iz + 1)),
        aoMul(solid(h, nx, iy, iz - 1), solid(h, nx, iy - 1, iz), solid(h, nx, iy - 1, iz - 1)),
        aoMul(solid(h, nx, iy, iz - 1), solid(h, nx, iy + 1, iz), solid(h, nx, iy + 1, iz - 1)),
        aoMul(solid(h, nx, iy, iz + 1), solid(h, nx, iy + 1, iz), solid(h, nx, iy + 1, iz + 1)),
    };
}

fn countFaces(heights: *const [WIDTH][DEPTH]usize) usize {
    var count: usize = 0;
    for (0..WIDTH) |xi| {
        for (0..DEPTH) |zi| {
            const top = heights[xi][zi];
            for (0..top + 1) |yi| {
                if (yi == top) count += 1;
                if (zi == 0 or heights[xi][zi - 1] < yi) count += 1;
                if (zi + 1 == DEPTH or heights[xi][zi + 1] < yi) count += 1;
                if (xi == 0 or heights[xi - 1][zi] < yi) count += 1;
                if (xi + 1 == WIDTH or heights[xi + 1][zi] < yi) count += 1;
            }
        }
    }
    return count;
}

fn fillGeometry(w: *Writer, heights: *const [WIDTH][DEPTH]usize, types: *const [WIDTH][DEPTH][MAX_HEIGHT]TerrainType) void {
    for (0..WIDTH) |xi| {
        for (0..DEPTH) |zi| {
            const top = heights[xi][zi];
            const wx: f32 = @as(f32, @floatFromInt(xi)) * BLOCK_SIZE;
            const wz: f32 = @as(f32, @floatFromInt(zi)) * BLOCK_SIZE;
            const ix: i64 = @intCast(xi);
            const iz: i64 = @intCast(zi);

            for (0..top + 1) |yi| {
                const wy: f32 = @as(f32, @floatFromInt(yi)) * BLOCK_SIZE;
                const iy: i64 = @intCast(yi);
                const is_top = (yi == top);

                const bt = types[xi][zi][yi];
                const tc: rl.Color = switch (bt) {
                    .grass => COLOR_GRASS_TOP,
                    .dirt => COLOR_DIRT,
                    .rock => COLOR_STONE,
                    .coal => COLOR_COAL,
                };
                const sc: rl.Color = switch (bt) {
                    .grass => COLOR_GRASS_SIDE,
                    .dirt => COLOR_DIRT,
                    .rock => COLOR_STONE,
                    .coal => COLOR_COAL,
                };

                const x0 = wx - BLOCK_HALF;
                const x1 = wx + BLOCK_HALF;
                const y0 = wy - BLOCK_HALF;
                const y1 = wy + BLOCK_HALF;
                const z0 = wz - BLOCK_HALF;
                const z1 = wz + BLOCK_HALF;

                // +Y top -- only the surface block
                if (is_top) {
                    const a = aoTop(heights, ix, iy, iz);
                    w.addQuad(.{ x0, y1, z0 }, .{ x0, y1, z1 }, .{ x1, y1, z1 }, .{ x1, y1, z0 }, tint(tc, SH_TOP * a[0]), tint(tc, SH_TOP * a[1]), tint(tc, SH_TOP * a[2]), tint(tc, SH_TOP * a[3]));
                }

                // -Z
                if (zi == 0 or heights[xi][zi - 1] < yi) {
                    const a = aoNegZ(heights, ix, iy, iz);
                    w.addQuad(.{ x1, y0, z0 }, .{ x0, y0, z0 }, .{ x0, y1, z0 }, .{ x1, y1, z0 }, tint(sc, SH_NS * a[0]), tint(sc, SH_NS * a[1]), tint(sc, SH_NS * a[2]), tint(sc, SH_NS * a[3]));
                }
                // +Z
                if (zi + 1 == DEPTH or heights[xi][zi + 1] < yi) {
                    const a = aoPosZ(heights, ix, iy, iz);
                    w.addQuad(.{ x0, y0, z1 }, .{ x1, y0, z1 }, .{ x1, y1, z1 }, .{ x0, y1, z1 }, tint(sc, SH_NS * a[0]), tint(sc, SH_NS * a[1]), tint(sc, SH_NS * a[2]), tint(sc, SH_NS * a[3]));
                }
                // -X
                if (xi == 0 or heights[xi - 1][zi] < yi) {
                    const a = aoNegX(heights, ix, iy, iz);
                    w.addQuad(.{ x0, y0, z0 }, .{ x0, y0, z1 }, .{ x0, y1, z1 }, .{ x0, y1, z0 }, tint(sc, SH_EW * a[0]), tint(sc, SH_EW * a[1]), tint(sc, SH_EW * a[2]), tint(sc, SH_EW * a[3]));
                }
                // +X
                if (xi + 1 == WIDTH or heights[xi + 1][zi] < yi) {
                    const a = aoPosX(heights, ix, iy, iz);
                    w.addQuad(.{ x1, y0, z1 }, .{ x1, y0, z0 }, .{ x1, y1, z0 }, .{ x1, y1, z1 }, tint(sc, SH_EW * a[0]), tint(sc, SH_EW * a[1]), tint(sc, SH_EW * a[2]), tint(sc, SH_EW * a[3]));
                }
            }
        }
    }
}

// --- World ---------------------------------------------------------------

fn buildModel(heights: *const [WIDTH][DEPTH]usize, types: *const [WIDTH][DEPTH][MAX_HEIGHT]TerrainType) !rl.Model {
    const nfaces = countFaces(heights);
    const ca = std.heap.c_allocator;
    const verts = try ca.alloc(f32, nfaces * 4 * 3);
    const cols = try ca.alloc(u8, nfaces * 4 * 4);
    const idxs = try ca.alloc(u16, nfaces * 6);

    var wr = Writer{ .verts = verts, .cols = cols, .idxs = idxs };
    fillGeometry(&wr, heights, types);

    var mesh: rl.Mesh = std.mem.zeroes(rl.Mesh);
    mesh.vertexCount = @intCast(nfaces * 4);
    mesh.triangleCount = @intCast(nfaces * 2);
    mesh.vertices = verts.ptr;
    mesh.colors = cols.ptr;
    mesh.indices = @ptrCast(idxs.ptr);

    rl.uploadMesh(&mesh, false);
    return try rl.loadModelFromMesh(mesh);
}

pub const World = struct {
    model: rl.Model,
    heights: [WIDTH][DEPTH]usize,
    orig_heights: [WIDTH][DEPTH]usize,
    types: [WIDTH][DEPTH][MAX_HEIGHT]TerrainType,
    shader: rl.Shader,
    loc_light: i32,
    loc_view: i32,

    /// Build the static terrain mesh.  Must be called after rl.initWindow.
    pub fn init() !World {
        var heights: [WIDTH][DEPTH]usize = undefined;
        for (0..WIDTH) |x| {
            for (0..DEPTH) |z| {
                heights[x][z] = 0;
            }
        }

        var types: [WIDTH][DEPTH][MAX_HEIGHT]TerrainType = undefined;
        for (0..WIDTH) |x| {
            for (0..DEPTH) |z| {
                for (0..MAX_HEIGHT) |y| {
                    types[x][z][y] = .grass;
                }
            }
        }
        const shader = try rl.loadShaderFromMemory(lighting_vs, lighting_fs);
        const loc_light = rl.getShaderLocation(shader, "lightPos");
        const loc_view = rl.getShaderLocation(shader, "viewPos");
        var model = try buildModel(&heights, &types);
        model.materials[0].shader = shader;
        return .{ .model = model, .heights = heights, .orig_heights = heights, .types = types, .shader = shader, .loc_light = loc_light, .loc_view = loc_view };
    }

    pub fn deinit(self: *World) void {
        rl.unloadModel(self.model);
        rl.unloadShader(self.shader);
    }

    pub fn draw(self: World, view_pos: rl.Vector3) void {
        rl.setShaderValue(self.shader, self.loc_light, &view_pos, .vec3);
        rl.setShaderValue(self.shader, self.loc_view, &view_pos, .vec3);
        rl.drawModel(self.model, rl.Vector3{ .x = 0, .y = 0, .z = 0 }, 1.0, rl.Color.init(255, 255, 255, 255));
    }

    /// Returns the center of the closest block the ray intersects, or null.
    pub fn raycast(self: *const World, ray: rl.Ray) ?rl.Vector3 {
        var best_dist: f32 = std.math.floatMax(f32);
        var result: ?rl.Vector3 = null;
        for (0..WIDTH) |xi| {
            for (0..DEPTH) |zi| {
                const top = self.heights[xi][zi];
                for (0..top + 1) |yi| {
                    const wx: f32 = @as(f32, @floatFromInt(xi)) * BLOCK_SIZE;
                    const wy: f32 = @as(f32, @floatFromInt(yi)) * BLOCK_SIZE;
                    const wz: f32 = @as(f32, @floatFromInt(zi)) * BLOCK_SIZE;
                    const col = rl.getRayCollisionBox(ray, .{
                        .min = .{ .x = wx - BLOCK_HALF, .y = wy - BLOCK_HALF, .z = wz - BLOCK_HALF },
                        .max = .{ .x = wx + BLOCK_HALF, .y = wy + BLOCK_HALF, .z = wz + BLOCK_HALF },
                    });
                    if (col.hit and col.distance < best_dist) {
                        best_dist = col.distance;
                        result = .{ .x = wx, .y = wy, .z = wz };
                    }
                }
            }
        }
        return result;
    }

    pub fn typeAt(self: *const World, pos: rl.Vector3) TerrainType {
        const xi: usize = @intFromFloat(@round(pos.x / BLOCK_SIZE));
        const zi: usize = @intFromFloat(@round(pos.z / BLOCK_SIZE));
        const yi: usize = @intFromFloat(@round(pos.y / BLOCK_SIZE));
        if (xi >= WIDTH or zi >= DEPTH or yi >= MAX_HEIGHT) return .rock;
        return self.types[xi][zi][yi];
    }

    /// Remove the top block of the column under pos and rebuild the mesh.
    pub fn removeBlock(self: *World, pos: rl.Vector3) !void {
        const xi: usize = @intFromFloat(@round(pos.x / BLOCK_SIZE));
        const zi: usize = @intFromFloat(@round(pos.z / BLOCK_SIZE));
        if (xi >= WIDTH or zi >= DEPTH) return;
        if (self.heights[xi][zi] > 0) self.heights[xi][zi] -= 1;
        rl.unloadModel(self.model);
        self.model = try buildModel(&self.heights, &self.types);
        self.model.materials[0].shader = self.shader;
    }
};
