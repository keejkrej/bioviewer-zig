const std = @import("std");

pub const ChannelIdentity = struct {
    name: []u8,
    detail: []u8,
    color: [3]u8,
    suggested_gain: f32,

    pub fn clone(self: ChannelIdentity, allocator: std.mem.Allocator) !ChannelIdentity {
        const name_copy = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name_copy);
        const detail_copy = try allocator.dupe(u8, self.detail);
        return .{
            .name = name_copy,
            .detail = detail_copy,
            .color = self.color,
            .suggested_gain = self.suggested_gain,
        };
    }

    pub fn deinit(self: *ChannelIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.detail);
        self.* = undefined;
    }
};

pub const PropertyMap = struct {
    map: std.StringHashMapUnmanaged([]u8) = .empty,

    pub fn deinit(self: *PropertyMap, allocator: std.mem.Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.map.deinit(allocator);
    }

    pub fn get(self: *const PropertyMap, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    pub fn put(self: *PropertyMap, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        if (self.map.fetchRemove(key)) |removed| {
            allocator.free(removed.key);
            allocator.free(removed.value);
        }
        const k = try allocator.dupe(u8, key);
        errdefer allocator.free(k);
        const v = try allocator.dupe(u8, value);
        errdefer allocator.free(v);
        try self.map.put(allocator, k, v);
    }
};

/// Read a Micro-Manager UTF-16LE JSON property map from the beginning of a TIFF file.
pub fn read_mm_properties(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !PropertyMap {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const read_len: usize = @intCast(@min(stat.size, 1024 * 1024));
    const buf = try allocator.alloc(u8, read_len);
    defer allocator.free(buf);

    _ = try file.readPositionalAll(io, buf, 0);
    return parse_mm_properties(allocator, buf);
}

pub fn parse_mm_properties(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !PropertyMap {
    var out = PropertyMap{};
    errdefer out.deinit(allocator);

    const needle = [_]u8{ '"', 0, 'W', 0, 'i', 0, 'd', 0, 't', 0, 'h', 0, '"', 0 };
    const start_hint = findSubslice(bytes, &needle) orelse return out;

    const search_from = start_hint -| 256;
    const open_brace = [_]u8{ '{', 0 };
    const rel_open = findLastSubslice(bytes[search_from .. start_hint + 2], &open_brace) orelse 0;
    const json_start = search_from + rel_open;

    const rest = bytes[json_start..];
    const u16_count = @min(rest.len / 2, 65536);

    var utf8_buf = try std.ArrayList(u8).initCapacity(allocator, u16_count);
    defer utf8_buf.deinit(allocator);

    var i: usize = 0;
    while (i < u16_count) : (i += 1) {
        const unit = std.mem.readInt(u16, rest[i * 2 ..][0..2], .little);
        if (unit == 0) continue;
        if (unit < 0x80) {
            try utf8_buf.append(allocator, @intCast(unit));
        } else if (unit < 0x800) {
            try utf8_buf.append(allocator, @intCast(0xC0 | (unit >> 6)));
            try utf8_buf.append(allocator, @intCast(0x80 | (unit & 0x3F)));
        } else if (unit >= 0xD800 and unit <= 0xDFFF) {
            try utf8_buf.append(allocator, '?');
        } else {
            try utf8_buf.append(allocator, @intCast(0xE0 | (unit >> 12)));
            try utf8_buf.append(allocator, @intCast(0x80 | ((unit >> 6) & 0x3F)));
            try utf8_buf.append(allocator, @intCast(0x80 | (unit & 0x3F)));
        }
    }

    const keys = [_][]const u8{
        "TIFilterBlock1-Label",
        "ZeissReflectorTurret-Label",
        "Channel",
        "HamamatsuHam_DCAM-Exposure",
        "Exposure-ms",
    };
    for (keys) |key| {
        if (extractJsonStringOrNumber(allocator, utf8_buf.items, key) catch null) |val| {
            defer allocator.free(val);
            try out.put(allocator, key, val);
        }
    }

    return out;
}

fn extractJsonStringOrNumber(
    allocator: std.mem.Allocator,
    text: []const u8,
    key: []const u8,
) !?[]u8 {
    const pattern = try std.fmt.allocPrint(allocator, "\"{s}\":", .{key});
    defer allocator.free(pattern);

    const pos = std.mem.indexOf(u8, text, pattern) orelse return null;
    const after = std.mem.trimStart(u8, text[pos + pattern.len ..], " \t\r\n");
    if (after.len == 0) return null;

    if (after[0] == '"') {
        const rest = after[1..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
        return try allocator.dupe(u8, rest[0..end]);
    } else {
        var end: usize = 0;
        while (end < after.len) : (end += 1) {
            const c = after[end];
            if (c == ',' or c == '}' or c == '\n' or c == '\r') break;
        }
        const trimmed = std.mem.trim(u8, after[0..end], " \t");
        if (trimmed.len == 0) return null;
        return try allocator.dupe(u8, trimmed);
    }
}

pub fn identify_channel(
    allocator: std.mem.Allocator,
    channel_index: u32,
    props: *const PropertyMap,
) !ChannelIdentity {
    const filter = props.get("TIFilterBlock1-Label") orelse
        props.get("ZeissReflectorTurret-Label") orelse "";
    const channel = props.get("Channel") orelse "";
    const exposure = props.get("HamamatsuHam_DCAM-Exposure") orelse
        props.get("Exposure-ms");

    const source = if (filter.len != 0) filter else channel;
    return identifyFromLabelAndExposure(allocator, channel_index, source, filter, exposure);
}

pub fn identifyFromLabelAndExposure(
    allocator: std.mem.Allocator,
    channel_index: u32,
    source: []const u8,
    filter: []const u8,
    exposure: ?[]const u8,
) !ChannelIdentity {
    var base_name: []u8 = undefined;
    var color: [3]u8 = undefined;
    var gain: f32 = 1.0;

    if (matchesAnyIgnoreCase(source, &.{ "3-Cy3", "Cy3", "TRITC", "RFP", "mCherry", "AF555", "Alexa 568" })) {
        base_name = try allocator.dupe(u8, "Cy3");
        color = .{ 255, 150, 40 };
        gain = 1.25;
    } else if (matchesAnyIgnoreCase(source, &.{ "2-FITC", "FITC", "GFP", "EGFP", "AF488", "Alexa 488" })) {
        base_name = try allocator.dupe(u8, "FITC");
        color = .{ 70, 235, 120 };
        gain = 1.25;
    } else if (matchesAnyIgnoreCase(source, &.{ "1-DAPI", "DAPI", "Hoechst", "BFP", "AF405" })) {
        base_name = try allocator.dupe(u8, "DAPI");
        color = .{ 80, 155, 255 };
        gain = 1.2;
    } else if (matchesAnyIgnoreCase(source, &.{ "4-Cy5", "Cy5", "AF647", "Alexa 647", "Draq5" })) {
        base_name = try allocator.dupe(u8, "Cy5");
        color = .{ 255, 75, 150 };
        gain = 1.25;
    } else if (matchesAnyIgnoreCase(source, &.{ "5-BF", "BF", "Brightfield", "TL", "Phase", "DIC", "Trans" })) {
        base_name = try allocator.dupe(u8, "Brightfield");
        color = .{ 235, 235, 235 };
        gain = 1.0;
    } else {
        const fallback_palette = [_][3]u8{
            .{ 235, 235, 235 },
            .{ 255, 150, 40 },
            .{ 70, 235, 120 },
            .{ 80, 155, 255 },
            .{ 255, 75, 150 },
        };
        if (source.len == 0) {
            base_name = try std.fmt.allocPrint(allocator, "Channel {d}", .{channel_index});
        } else {
            base_name = try allocator.dupe(u8, source);
        }
        color = fallback_palette[channel_index % fallback_palette.len];
        gain = 1.0;
    }
    errdefer allocator.free(base_name);

    var detail_list: std.ArrayList(u8) = .empty;
    defer detail_list.deinit(allocator);

    const ch_str = try std.fmt.allocPrint(allocator, "ch{d}", .{channel_index});
    defer allocator.free(ch_str);
    try detail_list.appendSlice(allocator, ch_str);

    if (filter.len != 0) {
        try detail_list.appendSlice(allocator, " · ");
        try detail_list.appendSlice(allocator, filter);
    }
    if (exposure) |exp| {
        if (exp.len != 0) {
            try detail_list.appendSlice(allocator, " · ");
            try detail_list.appendSlice(allocator, exp);
            try detail_list.appendSlice(allocator, " ms");
        }
    }

    return .{
        .name = base_name,
        .detail = try detail_list.toOwnedSlice(allocator),
        .color = color,
        .suggested_gain = gain,
    };
}

fn matchesAnyIgnoreCase(source: []const u8, candidates: []const []const u8) bool {
    if (source.len == 0) return false;
    for (candidates) |cand| {
        if (std.ascii.eqlIgnoreCase(source, cand)) return true;
        if (containsIgnoreCase(source, cand)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn findSubslice(haystack: []const u8, needle: []const u8) ?usize {
    return std.mem.indexOf(u8, haystack, needle);
}

fn findLastSubslice(haystack: []const u8, needle: []const u8) ?usize {
    return std.mem.lastIndexOf(u8, haystack, needle);
}

test "parses_utf16_micro_manager_filter_label" {
    const allocator = std.testing.allocator;
    const json = "{\"Width\": 2048, \"TIFilterBlock1-Label\": \"3-Cy3\", \"HamamatsuHam_DCAM-Exposure\": \"299.80\"}";
    var utf16 = try std.ArrayList(u8).initCapacity(allocator, json.len * 2);
    defer utf16.deinit(allocator);
    for (json) |ch| {
        try utf16.append(allocator, ch);
        try utf16.append(allocator, 0);
    }

    var props = try parse_mm_properties(allocator, utf16.items);
    defer props.deinit(allocator);

    var id = try identify_channel(allocator, 1, &props);
    defer id.deinit(allocator);

    try std.testing.expectEqualStrings("Cy3", id.name);
    try std.testing.expectEqual([3]u8{ 255, 150, 40 }, id.color);
    try std.testing.expect(std.mem.indexOf(u8, id.detail, "3-Cy3") != null);
}

test "identifies_brightfield_and_cy3" {
    const allocator = std.testing.allocator;
    var bf_props = PropertyMap{};
    defer bf_props.deinit(allocator);
    try bf_props.put(allocator, "TIFilterBlock1-Label", "5-BF");

    var bf = try identify_channel(allocator, 0, &bf_props);
    defer bf.deinit(allocator);
    try std.testing.expectEqualStrings("Brightfield", bf.name);
    try std.testing.expectEqual([3]u8{ 235, 235, 235 }, bf.color);

    var cy3_props = PropertyMap{};
    defer cy3_props.deinit(allocator);
    try cy3_props.put(allocator, "TIFilterBlock1-Label", "3-Cy3");

    var cy3 = try identify_channel(allocator, 1, &cy3_props);
    defer cy3.deinit(allocator);
    try std.testing.expectEqualStrings("Cy3", cy3.name);
    try std.testing.expectEqual([3]u8{ 255, 150, 40 }, cy3.color);
}
