const std = @import("std");
const czi = @import("czi");
const nd2 = @import("nd2");
const metadata = @import("metadata.zig");
const tiff_frame = @import("tiff_frame.zig");

pub const Axes = struct {
    position: []u8,
    time: u32,
    z: u32,
    channel: u32,

    pub fn deinit(self: *Axes, allocator: std.mem.Allocator) void {
        allocator.free(self.position);
        self.* = undefined;
    }
};

pub const Axis = enum {
    time,
    position,
    z,
    channel,
};

pub const FrameEntry = struct {
    axes: Axes,
    path: []u8,

    pub fn deinit(self: *FrameEntry, allocator: std.mem.Allocator) void {
        self.axes.deinit(allocator);
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const Series = struct {
    root: []u8,
    positions: [][]u8,
    times: []u32,
    zs: []u32,
    channels: []u32,
    files: []FrameEntry,

    pub fn deinit(self: *Series, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        for (self.positions) |pos| allocator.free(pos);
        allocator.free(self.positions);
        allocator.free(self.times);
        allocator.free(self.zs);
        allocator.free(self.channels);
        for (self.files) |*entry| entry.deinit(allocator);
        allocator.free(self.files);
        self.* = undefined;
    }

    pub fn get(
        self: *const Series,
        position: []const u8,
        time: u32,
        z: u32,
        channel: u32,
    ) ?[]const u8 {
        for (self.files) |entry| {
            if (entry.axes.time == time and
                entry.axes.z == z and
                entry.axes.channel == channel and
                std.mem.eql(u8, entry.axes.position, position))
            {
                return entry.path;
            }
        }
        return null;
    }
};

pub const DatasetKind = union(enum) {
    mm_tiff,
    czi_file: czi.CziFile,
    nd2_file: nd2.Nd2File,
};

pub const OpenedSeries = struct {
    series: Series,
    channel_info: []metadata.ChannelIdentity,
    backend: DatasetKind = .mm_tiff,

    pub fn deinit(self: *OpenedSeries, allocator: std.mem.Allocator, io: std.Io) void {
        _ = io;
        switch (self.backend) {
            .mm_tiff => {},
            .czi_file => |*f| f.deinit(),
            .nd2_file => |*f| f.deinit(),
        }
        self.series.deinit(allocator);
        for (self.channel_info) |*info| info.deinit(allocator);
        allocator.free(self.channel_info);
        self.* = undefined;
    }

    pub fn loadMoment(
        self: *OpenedSeries,
        allocator: std.mem.Allocator,
        io: std.Io,
        position: []const u8,
        time: u32,
        z: u32,
    ) !tiff_frame.Moment {
        return switch (self.backend) {
            .mm_tiff => load_moment(allocator, io, &self.series, position, time, z),
            .czi_file => |*f| loadCziMoment(allocator, f, &self.series, position, time, z),
            .nd2_file => |*f| loadNd2Moment(allocator, f, &self.series, position, time, z),
        };
    }
};

pub fn load_moment(
    allocator: std.mem.Allocator,
    io: std.Io,
    series: *const Series,
    position: []const u8,
    time: u32,
    z: u32,
) !tiff_frame.Moment {
    var channels: std.ArrayList(tiff_frame.LoadedChannel) = .empty;
    errdefer {
        for (channels.items) |*ch| ch.deinit(allocator);
        channels.deinit(allocator);
    }

    for (series.channels) |ch| {
        if (series.get(position, time, z, ch)) |path| {
            const plane = try tiff_frame.read_plane(allocator, io, path);
            try channels.append(allocator, .{
                .channel = ch,
                .plane = plane,
            });
        }
    }

    if (channels.items.len == 0) {
        return error.NoChannelFilesFound;
    }

    const pos_copy = try allocator.dupe(u8, position);
    errdefer allocator.free(pos_copy);

    return .{
        .position = pos_copy,
        .time = time,
        .z = z,
        .channels = try channels.toOwnedSlice(allocator),
    };
}

pub fn open_any_series(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !OpenedSeries {
    if (hasExtensionIgnoreCase(path, ".czi")) {
        return open_czi_series(allocator, io, path);
    }
    if (hasExtensionIgnoreCase(path, ".nd2")) {
        return open_nd2_series(allocator, io, path);
    }
    return open_series(allocator, io, path) catch |err| switch (err) {
        error.NoMicroManagerTiffFilesFound => {
            if (try findFirstCziOrNd2InDir(allocator, io, path)) |found_file| {
                defer allocator.free(found_file);
                if (hasExtensionIgnoreCase(found_file, ".czi")) {
                    return open_czi_series(allocator, io, found_file);
                } else {
                    return open_nd2_series(allocator, io, found_file);
                }
            }
            return err;
        },
        else => return err,
    };
}

fn findFirstCziOrNd2InDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
) !?[]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (hasExtensionIgnoreCase(entry.name, ".czi") or hasExtensionIgnoreCase(entry.name, ".nd2")) {
            return try std.fs.path.join(allocator, &.{ root_path, entry.name });
        }
    }
    return null;
}

pub fn open_czi_series(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !OpenedSeries {
    var file = try czi.CziFile.open(allocator, io, path);
    errdefer file.deinit();

    var sum = try file.summary();
    defer sum.deinit(allocator);

    const dims = sum.sizes;
    const num_s: u32 = @max(@as(u32, @intCast(dims.get("S") orelse 1)), 1);
    const num_t: u32 = @max(@as(u32, @intCast(dims.get("T") orelse 1)), 1);
    const num_z: u32 = @max(@as(u32, @intCast(dims.get("Z") orelse 1)), 1);
    const num_c: u32 = @max(@as(u32, @intCast(dims.get("C") orelse 1)), 1);

    var positions = try allocator.alloc([]u8, num_s);
    var pos_init: usize = 0;
    errdefer {
        for (positions[0..pos_init]) |p| allocator.free(p);
        allocator.free(positions);
    }
    while (pos_init < num_s) : (pos_init += 1) {
        positions[pos_init] = try std.fmt.allocPrint(allocator, "S{d}", .{pos_init});
    }

    const times = try allocator.alloc(u32, num_t);
    errdefer allocator.free(times);
    for (times, 0..) |*t, i| t.* = @intCast(i);

    const zs = try allocator.alloc(u32, num_z);
    errdefer allocator.free(zs);
    for (zs, 0..) |*z, i| z.* = @intCast(i);

    const channels = try allocator.alloc(u32, num_c);
    errdefer allocator.free(channels);
    for (channels, 0..) |*c, i| c.* = @intCast(i);

    const root_copy = try allocator.dupe(u8, path);
    errdefer allocator.free(root_copy);

    const files = try allocator.alloc(FrameEntry, 0);
    errdefer allocator.free(files);

    var channel_info = try allocator.alloc(metadata.ChannelIdentity, num_c);
    var ch_init: usize = 0;
    errdefer {
        for (channel_info[0..ch_init]) |*ci| ci.deinit(allocator);
        allocator.free(channel_info);
    }

    while (ch_init < num_c) : (ch_init += 1) {
        const ch_idx: u32 = @intCast(ch_init);
        const ch_name: []const u8 = if (ch_init < sum.channels.len)
            (sum.channels[ch_init].name orelse "")
        else
            "";
        channel_info[ch_init] = try metadata.identifyFromLabelAndExposure(
            allocator,
            ch_idx,
            ch_name,
            ch_name,
            null,
        );
    }

    return .{
        .series = .{
            .root = root_copy,
            .positions = positions,
            .times = times,
            .zs = zs,
            .channels = channels,
            .files = files,
        },
        .channel_info = channel_info,
        .backend = .{ .czi_file = file },
    };
}

fn loadCziMoment(
    allocator: std.mem.Allocator,
    file: *czi.CziFile,
    series: *const Series,
    position: []const u8,
    time: u32,
    z: u32,
) !tiff_frame.Moment {
    var scene_idx: usize = 0;
    for (series.positions, 0..) |pos_name, idx| {
        if (std.mem.eql(u8, pos_name, position)) {
            scene_idx = idx;
            break;
        }
    }

    const dims = file.sizes();
    const width: u32 = @intCast(dims.get("X") orelse 0);
    const height: u32 = @intCast(dims.get("Y") orelse 0);
    if (width == 0 or height == 0) return error.NoChannelFilesFound;

    var channels: std.ArrayList(tiff_frame.LoadedChannel) = .empty;
    errdefer {
        for (channels.items) |*ch| ch.deinit(allocator);
        channels.deinit(allocator);
    }

    for (series.channels) |ch| {
        const raw_pixels = try file.readFrame2d(scene_idx, time, ch, z);
        defer file.allocator.free(raw_pixels);

        const pixels = try allocator.dupe(u16, raw_pixels);
        errdefer allocator.free(pixels);

        try channels.append(allocator, .{
            .channel = ch,
            .plane = .{
                .width = width,
                .height = height,
                .pixels = pixels,
            },
        });
    }

    if (channels.items.len == 0) return error.NoChannelFilesFound;

    return .{
        .position = try allocator.dupe(u8, position),
        .time = time,
        .z = z,
        .channels = try channels.toOwnedSlice(allocator),
    };
}

pub fn open_nd2_series(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !OpenedSeries {
    var file = try nd2.Nd2File.open(allocator, io, path);
    errdefer file.deinit();

    const sz = try file.sizes();
    const num_p: u32 = @max(@as(u32, @intCast(sz.P)), 1);
    const num_t: u32 = @max(@as(u32, @intCast(sz.T)), 1);
    const num_z: u32 = @max(@as(u32, @intCast(sz.Z)), 1);
    const num_c: u32 = @max(@as(u32, @intCast(sz.C)), 1);

    var positions = try allocator.alloc([]u8, num_p);
    var pos_init: usize = 0;
    errdefer {
        for (positions[0..pos_init]) |p| allocator.free(p);
        allocator.free(positions);
    }
    while (pos_init < num_p) : (pos_init += 1) {
        positions[pos_init] = try std.fmt.allocPrint(allocator, "P{d}", .{pos_init});
    }

    const times = try allocator.alloc(u32, num_t);
    errdefer allocator.free(times);
    for (times, 0..) |*t, i| t.* = @intCast(i);

    const zs = try allocator.alloc(u32, num_z);
    errdefer allocator.free(zs);
    for (zs, 0..) |*z, i| z.* = @intCast(i);

    const channels = try allocator.alloc(u32, num_c);
    errdefer allocator.free(channels);
    for (channels, 0..) |*c, i| c.* = @intCast(i);

    const root_copy = try allocator.dupe(u8, path);
    errdefer allocator.free(root_copy);

    const files = try allocator.alloc(FrameEntry, 0);
    errdefer allocator.free(files);

    var channel_info = try allocator.alloc(metadata.ChannelIdentity, num_c);
    var ch_init: usize = 0;
    errdefer {
        for (channel_info[0..ch_init]) |*ci| ci.deinit(allocator);
        allocator.free(channel_info);
    }

    while (ch_init < num_c) : (ch_init += 1) {
        const ch_idx: u32 = @intCast(ch_init);
        channel_info[ch_init] = try metadata.identifyFromLabelAndExposure(
            allocator,
            ch_idx,
            "",
            "",
            null,
        );
    }

    return .{
        .series = .{
            .root = root_copy,
            .positions = positions,
            .times = times,
            .zs = zs,
            .channels = channels,
            .files = files,
        },
        .channel_info = channel_info,
        .backend = .{ .nd2_file = file },
    };
}

fn loadNd2Moment(
    allocator: std.mem.Allocator,
    file: *nd2.Nd2File,
    series: *const Series,
    position: []const u8,
    time: u32,
    z: u32,
) !tiff_frame.Moment {
    var pos_idx: usize = 0;
    for (series.positions, 0..) |pos_name, idx| {
        if (std.mem.eql(u8, pos_name, position)) {
            pos_idx = idx;
            break;
        }
    }

    const sz = try file.sizes();
    const width: u32 = @intCast(sz.X);
    const height: u32 = @intCast(sz.Y);

    var channels: std.ArrayList(tiff_frame.LoadedChannel) = .empty;
    errdefer {
        for (channels.items) |*ch| ch.deinit(allocator);
        channels.deinit(allocator);
    }

    for (series.channels) |ch| {
        const raw_pixels = try file.readFrame2d(pos_idx, time, ch, z);
        defer file.allocator.free(raw_pixels);

        const pixels = try allocator.dupe(u16, raw_pixels);
        errdefer allocator.free(pixels);

        try channels.append(allocator, .{
            .channel = ch,
            .plane = .{
                .width = width,
                .height = height,
                .pixels = pixels,
            },
        });
    }

    if (channels.items.len == 0) return error.NoChannelFilesFound;

    return .{
        .position = try allocator.dupe(u8, position),
        .time = time,
        .z = z,
        .channels = try channels.toOwnedSlice(allocator),
    };
}

/// Scan a directory (and immediate child directories) for Micro-Manager TIFF files.
pub fn scan_series(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
) !Series {
    var files: std.ArrayList(FrameEntry) = .empty;
    errdefer {
        for (files.items) |*entry| entry.deinit(allocator);
        files.deinit(allocator);
    }

    try visit_dir(allocator, io, root, &files);

    if (files.items.len == 0) {
        return error.NoMicroManagerTiffFilesFound;
    }

    var positions_list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (positions_list.items) |p| allocator.free(p);
        positions_list.deinit(allocator);
    }
    var times_list: std.ArrayList(u32) = .empty;
    errdefer times_list.deinit(allocator);
    var zs_list: std.ArrayList(u32) = .empty;
    errdefer zs_list.deinit(allocator);
    var channels_list: std.ArrayList(u32) = .empty;
    errdefer channels_list.deinit(allocator);

    for (files.items) |entry| {
        if (!containsString(positions_list.items, entry.axes.position)) {
            const p = try allocator.dupe(u8, entry.axes.position);
            errdefer allocator.free(p);
            try positions_list.append(allocator, p);
        }
        if (std.mem.indexOfScalar(u32, times_list.items, entry.axes.time) == null) {
            try times_list.append(allocator, entry.axes.time);
        }
        if (std.mem.indexOfScalar(u32, zs_list.items, entry.axes.z) == null) {
            try zs_list.append(allocator, entry.axes.z);
        }
        if (std.mem.indexOfScalar(u32, channels_list.items, entry.axes.channel) == null) {
            try channels_list.append(allocator, entry.axes.channel);
        }
    }

    std.mem.sort([]u8, positions_list.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return natural_cmp(a, b) == .lt;
        }
    }.lessThan);
    std.mem.sort(u32, times_list.items, {}, std.sort.asc(u32));
    std.mem.sort(u32, zs_list.items, {}, std.sort.asc(u32));
    std.mem.sort(u32, channels_list.items, {}, std.sort.asc(u32));

    const root_copy = try allocator.dupe(u8, root);
    errdefer allocator.free(root_copy);

    return .{
        .root = root_copy,
        .positions = try positions_list.toOwnedSlice(allocator),
        .times = try times_list.toOwnedSlice(allocator),
        .zs = try zs_list.toOwnedSlice(allocator),
        .channels = try channels_list.toOwnedSlice(allocator),
        .files = try files.toOwnedSlice(allocator),
    };
}

pub fn open_series(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
) !OpenedSeries {
    var series = try scan_series(allocator, io, root);
    errdefer series.deinit(allocator);

    const first_pos = if (series.positions.len > 0) series.positions[0] else "";
    const first_t = if (series.times.len > 0) series.times[0] else 0;
    const first_z = if (series.zs.len > 0) series.zs[0] else 0;

    var channel_info = try allocator.alloc(metadata.ChannelIdentity, series.channels.len);
    var ch_init: usize = 0;
    errdefer {
        for (channel_info[0..ch_init]) |*ci| ci.deinit(allocator);
        allocator.free(channel_info);
    }

    for (series.channels, 0..) |ch, i| {
        const sample_path = series.get(first_pos, first_t, first_z, ch) orelse blk: {
            for (series.files) |entry| {
                if (entry.axes.channel == ch) break :blk entry.path;
            }
            break :blk null;
        };

        if (sample_path) |p| {
            var props = metadata.read_mm_properties(allocator, io, p) catch metadata.PropertyMap{};
            defer props.deinit(allocator);
            channel_info[i] = try metadata.identify_channel(allocator, ch, &props);
        } else {
            var empty_props = metadata.PropertyMap{};
            channel_info[i] = try metadata.identify_channel(allocator, ch, &empty_props);
        }
        ch_init += 1;
    }

    return .{
        .series = series,
        .channel_info = channel_info,
        .backend = .mm_tiff,
    };
}

fn visit_dir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    out: *std.ArrayList(FrameEntry),
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        errdefer allocator.free(full_path);

        if (entry.kind == .directory) {
            try visit_dir(allocator, io, full_path, out);
            allocator.free(full_path);
        } else if (entry.kind == .file and is_tiff(entry.name)) {
            if (try parse_mm_filename(allocator, entry.name)) |axes| {
                try out.append(allocator, .{
                    .axes = axes,
                    .path = full_path,
                });
            } else {
                allocator.free(full_path);
            }
        } else {
            allocator.free(full_path);
        }
    }
}

pub fn is_tiff(name: []const u8) bool {
    return hasExtensionIgnoreCase(name, ".tif") or hasExtensionIgnoreCase(name, ".tiff");
}

pub fn hasExtensionIgnoreCase(path: []const u8, expected_ext: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, expected_ext);
}

/// Parse filenames like `img_channel000_position012_time000000083_z000.tif`
/// or `60x_water_1_MMStack_1-Pos001_003.ome.tif`.
pub fn parse_mm_filename(
    allocator: std.mem.Allocator,
    name: []const u8,
) !?Axes {
    const stem = stripTiffStem(name);

    const channel = extract_number(stem, "channel") orelse 0;
    const time = extract_number(stem, "time") orelse 0;
    const z = extract_number(stem, "_z") orelse extract_number(stem, "z") orelse 0;

    var position: []u8 = undefined;
    if (extract_token(stem, "position")) |pos_str| {
        if (std.fmt.parseInt(u32, pos_str, 10)) |num| {
            position = try std.fmt.allocPrint(allocator, "s{d}", .{num + 1});
        } else |_| {
            position = try allocator.dupe(u8, pos_str);
        }
    } else if (extract_token(stem, "Pos")) |pos_str| {
        position = try std.fmt.allocPrint(allocator, "Pos{s}", .{pos_str});
    } else if (std.mem.indexOf(u8, stem, "channel") != null or std.mem.indexOf(u8, stem, "time") != null) {
        position = try allocator.dupe(u8, "Default");
    } else {
        return null;
    }

    return .{
        .position = position,
        .time = time,
        .z = z,
        .channel = channel,
    };
}

fn stripTiffStem(name: []const u8) []const u8 {
    if (std.ascii.endsWithIgnoreCase(name, ".ome.tif")) {
        return name[0 .. name.len - ".ome.tif".len];
    }
    if (std.ascii.endsWithIgnoreCase(name, ".ome.tiff")) {
        return name[0 .. name.len - ".ome.tiff".len];
    }
    if (std.ascii.endsWithIgnoreCase(name, ".tiff")) {
        return name[0 .. name.len - ".tiff".len];
    }
    if (std.ascii.endsWithIgnoreCase(name, ".tif")) {
        return name[0 .. name.len - ".tif".len];
    }
    return name;
}

fn extract_number(stem: []const u8, key: []const u8) ?u32 {
    const digits = extract_digits(stem, key) orelse return null;
    return std.fmt.parseInt(u32, digits, 10) catch null;
}

fn extract_digits(stem: []const u8, key: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, stem, key) orelse return null;
    const rest = stem[start + key.len ..];
    var len: usize = 0;
    while (len < rest.len and std.ascii.isDigit(rest[len])) : (len += 1) {}
    if (len == 0) return null;
    return rest[0..len];
}

fn extract_token(stem: []const u8, key: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, stem, key) orelse return null;
    const rest = stem[start + key.len ..];
    var len: usize = 0;
    while (len < rest.len and (std.ascii.isAlphanumeric(rest[len]) or rest[len] == '-')) : (len += 1) {}
    if (len == 0) return null;
    return rest[0..len];
}

fn containsString(list: []const []const u8, target: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, target)) return true;
    }
    return false;
}

pub fn natural_cmp(a: []const u8, b: []const u8) std.math.Order {
    var ia: usize = 0;
    var ib: usize = 0;

    while (ia < a.len and ib < b.len) {
        const ca = a[ia];
        const cb = b[ib];
        if (std.ascii.isDigit(ca) and std.ascii.isDigit(cb)) {
            var na: u64 = 0;
            while (ia < a.len and std.ascii.isDigit(a[ia])) : (ia += 1) {
                na = na * 10 + @as(u64, a[ia] - '0');
            }
            var nb: u64 = 0;
            while (ib < b.len and std.ascii.isDigit(b[ib])) : (ib += 1) {
                nb = nb * 10 + @as(u64, b[ib] - '0');
            }
            const ord = std.math.order(na, nb);
            if (ord != .eq) return ord;
        } else {
            const ord = std.math.order(ca, cb);
            if (ord != .eq) return ord;
            ia += 1;
            ib += 1;
        }
    }

    return std.math.order(a.len - ia, b.len - ib);
}

test "parses_standard_micro_manager_filename" {
    const allocator = std.testing.allocator;
    var axes = (try parse_mm_filename(allocator, "img_channel001_position009_time000000042_z003.tif")).?;
    defer axes.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), axes.channel);
    try std.testing.expectEqualStrings("s10", axes.position);
    try std.testing.expectEqual(@as(u32, 42), axes.time);
    try std.testing.expectEqual(@as(u32, 3), axes.z);
}

test "natural_sort_orders_s2_before_s10" {
    try std.testing.expectEqual(std.math.Order.lt, natural_cmp("s2", "s10"));
}
