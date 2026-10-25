const std = @import("std");

pub const Plane = struct {
    width: u32,
    height: u32,
    pixels: []u16,

    pub fn deinit(self: *Plane, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

pub const LoadedChannel = struct {
    channel: u32,
    plane: Plane,

    pub fn deinit(self: *LoadedChannel, allocator: std.mem.Allocator) void {
        self.plane.deinit(allocator);
        self.* = undefined;
    }
};

pub const Moment = struct {
    position: []u8,
    time: u32,
    z: u32,
    channels: []LoadedChannel,

    pub fn deinit(self: *Moment, allocator: std.mem.Allocator) void {
        allocator.free(self.position);
        for (self.channels) |*ch| {
            ch.deinit(allocator);
        }
        allocator.free(self.channels);
        self.* = undefined;
    }
};

pub const TiffError = error{
    InvalidTiffHeader,
    InvalidIfdOffset,
    MissingDimensions,
    UnsupportedBitsPerSample,
    UnsupportedCompression,
    CorruptStripData,
};

pub fn read_plane(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !Plane {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const bytes = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(bytes);

    _ = try file.readPositionalAll(io, bytes, 0);
    return read_plane_bytes(allocator, bytes);
}

pub fn read_plane_bytes(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !Plane {
    if (bytes.len < 8) return error.InvalidTiffHeader;
    const endian: std.builtin.Endian = if (std.mem.eql(u8, bytes[0..2], "II"))
        .little
    else if (std.mem.eql(u8, bytes[0..2], "MM"))
        .big
    else
        return error.InvalidTiffHeader;

    const magic = readU16(bytes[2..4], endian);
    if (magic != 42) return error.InvalidTiffHeader;

    const ifd_offset = readU32(bytes[4..8], endian);
    if (ifd_offset + 2 > bytes.len) return error.InvalidIfdOffset;

    const entry_count = readU16(bytes[ifd_offset .. ifd_offset + 2], endian);
    const entries_start = ifd_offset + 2;
    if (entries_start + @as(usize, entry_count) * 12 > bytes.len) return error.InvalidIfdOffset;

    var width: u32 = 0;
    var height: u32 = 0;
    var bits_per_sample: u16 = 8;
    var compression: u16 = 1;
    var samples_per_pixel: u16 = 1;
    var rows_per_strip: u32 = std.math.maxInt(u32);
    var predictor: u16 = 1;

    var strip_offsets: std.ArrayList(u64) = .empty;
    defer strip_offsets.deinit(allocator);
    var strip_byte_counts: std.ArrayList(u64) = .empty;
    defer strip_byte_counts.deinit(allocator);

    var idx: usize = 0;
    while (idx < entry_count) : (idx += 1) {
        const entry_bytes = bytes[entries_start + idx * 12 ..][0..12];
        const tag = readU16(entry_bytes[0..2], endian);
        const field_type = readU16(entry_bytes[2..4], endian);
        const count = readU32(entry_bytes[4..8], endian);
        const val_bytes = entry_bytes[8..12];

        switch (tag) {
            256 => width = try readSingleU32(bytes, endian, field_type, count, val_bytes),
            257 => height = try readSingleU32(bytes, endian, field_type, count, val_bytes),
            258 => bits_per_sample = @intCast(try readFirstFromTagList(bytes, endian, field_type, count, val_bytes)),
            259 => compression = @intCast(try readSingleU32(bytes, endian, field_type, count, val_bytes)),
            273 => try readTagU64List(allocator, bytes, endian, field_type, count, val_bytes, &strip_offsets),
            277 => samples_per_pixel = @intCast(try readSingleU32(bytes, endian, field_type, count, val_bytes)),
            278 => rows_per_strip = try readSingleU32(bytes, endian, field_type, count, val_bytes),
            279 => try readTagU64List(allocator, bytes, endian, field_type, count, val_bytes, &strip_byte_counts),
            317 => predictor = @intCast(try readSingleU32(bytes, endian, field_type, count, val_bytes)),
            else => {},
        }
    }

    if (width == 0 or height == 0) return error.MissingDimensions;
    if (bits_per_sample != 8 and bits_per_sample != 16) return error.UnsupportedBitsPerSample;
    if (strip_offsets.items.len == 0) return error.CorruptStripData;

    const bytes_per_sample: usize = bits_per_sample / 8;
    const spp: usize = @max(@as(usize, samples_per_pixel), 1);
    const row_bytes = @as(usize, width) * spp * bytes_per_sample;
    const total_raw_bytes = row_bytes * @as(usize, height);

    const raw_buf = try allocator.alloc(u8, total_raw_bytes);
    defer allocator.free(raw_buf);
    @memset(raw_buf, 0);

    var write_pos: usize = 0;
    for (strip_offsets.items, 0..) |offset_u64, strip_idx| {
        if (write_pos >= total_raw_bytes) break;
        const offset: usize = @intCast(offset_u64);
        const remaining_out = total_raw_bytes - write_pos;
        const expected_strip_rows = if (rows_per_strip >= height)
            @as(usize, height)
        else
            @min(@as(usize, rows_per_strip), (remaining_out + row_bytes - 1) / row_bytes);
        const expected_uncompressed = @min(remaining_out, expected_strip_rows * row_bytes);

        const byte_count: usize = if (strip_idx < strip_byte_counts.items.len and strip_byte_counts.items[strip_idx] > 0)
            @intCast(strip_byte_counts.items[strip_idx])
        else
            expected_uncompressed;

        if (offset + byte_count > bytes.len) return error.CorruptStripData;
        const strip_src = bytes[offset .. offset + byte_count];
        const strip_dst = raw_buf[write_pos .. write_pos + expected_uncompressed];

        switch (compression) {
            1 => {
                const copy_len = @min(strip_src.len, strip_dst.len);
                @memcpy(strip_dst[0..copy_len], strip_src[0..copy_len]);
            },
            8, 32946 => {
                try decompressZlibStrip(allocator, strip_src, strip_dst);
            },
            32773 => {
                decompressPackBitsStrip(strip_src, strip_dst);
            },
            else => return error.UnsupportedCompression,
        }

        if (predictor == 2) {
            applyHorizontalDifferencing(strip_dst, @intCast(width), spp, bytes_per_sample, endian);
        }

        write_pos += expected_uncompressed;
    }

    const pixel_count = @as(usize, width) * @as(usize, height);
    const pixels = try allocator.alloc(u16, pixel_count);
    errdefer allocator.free(pixels);

    var p: usize = 0;
    while (p < pixel_count) : (p += 1) {
        const sample_base = p * spp * bytes_per_sample;
        if (bits_per_sample == 8) {
            if (spp == 1) {
                pixels[p] = raw_buf[sample_base];
            } else {
                var sum: u32 = 0;
                const channels = @min(spp, 3);
                for (0..channels) |c| {
                    sum += raw_buf[sample_base + c];
                }
                pixels[p] = @intCast(sum / @as(u32, @intCast(channels)));
            }
        } else {
            if (spp == 1) {
                pixels[p] = std.mem.readInt(u16, raw_buf[sample_base..][0..2], endian);
            } else {
                var sum: u32 = 0;
                const channels = @min(spp, 3);
                for (0..channels) |c| {
                    const v = std.mem.readInt(u16, raw_buf[sample_base + c * 2 ..][0..2], endian);
                    sum += v;
                }
                pixels[p] = @intCast(sum / @as(u32, @intCast(channels)));
            }
        }
    }

    return .{
        .width = width,
        .height = height,
        .pixels = pixels,
    };
}

fn decompressZlibStrip(
    allocator: std.mem.Allocator,
    compressed: []const u8,
    dst: []u8,
) !void {
    var in_reader = std.Io.Reader.fixed(compressed);
    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var zlib_stream = std.compress.flate.Decompress.init(&in_reader, .zlib, &window_buf);

    var out_writer = std.Io.Writer.Allocating.init(allocator);
    defer out_writer.deinit();

    _ = zlib_stream.reader.streamRemaining(&out_writer.writer) catch return error.CorruptStripData;
    const copy_len = @min(out_writer.written().len, dst.len);
    @memcpy(dst[0..copy_len], out_writer.written()[0..copy_len]);
}

fn decompressPackBitsStrip(compressed: []const u8, dst: []u8) void {
    var in_pos: usize = 0;
    var out_pos: usize = 0;
    while (in_pos < compressed.len and out_pos < dst.len) {
        const header: i8 = @bitCast(compressed[in_pos]);
        in_pos += 1;
        if (header >= 0) {
            const count: usize = @as(usize, @intCast(header)) + 1;
            const avail = @min(count, @min(compressed.len - in_pos, dst.len - out_pos));
            @memcpy(dst[out_pos .. out_pos + avail], compressed[in_pos .. in_pos + avail]);
            in_pos += avail;
            out_pos += avail;
        } else if (header != -128) {
            if (in_pos >= compressed.len) break;
            const count: usize = @as(usize, @intCast(1 - @as(isize, header)));
            const val = compressed[in_pos];
            in_pos += 1;
            const avail = @min(count, dst.len - out_pos);
            @memset(dst[out_pos .. out_pos + avail], val);
            out_pos += avail;
        }
    }
}

fn applyHorizontalDifferencing(
    buf: []u8,
    width: usize,
    spp: usize,
    bytes_per_sample: usize,
    endian: std.builtin.Endian,
) void {
    const row_bytes = width * spp * bytes_per_sample;
    if (row_bytes == 0) return;
    const rows = buf.len / row_bytes;
    var r: usize = 0;
    while (r < rows) : (r += 1) {
        const row = buf[r * row_bytes .. (r + 1) * row_bytes];
        if (bytes_per_sample == 1) {
            var i: usize = spp;
            while (i < row_bytes) : (i += 1) {
                row[i] +%= row[i - spp];
            }
        } else if (bytes_per_sample == 2) {
            var px: usize = spp;
            while (px < width * spp) : (px += 1) {
                const prev = std.mem.readInt(u16, row[(px - spp) * 2 ..][0..2], endian);
                const cur = std.mem.readInt(u16, row[px * 2 ..][0..2], endian);
                std.mem.writeInt(u16, row[px * 2 ..][0..2], cur +% prev, endian);
            }
        }
    }
}

fn readU16(bytes: []const u8, endian: std.builtin.Endian) u16 {
    return std.mem.readInt(u16, bytes[0..2], endian);
}

fn readU32(bytes: []const u8, endian: std.builtin.Endian) u32 {
    return std.mem.readInt(u32, bytes[0..4], endian);
}

fn readSingleU32(
    bytes: []const u8,
    endian: std.builtin.Endian,
    field_type: u16,
    count: u32,
    val_bytes: *const [4]u8,
) !u32 {
    return @intCast(try readFirstFromTagList(bytes, endian, field_type, count, val_bytes));
}

fn readFirstFromTagList(
    bytes: []const u8,
    endian: std.builtin.Endian,
    field_type: u16,
    count: u32,
    val_bytes: *const [4]u8,
) !u64 {
    if (count == 0) return 0;
    const elem_size: usize = switch (field_type) {
        1, 2, 6, 7 => 1,
        3, 8 => 2,
        4, 9 => 4,
        16 => 8,
        else => 4,
    };
    const total_bytes = elem_size * @as(usize, count);
    const data_slice = if (total_bytes <= 4)
        val_bytes[0..total_bytes]
    else blk: {
        const offset: usize = readU32(val_bytes, endian);
        if (offset + elem_size > bytes.len) return error.InvalidIfdOffset;
        break :blk bytes[offset .. offset + elem_size];
    };
    return switch (elem_size) {
        1 => data_slice[0],
        2 => readU16(data_slice[0..2], endian),
        4 => readU32(data_slice[0..4], endian),
        8 => std.mem.readInt(u64, data_slice[0..8], endian),
        else => 0,
    };
}

fn readTagU64List(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    endian: std.builtin.Endian,
    field_type: u16,
    count: u32,
    val_bytes: *const [4]u8,
    out: *std.ArrayList(u64),
) !void {
    out.clearRetainingCapacity();
    if (count == 0) return;

    const elem_size: usize = switch (field_type) {
        1, 2, 6, 7 => 1,
        3, 8 => 2,
        4, 9 => 4,
        16 => 8,
        else => return error.InvalidIfdOffset,
    };
    const total_bytes = elem_size * @as(usize, count);
    const data_slice = if (total_bytes <= 4)
        val_bytes[0..total_bytes]
    else blk: {
        const offset: usize = readU32(val_bytes, endian);
        if (offset + total_bytes > bytes.len) return error.InvalidIfdOffset;
        break :blk bytes[offset .. offset + total_bytes];
    };

    try out.ensureTotalCapacity(allocator, count);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const chunk = data_slice[i * elem_size .. (i + 1) * elem_size];
        const val: u64 = switch (elem_size) {
            1 => chunk[0],
            2 => readU16(chunk[0..2], endian),
            4 => readU32(chunk[0..4], endian),
            8 => std.mem.readInt(u64, chunk[0..8], endian),
            else => unreachable,
        };
        out.appendAssumeCapacity(val);
    }
}

/// Helper to build an uncompressed 16-bit little-endian grayscale TIFF in memory for testing.
pub fn encodeTestTiffU16Le(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: []const u16,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // Header: "II", 42, IFD offset = 8
    try out.appendSlice(allocator, "II");
    try appendU16Le(allocator, &out, 42);
    try appendU32Le(allocator, &out, 8);

    const entry_count: u16 = 7;
    const pixel_data_offset: u32 = 8 + 2 + @as(u32, entry_count) * 12 + 4;
    const byte_count: u32 = width * height * 2;

    try appendU16Le(allocator, &out, entry_count);
    try appendIfdEntryLe(allocator, &out, 256, 4, 1, width); // ImageWidth
    try appendIfdEntryLe(allocator, &out, 257, 4, 1, height); // ImageLength
    try appendIfdEntryLe(allocator, &out, 258, 3, 1, 16); // BitsPerSample = 16
    try appendIfdEntryLe(allocator, &out, 259, 3, 1, 1); // Compression = 1 (Uncompressed)
    try appendIfdEntryLe(allocator, &out, 273, 4, 1, pixel_data_offset); // StripOffsets
    try appendIfdEntryLe(allocator, &out, 278, 4, 1, height); // RowsPerStrip
    try appendIfdEntryLe(allocator, &out, 279, 4, 1, byte_count); // StripByteCounts
    try appendU32Le(allocator, &out, 0); // next IFD offset = 0

    for (pixels) |px| {
        try appendU16Le(allocator, &out, px);
    }

    return out.toOwnedSlice(allocator);
}

fn appendU16Le(allocator: std.mem.Allocator, out: *std.ArrayList(u8), v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try out.appendSlice(allocator, &b);
}

fn appendU32Le(allocator: std.mem.Allocator, out: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(allocator, &b);
}

fn appendIfdEntryLe(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    tag: u16,
    field_type: u16,
    count: u32,
    value: u32,
) !void {
    try appendU16Le(allocator, out, tag);
    try appendU16Le(allocator, out, field_type);
    try appendU32Le(allocator, out, count);
    if (field_type == 3 and count == 1) {
        try appendU16Le(allocator, out, @intCast(value));
        try appendU16Le(allocator, out, 0);
    } else {
        try appendU32Le(allocator, out, value);
    }
}

test "decodes_16bit_grayscale_tiff_in_memory" {
    const allocator = std.testing.allocator;
    const expected = [_]u16{ 120, 4095, 1024, 65535 };
    const tiff_bytes = try encodeTestTiffU16Le(allocator, 2, 2, &expected);
    defer allocator.free(tiff_bytes);

    var plane = try read_plane_bytes(allocator, tiff_bytes);
    defer plane.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 2), plane.width);
    try std.testing.expectEqual(@as(u32, 2), plane.height);
    try std.testing.expectEqualSlices(u16, &expected, plane.pixels);
}
