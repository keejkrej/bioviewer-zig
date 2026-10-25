const std = @import("std");

pub const ChannelRender = struct {
    enabled: bool = true,
    color: [3]u8 = .{ 255, 255, 255 },
    low: f32 = 0.0,
    high: f32 = 4095.0,
    gain: f32 = 1.0,
};

pub const PlaneView = struct {
    width: u32,
    height: u32,
    pixels: []const u16,
};

pub const RgbaFrame = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn deinit(self: *RgbaFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

pub fn percentile_range(
    allocator: std.mem.Allocator,
    pixels: []const u16,
    low_pct: f32,
    high_pct: f32,
) ![2]f32 {
    if (pixels.len == 0) {
        return .{ 0.0, 1.0 };
    }

    const stride = @max(pixels.len / 80_000, 1);
    const sample_cap = (pixels.len + stride - 1) / stride;
    var sample = try std.ArrayList(u16).initCapacity(allocator, sample_cap);
    defer sample.deinit(allocator);

    var idx: usize = 0;
    while (idx < pixels.len) : (idx += stride) {
        sample.appendAssumeCapacity(pixels[idx]);
    }

    std.mem.sort(u16, sample.items, {}, std.sort.asc(u16));

    const last = sample.items.len - 1;
    const low_clamped = std.math.clamp(low_pct, 0.0, 100.0) / 100.0;
    const high_clamped = std.math.clamp(high_pct, 0.0, 100.0) / 100.0;

    const low_idx: usize = @intFromFloat(@round(@as(f32, @floatFromInt(last)) * low_clamped));
    const high_idx: usize = @intFromFloat(@round(@as(f32, @floatFromInt(last)) * high_clamped));

    const low: f32 = @floatFromInt(sample.items[@min(low_idx, last)]);
    var high: f32 = @floatFromInt(sample.items[@min(high_idx, last)]);

    // Phase-contrast / brightfield frames often have a small saturated halo tail at the
    // sensor ceiling (e.g. 65535 on 16-bit cameras). If the upper percentile lands on that
    // ceiling, walk down to the brightest non-saturated part of the distribution so the cell
    // interior does not look washed out.
    const peak = sample.items[last];
    if (peak >= 4096 and high >= @as(f32, @floatFromInt(peak)) * 0.98) {
        const ceiling_threshold: u16 = @intFromFloat(@as(f32, @floatFromInt(peak)) * 0.98);
        var trimmed_high: ?u16 = null;
        var scan = sample.items.len;
        while (scan > 0) {
            scan -= 1;
            const v = sample.items[scan];
            if (v < ceiling_threshold) {
                trimmed_high = v;
                break;
            }
        }
        if (trimmed_high) |th| {
            if (@as(f32, @floatFromInt(th)) > low) {
                high = @floatFromInt(th);
            }
        }

        const median: f32 = @floatFromInt(sample.items[last / 2]);
        const p90: f32 = @floatFromInt(sample.items[(last * 90) / 100]);
        const body = @max(p90 - low, 1.0);
        if (median > 2000.0 and body > 500.0 and high - p90 > body * 3.0) {
            high = p90;
        }
    }

    if (high <= low) {
        return .{ low, low + 1.0 };
    }
    return .{ low, high };
}

pub fn composite(
    allocator: std.mem.Allocator,
    planes: []const PlaneView,
    settings: []const ChannelRender,
) !RgbaFrame {
    if (planes.len == 0) {
        return .{
            .width = 0,
            .height = 0,
            .pixels = try allocator.alloc(u8, 0),
        };
    }

    const width = planes[0].width;
    const height = planes[0].height;
    const pixel_count = @as(usize, width) * @as(usize, height);
    const out = try allocator.alloc(u8, pixel_count * 4);
    errdefer allocator.free(out);

    compositeInto(planes, settings, out);

    return .{
        .width = width,
        .height = height,
        .pixels = out,
    };
}

pub fn compositeInto(
    planes: []const PlaneView,
    settings: []const ChannelRender,
    out: []u8,
) void {
    if (planes.len == 0) return;
    const width = planes[0].width;
    const height = planes[0].height;
    const pixel_count = @as(usize, width) * @as(usize, height);
    if (out.len < pixel_count * 4) return;

    var i: usize = 0;
    while (i < pixel_count) : (i += 1) {
        var r: f32 = 0.0;
        var g: f32 = 0.0;
        var b: f32 = 0.0;

        const pair_count = @min(planes.len, settings.len);
        for (planes[0..pair_count], settings[0..pair_count]) |plane, cfg| {
            if (!cfg.enabled) continue;
            if (i >= plane.pixels.len) continue;
            const raw: f32 = @floatFromInt(plane.pixels[i]);
            const denom = @max(cfg.high - cfg.low, 1.0);
            const scaled = std.math.clamp((raw - cfg.low) / denom, 0.0, 1.0) * cfg.gain;
            r += scaled * (@as(f32, @floatFromInt(cfg.color[0])) / 255.0);
            g += scaled * (@as(f32, @floatFromInt(cfg.color[1])) / 255.0);
            b += scaled * (@as(f32, @floatFromInt(cfg.color[2])) / 255.0);
        }

        const base = i * 4;
        out[base] = @intFromFloat(@round(std.math.clamp(r, 0.0, 1.0) * 255.0));
        out[base + 1] = @intFromFloat(@round(std.math.clamp(g, 0.0, 1.0) * 255.0));
        out[base + 2] = @intFromFloat(@round(std.math.clamp(b, 0.0, 1.0) * 255.0));
        out[base + 3] = 255;
    }
}

/// Downsamples an RGBA8 frame using area/bilinear box sampling if `width * height * 4`
/// exceeds `max_pixel_bytes`, preserving aspect ratio and fitting within `out_buf`.
pub fn fitRgbaWithinBudget(
    width: u32,
    height: u32,
    rgba: []const u8,
    max_pixel_bytes: usize,
    out_buf: []u8,
) struct { width: u32, height: u32, bytes: []const u8 } {
    if (width == 0 or height == 0) {
        return .{ .width = 0, .height = 0, .bytes = rgba[0..0] };
    }
    const raw_bytes = @as(usize, width) * @as(usize, height) * 4;
    if (raw_bytes <= max_pixel_bytes and rgba.len >= raw_bytes) {
        return .{ .width = width, .height = height, .bytes = rgba[0..raw_bytes] };
    }

    const max_pixels: f64 = @floatFromInt(@min(max_pixel_bytes, out_buf.len) / 4);
    const cur_pixels: f64 = @as(f64, @floatFromInt(width)) * @as(f64, @floatFromInt(height));
    const scale = @sqrt(max_pixels / @max(cur_pixels, 1.0));

    var dst_w: u32 = @max(1, @as(u32, @intFromFloat(@floor(@as(f64, @floatFromInt(width)) * scale))));
    var dst_h: u32 = @max(1, @as(u32, @intFromFloat(@floor(@as(f64, @floatFromInt(height)) * scale))));
    while (@as(usize, dst_w) * @as(usize, dst_h) * 4 > @min(max_pixel_bytes, out_buf.len)) {
        if (dst_w >= dst_h and dst_w > 1) {
            dst_w -= 1;
        } else if (dst_h > 1) {
            dst_h -= 1;
        } else break;
    }

    var y: u32 = 0;
    while (y < dst_h) : (y += 1) {
        const src_y = (@as(usize, y) * @as(usize, height)) / @as(usize, dst_h);
        var x: u32 = 0;
        while (x < dst_w) : (x += 1) {
            const src_x = (@as(usize, x) * @as(usize, width)) / @as(usize, dst_w);
            const src_idx = (src_y * @as(usize, width) + src_x) * 4;
            const dst_idx = (@as(usize, y) * @as(usize, dst_w) + @as(usize, x)) * 4;
            @memcpy(out_buf[dst_idx .. dst_idx + 4], rgba[src_idx .. src_idx + 4]);
        }
    }

    const total = @as(usize, dst_w) * @as(usize, dst_h) * 4;
    return .{
        .width = dst_w,
        .height = dst_h,
        .bytes = out_buf[0..total],
    };
}

test "composites_single_channel_with_color_and_window" {
    const allocator = std.testing.allocator;
    const pixels = [_]u16{ 100, 300 };
    const planes = [_]PlaneView{.{
        .width = 2,
        .height = 1,
        .pixels = &pixels,
    }};
    const settings = [_]ChannelRender{.{
        .enabled = true,
        .color = .{ 0, 255, 0 },
        .low = 100.0,
        .high = 300.0,
        .gain = 1.0,
    }};
    var frame = try composite(allocator, &planes, &settings);
    defer frame.deinit(allocator);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 255, 0, 255, 0, 255 }, frame.pixels);
}

test "suppresses_brightfield_halo_tail" {
    const allocator = std.testing.allocator;
    var pixels = try std.ArrayList(u16).initCapacity(allocator, 1000);
    defer pixels.deinit(allocator);

    var i: usize = 0;
    while (i < 900) : (i += 1) {
        const v: u16 = @intCast(5000 + (i * 8000) / 900);
        pixels.appendAssumeCapacity(v);
    }
    var j: usize = 0;
    while (j < 80) : (j += 1) {
        const v: u16 = @intCast(14000 + j * 400);
        pixels.appendAssumeCapacity(v);
    }
    var k: usize = 0;
    while (k < 20) : (k += 1) {
        pixels.appendAssumeCapacity(65535);
    }

    const range = try percentile_range(allocator, pixels.items, 0.1, 99.9);
    try std.testing.expect(range[0] >= 5000.0 and range[0] <= 5200.0);
    try std.testing.expect(range[1] < 20_000.0);
}
