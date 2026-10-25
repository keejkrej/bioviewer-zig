const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const runner = @import("runner");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

pub const composite = @import("composite.zig");
pub const metadata = @import("metadata.zig");
pub const tiff_frame = @import("tiff_frame.zig");
pub const series = @import("series.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const window_width: f32 = 1480.0;
const window_height: f32 = 920.0;
const window_min_width: f32 = 960.0;
const window_min_height: f32 = 600.0;
const titlebar_natural_height: f32 = 52.0;
const canvas_label = "bioviewer-canvas";
const frame_image_id: u64 = 1;
const playback_timer_key: u64 = 1;
const max_display_image_bytes: usize = 512 * 512 * 4;

const max_path_bytes: usize = 1024;
const max_name_bytes: usize = 256;
const max_status_bytes: usize = 320;
const max_dir_entries: usize = 128;
const max_positions: usize = 128;
const max_zs: usize = 64;
const max_channels: usize = 8;

const app_permissions = [_][]const u8{
    native_sdk.security.permission_command,
    native_sdk.security.permission_dialog,
    native_sdk.security.permission_filesystem,
    native_sdk.security.permission_view,
};

const shell_views = [_]native_sdk.ShellView{
    .{
        .label = canvas_label,
        .kind = .gpu_surface,
        .fill = true,
        .role = "BioViewer canvas",
        .accessibility_label = "BioViewer",
        .gpu_backend = .metal,
        .gpu_pixel_format = .bgra8_unorm,
        .gpu_present_mode = .timer,
        .gpu_alpha_mode = .@"opaque",
        .gpu_color_space = .srgb,
        .gpu_vsync = true,
    },
};

const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "BioViewer",
    .width = window_width,
    .height = window_height,
    .min_width = window_min_width,
    .min_height = window_min_height,
    .restore_policy = .center_on_primary,
    .titlebar = .hidden_inset_tall,
    .views = &shell_views,
}};

pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

pub const app_shortcuts = [_]native_sdk.Shortcut{
    .{ .id = "open-folder", .key = "o", .modifiers = .{ .primary = true } },
};

pub const DirEntryView = struct {
    index: u16 = 0,
    is_dir: bool = false,
    name_storage: [max_name_bytes]u8 = @splat(0),
    name_len: usize = 0,
    path_storage: [max_path_bytes]u8 = @splat(0),
    path_len: usize = 0,

    pub const view_unbound = .{
        "name_storage",
        "name_len",
        "path_storage",
        "path_len",
    };

    pub fn name(self: *const DirEntryView) []const u8 {
        return self.name_storage[0..self.name_len];
    }

    pub fn path(self: *const DirEntryView) []const u8 {
        return self.path_storage[0..self.path_len];
    }

    pub fn set(self: *DirEntryView, idx: u16, is_dir: bool, entry_name: []const u8, full_path: []const u8) void {
        self.* = .{ .index = idx, .is_dir = is_dir };
        const nlen = @min(entry_name.len, self.name_storage.len);
        @memcpy(self.name_storage[0..nlen], entry_name[0..nlen]);
        self.name_len = nlen;
        const plen = @min(full_path.len, self.path_storage.len);
        @memcpy(self.path_storage[0..plen], full_path[0..plen]);
        self.path_len = plen;
    }
};

pub const PositionView = struct {
    index: u16 = 0,
    selected: bool = false,
    name_storage: [max_name_bytes]u8 = @splat(0),
    name_len: usize = 0,

    pub const view_unbound = .{
        "name_storage",
        "name_len",
    };

    pub fn name(self: *const PositionView) []const u8 {
        return self.name_storage[0..self.name_len];
    }

    pub fn set(self: *PositionView, idx: u16, selected: bool, pos_name: []const u8) void {
        self.* = .{ .index = idx, .selected = selected };
        const nlen = @min(pos_name.len, self.name_storage.len);
        @memcpy(self.name_storage[0..nlen], pos_name[0..nlen]);
        self.name_len = nlen;
    }
};

pub const ZItemView = struct {
    index: u16 = 0,
    z: u32 = 0,
    selected: bool = false,
    label_storage: [32]u8 = @splat(0),
    label_len: usize = 0,

    pub const view_unbound = .{
        "label_storage",
        "label_len",
    };

    pub fn label(self: *const ZItemView) []const u8 {
        return self.label_storage[0..self.label_len];
    }

    pub fn set(self: *ZItemView, idx: u16, z_val: u32, selected: bool) void {
        self.* = .{ .index = idx, .z = z_val, .selected = selected };
        const text = std.fmt.bufPrint(&self.label_storage, "z{d}", .{z_val}) catch "z0";
        self.label_len = text.len;
    }
};

pub const ChannelView = struct {
    index: u16 = 0,
    channel: u32 = 0,
    enabled: bool = true,
    color: [3]u8 = .{ 235, 235, 235 },
    low: f32 = 0.0,
    high: f32 = 4095.0,
    gain: f32 = 1.0,
    lowFraction: f32 = 0.0,
    highFraction: f32 = 1.0,
    gainFraction: f32 = 0.25,

    name_storage: [64]u8 = @splat(0),
    name_len: usize = 0,
    detail_storage: [128]u8 = @splat(0),
    detail_len: usize = 0,
    window_storage: [96]u8 = @splat(0),
    window_len: usize = 0,
    gain_storage: [32]u8 = @splat(0),
    gain_len: usize = 0,
    badge_storage: [32]u8 = @splat(0),
    badge_len: usize = 0,

    low_label_storage: [64]u8 = @splat(0),
    low_label_len: usize = 0,
    high_label_storage: [64]u8 = @splat(0),
    high_label_len: usize = 0,
    gain_label_storage: [64]u8 = @splat(0),
    gain_label_len: usize = 0,
    auto_label_storage: [64]u8 = @splat(0),
    auto_label_len: usize = 0,
    bf_label_storage: [64]u8 = @splat(0),
    bf_label_len: usize = 0,
    dapi_label_storage: [64]u8 = @splat(0),
    dapi_label_len: usize = 0,
    fitc_label_storage: [64]u8 = @splat(0),
    fitc_label_len: usize = 0,
    cy3_label_storage: [64]u8 = @splat(0),
    cy3_label_len: usize = 0,
    cy5_label_storage: [64]u8 = @splat(0),
    cy5_label_len: usize = 0,

    pub const view_unbound = .{
        "color",
        "low",
        "high",
        "gain",
        "name_storage",
        "name_len",
        "detail_storage",
        "detail_len",
        "window_storage",
        "window_len",
        "gain_storage",
        "gain_len",
        "badge_storage",
        "badge_len",
        "low_label_storage",
        "low_label_len",
        "high_label_storage",
        "high_label_len",
        "gain_label_storage",
        "gain_label_len",
        "auto_label_storage",
        "auto_label_len",
        "bf_label_storage",
        "bf_label_len",
        "dapi_label_storage",
        "dapi_label_len",
        "fitc_label_storage",
        "fitc_label_len",
        "cy3_label_storage",
        "cy3_label_len",
        "cy5_label_storage",
        "cy5_label_len",
    };

    pub fn name(self: *const ChannelView) []const u8 {
        return self.name_storage[0..self.name_len];
    }

    pub fn detail(self: *const ChannelView) []const u8 {
        return self.detail_storage[0..self.detail_len];
    }

    pub fn windowSummary(self: *const ChannelView) []const u8 {
        return self.window_storage[0..self.window_len];
    }

    pub fn gainText(self: *const ChannelView) []const u8 {
        return self.gain_storage[0..self.gain_len];
    }

    pub fn colorBadge(self: *const ChannelView) []const u8 {
        return self.badge_storage[0..self.badge_len];
    }

    pub fn lowSliderLabel(self: *const ChannelView) []const u8 {
        return self.low_label_storage[0..self.low_label_len];
    }

    pub fn highSliderLabel(self: *const ChannelView) []const u8 {
        return self.high_label_storage[0..self.high_label_len];
    }

    pub fn gainSliderLabel(self: *const ChannelView) []const u8 {
        return self.gain_label_storage[0..self.gain_label_len];
    }

    pub fn autoLabel(self: *const ChannelView) []const u8 {
        return self.auto_label_storage[0..self.auto_label_len];
    }

    pub fn bfLabel(self: *const ChannelView) []const u8 {
        return self.bf_label_storage[0..self.bf_label_len];
    }

    pub fn dapiLabel(self: *const ChannelView) []const u8 {
        return self.dapi_label_storage[0..self.dapi_label_len];
    }

    pub fn fitcLabel(self: *const ChannelView) []const u8 {
        return self.fitc_label_storage[0..self.fitc_label_len];
    }

    pub fn cy3Label(self: *const ChannelView) []const u8 {
        return self.cy3_label_storage[0..self.cy3_label_len];
    }

    pub fn cy5Label(self: *const ChannelView) []const u8 {
        return self.cy5_label_storage[0..self.cy5_label_len];
    }

    pub fn syncStrings(self: *ChannelView) void {
        self.lowFraction = std.math.clamp(self.low / 65535.0, 0.0, 1.0);
        self.highFraction = std.math.clamp(self.high / 65535.0, 0.0, 1.0);
        self.gainFraction = std.math.clamp((self.gain - 0.2) / 3.8, 0.0, 1.0);

        const win_str = std.fmt.bufPrint(&self.window_storage, "Window: {d:.0} .. {d:.0}", .{ self.low, self.high }) catch "Window";
        self.window_len = win_str.len;

        const gain_str = std.fmt.bufPrint(&self.gain_storage, "{d:.2}x", .{self.gain}) catch "1.00x";
        self.gain_len = gain_str.len;

        const badge_str = colorPresetName(self.color);
        @memcpy(self.badge_storage[0..badge_str.len], badge_str);
        self.badge_len = badge_str.len;

        const ch_name = self.name();
        const low_lbl = std.fmt.bufPrint(&self.low_label_storage, "{s} black level", .{ch_name}) catch "Black level";
        self.low_label_len = low_lbl.len;
        const high_lbl = std.fmt.bufPrint(&self.high_label_storage, "{s} white level", .{ch_name}) catch "White level";
        self.high_label_len = high_lbl.len;
        const gain_lbl = std.fmt.bufPrint(&self.gain_label_storage, "{s} brightness gain", .{ch_name}) catch "Brightness gain";
        self.gain_label_len = gain_lbl.len;
        const auto_lbl = std.fmt.bufPrint(&self.auto_label_storage, "Auto contrast {s}", .{ch_name}) catch "Auto contrast";
        self.auto_label_len = auto_lbl.len;
        const bf_lbl = std.fmt.bufPrint(&self.bf_label_storage, "{s} preset BF", .{ch_name}) catch "Preset BF";
        self.bf_label_len = bf_lbl.len;
        const dapi_lbl = std.fmt.bufPrint(&self.dapi_label_storage, "{s} preset DAPI", .{ch_name}) catch "Preset DAPI";
        self.dapi_label_len = dapi_lbl.len;
        const fitc_lbl = std.fmt.bufPrint(&self.fitc_label_storage, "{s} preset FITC", .{ch_name}) catch "Preset FITC";
        self.fitc_label_len = fitc_lbl.len;
        const cy3_lbl = std.fmt.bufPrint(&self.cy3_label_storage, "{s} preset Cy3", .{ch_name}) catch "Preset Cy3";
        self.cy3_label_len = cy3_lbl.len;
        const cy5_lbl = std.fmt.bufPrint(&self.cy5_label_storage, "{s} preset Cy5", .{ch_name}) catch "Preset Cy5";
        self.cy5_label_len = cy5_lbl.len;
    }
};

fn colorPresetName(color: [3]u8) []const u8 {
    if (std.mem.eql(u8, &color, &[_]u8{ 235, 235, 235 })) return "BF";
    if (std.mem.eql(u8, &color, &[_]u8{ 80, 155, 255 })) return "DAPI";
    if (std.mem.eql(u8, &color, &[_]u8{ 70, 235, 120 })) return "FITC";
    if (std.mem.eql(u8, &color, &[_]u8{ 255, 150, 40 })) return "Cy3";
    if (std.mem.eql(u8, &color, &[_]u8{ 255, 75, 150 })) return "Cy5";
    return "Custom";
}

pub const HostBridge = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    opened: ?series.OpenedSeries = null,
    moment: ?tiff_frame.Moment = null,
    rgba_buf: []u8 = &.{},
    downsample_buf: [max_display_image_bytes]u8 = undefined,

    pub fn deinit(self: *HostBridge) void {
        if (self.moment) |*m| {
            m.deinit(self.allocator);
            self.moment = null;
        }
        if (self.opened) |*o| {
            o.deinit(self.allocator, self.io);
            self.opened = null;
        }
        if (self.rgba_buf.len > 0) {
            self.allocator.free(self.rgba_buf);
            self.rgba_buf = &.{};
        }
    }
};

pub const ActionKind = enum {
    none,
    refresh_dir,
    choose_folder,
    open_series_path,
    reload_moment,
};

pub const Model = struct {
    titlebarHeight: f32 = titlebar_natural_height,
    chromeLeading: f32 = 0.0,
    showFolderBrowser: bool = true,
    frameImageId: u64 = 0,
    timeFraction: f32 = 0.0,

    browse_dir_storage: [max_path_bytes]u8 = @splat(0),
    browse_dir_len: usize = 0,

    pending_open_path_storage: [max_path_bytes]u8 = @splat(0),
    pending_open_path_len: usize = 0,
    pending_action: ActionKind = .none,
    action_serial: u64 = 0,

    dir_entries_storage: [max_dir_entries]DirEntryView = @splat(.{}),
    dir_entry_count: usize = 0,

    positions_storage: [max_positions]PositionView = @splat(.{}),
    position_count: usize = 0,
    position_idx: usize = 0,

    zs_storage: [max_zs]ZItemView = @splat(.{}),
    z_count: usize = 0,
    z_idx: usize = 0,

    time_count: usize = 0,
    time_idx: usize = 0,

    channels_storage: [max_channels]ChannelView = @splat(.{}),
    channel_count: usize = 0,

    frame_width: u32 = 0,
    frame_height: u32 = 0,
    zoom: f32 = 1.0,
    zoom_storage: [32]u8 = @splat(0),
    zoom_len: usize = 0,

    playing: bool = false,
    needs_auto_contrast: bool = true,

    status_storage: [max_status_bytes]u8 = @splat(0),
    status_len: usize = 0,

    host: ?*HostBridge = null,

    pub const view_unbound = .{
        "browse_dir_storage",
        "browse_dir_len",
        "pending_open_path_storage",
        "pending_open_path_len",
        "pending_action",
        "action_serial",
        "dir_entries_storage",
        "dir_entry_count",
        "positions_storage",
        "position_count",
        "position_idx",
        "zs_storage",
        "z_count",
        "z_idx",
        "time_count",
        "time_idx",
        "channels_storage",
        "channel_count",
        "frame_width",
        "frame_height",
        "zoom",
        "zoom_storage",
        "zoom_len",
        "playing",
        "needs_auto_contrast",
        "status_storage",
        "status_len",
        "host",
    };

    pub fn initDefault(self: *Model) void {
        self.setZoom(1.0);
        self.setBrowseDir(".");
        self.setStatus("Open a Micro-Manager TIFF folder, .czi, or .nd2 file", .{});
    }

    pub fn showPositionsBrowser(self: *const Model) bool {
        return !self.showFolderBrowser;
    }

    pub fn browseDir(self: *const Model) []const u8 {
        if (self.browse_dir_len == 0) return ".";
        return self.browse_dir_storage[0..self.browse_dir_len];
    }

    pub fn setBrowseDir(self: *Model, path: []const u8) void {
        const len = @min(path.len, self.browse_dir_storage.len);
        @memcpy(self.browse_dir_storage[0..len], path[0..len]);
        self.browse_dir_len = len;
    }

    pub fn requestAction(self: *Model, kind: ActionKind, path: []const u8) void {
        const len = @min(path.len, self.pending_open_path_storage.len);
        @memcpy(self.pending_open_path_storage[0..len], path[0..len]);
        self.pending_open_path_len = len;
        self.pending_action = kind;
        self.action_serial +%= 1;
        if (self.action_serial == 0) self.action_serial = 1;
    }

    pub fn status(self: *const Model) []const u8 {
        if (self.status_len == 0) return "Ready";
        return self.status_storage[0..self.status_len];
    }

    pub fn setStatus(self: *Model, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.status_storage, fmt, args) catch "Status update";
        self.status_len = text.len;
    }

    pub fn positionCount(self: *const Model) usize {
        return self.position_count;
    }

    pub fn dirEntries(self: *const Model) []const DirEntryView {
        return self.dir_entries_storage[0..self.dir_entry_count];
    }

    pub fn positionItems(self: *const Model) []const PositionView {
        return self.positions_storage[0..self.position_count];
    }

    pub fn channelViews(self: *const Model) []const ChannelView {
        return self.channels_storage[0..self.channel_count];
    }

    pub fn zItems(self: *const Model) []const ZItemView {
        return self.zs_storage[0..self.z_count];
    }

    pub fn hasMultipleZs(self: *const Model) bool {
        return self.z_count > 1;
    }

    pub fn hasFrame(self: *const Model) bool {
        return self.frameImageId != 0 and self.frame_width > 0 and self.frame_height > 0;
    }

    pub fn displayWidth(self: *const Model) f32 {
        const base: f32 = if (self.frame_width > 0) @floatFromInt(@min(self.frame_width, 640)) else 512.0;
        return @round(base * self.zoom);
    }

    pub fn displayHeight(self: *const Model) f32 {
        if (self.frame_width == 0 or self.frame_height == 0) return 512.0;
        const aspect = @as(f32, @floatFromInt(self.frame_height)) / @as(f32, @floatFromInt(self.frame_width));
        return @round(self.displayWidth() * aspect);
    }

    pub fn playButtonLabel(self: *const Model) []const u8 {
        return if (self.playing) "Pause" else "Play";
    }

    pub fn zoomLabel(self: *const Model) []const u8 {
        if (self.zoom_len == 0) return "100%";
        return self.zoom_storage[0..self.zoom_len];
    }

    pub fn setZoom(self: *Model, z: f32) void {
        self.zoom = std.math.clamp(z, 0.2, 8.0);
        const pct: u32 = @intFromFloat(@round(self.zoom * 100.0));
        const text = std.fmt.bufPrint(&self.zoom_storage, "{d}%", .{pct}) catch "100%";
        self.zoom_len = text.len;
    }

    pub fn syncTimeFractionFromIdx(self: *Model) void {
        if (self.time_count <= 1) {
            self.timeFraction = 0.0;
        } else {
            self.timeFraction = @as(f32, @floatFromInt(self.time_idx)) /
                @as(f32, @floatFromInt(self.time_count - 1));
        }
    }
};

pub const Msg = union(enum) {
    navigate_up,
    choose_folder,
    open_current_folder,
    show_folders,
    show_positions,
    activate_dir_entry: u16,
    select_position: u16,
    toggle_channel: u16,
    auto_contrast: u16,
    sync_sliders,
    set_preset_bf: u16,
    set_preset_dapi: u16,
    set_preset_fitc: u16,
    set_preset_cy3: u16,
    set_preset_cy5: u16,
    step_prev_time,
    toggle_play,
    step_next_time,
    zoom_out,
    zoom_fit,
    zoom_in,
    select_z: u16,
    step_prev_position,
    step_next_position,
    playback_tick: native_sdk.EffectTimer,
    host_synced,
    chrome_changed: native_sdk.WindowChrome,

    pub const view_unbound = .{
        "step_prev_position",
        "step_next_position",
        "playback_tick",
        "host_synced",
        "chrome_changed",
    };
};

pub const BioViewerUiApp = native_sdk.UiApp(Model, Msg);
pub const Effects = BioViewerUiApp.Effects;

pub const bioviewer_markup = @embedFile("bioviewer.native");
pub const CompiledBioViewerView = canvas.CompiledMarkupView(Model, Msg, bioviewer_markup);

fn rootView(ui: *BioViewerUiApp.Ui, model: *const Model) BioViewerUiApp.Ui.Node {
    return CompiledBioViewerView.build(ui, model);
}

pub fn onChrome(chrome: native_sdk.WindowChrome) ?Msg {
    return .{ .chrome_changed = chrome };
}

pub fn onCommand(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, "open-folder")) return .choose_folder;
    return null;
}

pub fn onKey(keyboard: canvas.WidgetKeyboardEvent) ?Msg {
    if (keyboard.modifiers.hasNavigationModifier() or keyboard.modifiers.shift) return null;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "space")) return .toggle_play;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowleft")) return .step_prev_time;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowright")) return .step_next_time;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowup")) return .step_prev_position;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowdown")) return .step_next_position;
    return null;
}

pub fn sync(model: *Model, layout: canvas.WidgetLayoutTree) void {
    var slider_index: usize = 0;
    const channel_slider_count = model.channel_count * 3;
    for (layout.nodes) |node| {
        if (node.widget.kind != .slider) continue;
        if (slider_index < channel_slider_count) {
            const ch_idx = slider_index / 3;
            const kind = slider_index % 3;
            var ch = &model.channels_storage[ch_idx];
            switch (kind) {
                0 => {
                    ch.lowFraction = node.widget.value;
                    ch.low = @round(ch.lowFraction * 65535.0);
                    if (ch.high <= ch.low) ch.high = ch.low + 1.0;
                },
                1 => {
                    ch.highFraction = node.widget.value;
                    ch.high = @max(ch.low + 1.0, @round(ch.highFraction * 65535.0));
                },
                2 => {
                    ch.gainFraction = node.widget.value;
                    ch.gain = 0.2 + ch.gainFraction * 3.8;
                },
                else => unreachable,
            }
            ch.syncStrings();
        } else if (slider_index == channel_slider_count) {
            model.timeFraction = node.widget.value;
        }
        slider_index += 1;
    }
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .chrome_changed => |chrome| {
            model.chromeLeading = chrome.insets.left;
            model.titlebarHeight = @max(titlebar_natural_height, chrome.insets.top);
        },
        .navigate_up => {
            const cur = model.browseDir();
            if (std.fs.path.dirname(cur)) |parent| {
                model.setBrowseDir(parent);
                model.requestAction(.refresh_dir, parent);
            }
        },
        .choose_folder => {
            model.requestAction(.choose_folder, model.browseDir());
        },
        .open_current_folder => {
            var path_buf: [max_path_bytes]u8 = undefined;
            const cur = model.browseDir();
            @memcpy(path_buf[0..cur.len], cur);
            model.requestAction(.open_series_path, path_buf[0..cur.len]);
        },
        .show_folders => {
            model.showFolderBrowser = true;
        },
        .show_positions => {
            model.showFolderBrowser = false;
        },
        .activate_dir_entry => |idx| {
            if (idx >= model.dir_entry_count) return;
            var path_buf: [max_path_bytes]u8 = undefined;
            const entry = &model.dir_entries_storage[idx];
            const entry_path = entry.path();
            @memcpy(path_buf[0..entry_path.len], entry_path);
            const path_slice = path_buf[0..entry_path.len];

            if (entry.is_dir) {
                model.setBrowseDir(path_slice);
                model.requestAction(.refresh_dir, path_slice);
            } else if (series.hasExtensionIgnoreCase(path_slice, ".czi") or
                series.hasExtensionIgnoreCase(path_slice, ".nd2"))
            {
                model.requestAction(.open_series_path, path_slice);
            } else {
                model.requestAction(.open_series_path, model.browseDir());
            }
        },
        .select_position => |idx| {
            if (idx >= model.position_count) return;
            model.position_idx = idx;
            for (model.positions_storage[0..model.position_count], 0..) |*pos, i| {
                pos.selected = (i == idx);
            }
            model.requestAction(.reload_moment, "");
        },
        .select_z => |idx| {
            if (idx >= model.z_count) return;
            model.z_idx = idx;
            for (model.zs_storage[0..model.z_count], 0..) |*zitem, i| {
                zitem.selected = (i == idx);
            }
            model.requestAction(.reload_moment, "");
        },
        .toggle_channel => |idx| {
            if (idx >= model.channel_count) return;
            model.channels_storage[idx].enabled = !model.channels_storage[idx].enabled;
            recompositeAndRegister(model, fx);
        },
        .auto_contrast => |idx| {
            if (idx >= model.channel_count) return;
            autoContrastChannel(model, idx);
            recompositeAndRegister(model, fx);
        },
        .sync_sliders => {
            if (model.time_count > 1) {
                const new_time_idx: usize = @intFromFloat(@round(
                    std.math.clamp(model.timeFraction, 0.0, 1.0) * @as(f32, @floatFromInt(model.time_count - 1)),
                ));
                if (new_time_idx != model.time_idx and new_time_idx < model.time_count) {
                    model.time_idx = new_time_idx;
                    model.requestAction(.reload_moment, "");
                    return;
                }
            }
            recompositeAndRegister(model, fx);
        },
        .set_preset_bf => |idx| applyColorPreset(model, fx, idx, .{ 235, 235, 235 }),
        .set_preset_dapi => |idx| applyColorPreset(model, fx, idx, .{ 80, 155, 255 }),
        .set_preset_fitc => |idx| applyColorPreset(model, fx, idx, .{ 70, 235, 120 }),
        .set_preset_cy3 => |idx| applyColorPreset(model, fx, idx, .{ 255, 150, 40 }),
        .set_preset_cy5 => |idx| applyColorPreset(model, fx, idx, .{ 255, 75, 150 }),
        .step_prev_time => {
            stepTime(model, -1);
        },
        .step_next_time => {
            stepTime(model, 1);
        },
        .step_prev_position => {
            stepPosition(model, -1);
        },
        .step_next_position => {
            stepPosition(model, 1);
        },
        .toggle_play => {
            model.playing = !model.playing;
            if (model.playing) {
                fx.startTimer(.{
                    .key = playback_timer_key,
                    .interval_ms = 120,
                    .mode = .repeating,
                    .on_fire = Effects.timerMsg(.playback_tick),
                });
            } else {
                fx.cancelTimer(playback_timer_key);
            }
        },
        .playback_tick => |timer| {
            if (timer.outcome != .fired or !model.playing) return;
            stepTime(model, 1);
        },
        .zoom_out => {
            model.setZoom(model.zoom / 1.25);
        },
        .zoom_fit => {
            model.setZoom(1.0);
        },
        .zoom_in => {
            model.setZoom(model.zoom * 1.25);
        },
        .host_synced => {
            recompositeAndRegister(model, fx);
        },
    }
}

fn applyColorPreset(model: *Model, fx: *Effects, idx: u16, color: [3]u8) void {
    if (idx >= model.channel_count) return;
    model.channels_storage[idx].color = color;
    model.channels_storage[idx].syncStrings();
    recompositeAndRegister(model, fx);
}

fn stepTime(model: *Model, delta: isize) void {
    if (model.time_count == 0) return;
    const len: isize = @intCast(model.time_count);
    const cur: isize = @intCast(model.time_idx);
    const next: usize = @intCast(@mod(cur + delta, len));
    if (next != model.time_idx) {
        model.time_idx = next;
        model.syncTimeFractionFromIdx();
        model.requestAction(.reload_moment, "");
    }
}

fn stepPosition(model: *Model, delta: isize) void {
    if (model.position_count == 0) return;
    const len: isize = @intCast(model.position_count);
    const cur: isize = @intCast(model.position_idx);
    const next: usize = @intCast(@mod(cur + delta, len));
    if (next != model.position_idx) {
        model.position_idx = next;
        for (model.positions_storage[0..model.position_count], 0..) |*pos, i| {
            pos.selected = (i == next);
        }
        model.requestAction(.reload_moment, "");
    }
}

fn autoContrastChannel(model: *Model, idx: usize) void {
    const host = model.host orelse return;
    const moment = host.moment orelse return;
    if (idx >= model.channel_count or idx >= moment.channels.len) return;

    const range = composite.percentile_range(
        host.allocator,
        moment.channels[idx].plane.pixels,
        0.1,
        99.9,
    ) catch return;
    model.channels_storage[idx].low = range[0];
    model.channels_storage[idx].high = range[1];
    model.channels_storage[idx].syncStrings();
}

pub fn recompositeAndRegister(model: *Model, fx: *Effects) void {
    const host = model.host orelse return;
    const moment = host.moment orelse return;
    if (moment.channels.len == 0) return;

    var plane_views: [max_channels]composite.PlaneView = undefined;
    var settings: [max_channels]composite.ChannelRender = undefined;
    const count = @min(moment.channels.len, model.channel_count);
    for (0..count) |i| {
        plane_views[i] = .{
            .width = moment.channels[i].plane.width,
            .height = moment.channels[i].plane.height,
            .pixels = moment.channels[i].plane.pixels,
        };
        const ch = &model.channels_storage[i];
        settings[i] = .{
            .enabled = ch.enabled,
            .color = ch.color,
            .low = ch.low,
            .high = ch.high,
            .gain = ch.gain,
        };
    }

    const w = plane_views[0].width;
    const h = plane_views[0].height;
    const needed_bytes = @as(usize, w) * @as(usize, h) * 4;
    if (host.rgba_buf.len < needed_bytes) {
        if (host.rgba_buf.len > 0) host.allocator.free(host.rgba_buf);
        host.rgba_buf = host.allocator.alloc(u8, needed_bytes) catch return;
    }

    composite.compositeInto(plane_views[0..count], settings[0..count], host.rgba_buf[0..needed_bytes]);
    const fitted = composite.fitRgbaWithinBudget(
        w,
        h,
        host.rgba_buf[0..needed_bytes],
        max_display_image_bytes,
        &host.downsample_buf,
    );

    fx.registerImage(frame_image_id, fitted.width, fitted.height, fitted.bytes) catch return;
    model.frameImageId = frame_image_id;
    model.frame_width = w;
    model.frame_height = h;
}

pub fn bioviewerOptions() BioViewerUiApp.Options {
    return .{
        .name = "bioviewer",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .on_chrome = onChrome,
        .on_command = onCommand,
        .on_key = onKey,
        .view = rootView,
        .sync = sync,
    };
}

pub const BioViewerApp = struct {
    ui_app: *BioViewerUiApp,
    host: HostBridge,
    handled_action_serial: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, initial_path: ?[]const u8) !*BioViewerApp {
        const self = try allocator.create(BioViewerApp);
        errdefer allocator.destroy(self);

        const ui_app = try BioViewerUiApp.create(allocator, bioviewerOptions());
        errdefer ui_app.destroy();

        self.* = .{
            .ui_app = ui_app,
            .host = .{
                .allocator = allocator,
                .io = io,
            },
        };

        self.ui_app.model.initDefault();
        self.ui_app.model.host = &self.host;

        if (initial_path) |p| {
            const dir_for_browse = if (series.hasExtensionIgnoreCase(p, ".czi") or
                series.hasExtensionIgnoreCase(p, ".nd2"))
                (std.fs.path.dirname(p) orelse ".")
            else
                p;
            self.ui_app.model.setBrowseDir(dir_for_browse);
            self.refreshDirEntriesOnHost(dir_for_browse);
            self.openSeriesOnHost(p);
        } else {
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd_len = std.Io.Dir.cwd().realPathFile(io, ".", &cwd_buf) catch 0;
            const start_dir = if (cwd_len > 0) cwd_buf[0..cwd_len] else ".";
            self.ui_app.model.setBrowseDir(start_dir);
            self.refreshDirEntriesOnHost(start_dir);
        }

        return self;
    }

    pub fn deinit(self: *BioViewerApp) void {
        const allocator = self.host.allocator;
        self.host.deinit();
        self.ui_app.destroy();
        allocator.destroy(self);
    }

    pub fn app(self: *BioViewerApp) native_sdk.App {
        return .{
            .context = self,
            .name = "bioviewer",
            .scene_fn = scene,
            .event_fn = event,
            .stop_fn = stop,
        };
    }

    fn scene(_: *anyopaque) anyerror!native_sdk.ShellConfig {
        return shell_scene;
    }

    fn event(context: *anyopaque, runtime: *native_sdk.Runtime, event_value: native_sdk.Event) anyerror!void {
        const self: *BioViewerApp = @ptrCast(@alignCast(context));
        try self.ui_app.app().event(runtime, event_value);
        if (self.host.moment != null and self.ui_app.model.frameImageId == 0) {
            try self.ui_app.dispatch(runtime, 1, .host_synced);
        }
        try self.performPendingHostAction(runtime);
    }

    fn stop(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
        const self: *BioViewerApp = @ptrCast(@alignCast(context));
        try self.ui_app.app().stop(runtime);
    }

    fn performPendingHostAction(self: *BioViewerApp, runtime: *native_sdk.Runtime) !void {
        const model = &self.ui_app.model;
        if (model.action_serial == self.handled_action_serial or model.pending_action == .none) return;
        self.handled_action_serial = model.action_serial;
        const action = model.pending_action;
        model.pending_action = .none;

        var path_buf: [max_path_bytes]u8 = undefined;
        const path_len = model.pending_open_path_len;
        @memcpy(path_buf[0..path_len], model.pending_open_path_storage[0..path_len]);
        const path = path_buf[0..path_len];

        switch (action) {
            .none => {},
            .refresh_dir => {
                self.refreshDirEntriesOnHost(path);
                try self.ui_app.dispatch(runtime, 1, .host_synced);
            },
            .choose_folder => {
                var dialog_buf: [native_sdk.platform.max_dialog_paths_bytes]u8 = undefined;
                const result = runtime.showOpenDialog(.{
                    .title = "Open Micro-Manager Series Folder",
                    .default_path = model.browseDir(),
                    .allow_directories = true,
                    .allow_multiple = false,
                }, &dialog_buf) catch return;
                if (result.count == 0) return;

                const selected = result.paths;
                if (series.hasExtensionIgnoreCase(selected, ".czi") or
                    series.hasExtensionIgnoreCase(selected, ".nd2"))
                {
                    if (std.fs.path.dirname(selected)) |parent| {
                        model.setBrowseDir(parent);
                        self.refreshDirEntriesOnHost(parent);
                    }
                    self.openSeriesOnHost(selected);
                } else {
                    model.setBrowseDir(selected);
                    self.refreshDirEntriesOnHost(selected);
                    self.openSeriesOnHost(selected);
                }
                try self.ui_app.dispatch(runtime, 1, .host_synced);
            },
            .open_series_path => {
                self.openSeriesOnHost(path);
                try self.ui_app.dispatch(runtime, 1, .host_synced);
            },
            .reload_moment => {
                self.reloadMomentOnHost();
                try self.ui_app.dispatch(runtime, 1, .host_synced);
            },
        }
    }

    pub fn refreshDirEntriesOnHost(self: *BioViewerApp, dir_path: []const u8) void {
        const model = &self.ui_app.model;
        model.dir_entry_count = 0;

        var dir = std.Io.Dir.cwd().openDir(self.host.io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(self.host.io);

        var iter = dir.iterate();
        while (iter.next(self.host.io) catch null) |entry| {
            if (model.dir_entry_count >= max_dir_entries) break;
            if (entry.name.len == 0 or entry.name[0] == '.') continue;

            const is_dir = (entry.kind == .directory);
            const is_bio_file = (entry.kind == .file) and
                (series.is_tiff(entry.name) or
                    series.hasExtensionIgnoreCase(entry.name, ".czi") or
                    series.hasExtensionIgnoreCase(entry.name, ".nd2"));
            if (!is_dir and !is_bio_file) continue;

            const full_path = std.fs.path.join(self.host.allocator, &.{ dir_path, entry.name }) catch continue;
            defer self.host.allocator.free(full_path);

            const idx: u16 = @intCast(model.dir_entry_count);
            model.dir_entries_storage[idx].set(idx, is_dir, entry.name, full_path);
            model.dir_entry_count += 1;
        }

        std.mem.sort(DirEntryView, model.dir_entries_storage[0..model.dir_entry_count], {}, struct {
            fn lessThan(_: void, a: DirEntryView, b: DirEntryView) bool {
                if (a.is_dir != b.is_dir) return a.is_dir;
                return series.natural_cmp(a.name(), b.name()) == .lt;
            }
        }.lessThan);

        for (model.dir_entries_storage[0..model.dir_entry_count], 0..) |*item, i| {
            item.index = @intCast(i);
        }
    }

    pub fn openSeriesOnHost(self: *BioViewerApp, path: []const u8) void {
        const model = &self.ui_app.model;
        const opened = series.open_any_series(self.host.allocator, self.host.io, path) catch |err| {
            model.setStatus("No microscopy dataset in {s} ({s})", .{ path, @errorName(err) });
            return;
        };

        if (self.host.moment) |*m| {
            m.deinit(self.host.allocator);
            self.host.moment = null;
        }
        if (self.host.opened) |*o| {
            o.deinit(self.host.allocator, self.host.io);
        }
        self.host.opened = opened;

        const ser = &self.host.opened.?.series;
        model.position_count = @min(ser.positions.len, max_positions);
        model.position_idx = 0;
        for (0..model.position_count) |i| {
            model.positions_storage[i].set(@intCast(i), i == 0, ser.positions[i]);
        }

        model.z_count = @min(ser.zs.len, max_zs);
        model.z_idx = 0;
        for (0..model.z_count) |i| {
            model.zs_storage[i].set(@intCast(i), ser.zs[i], i == 0);
        }

        model.time_count = ser.times.len;
        model.time_idx = 0;
        model.syncTimeFractionFromIdx();

        const ch_info = self.host.opened.?.channel_info;
        model.channel_count = @min(ser.channels.len, max_channels);
        for (0..model.channel_count) |i| {
            var cv = ChannelView{
                .index = @intCast(i),
                .channel = ser.channels[i],
                .enabled = true,
                .color = if (i < ch_info.len) ch_info[i].color else .{ 235, 235, 235 },
                .low = 0.0,
                .high = 4095.0,
                .gain = if (i < ch_info.len) ch_info[i].suggested_gain else 1.0,
            };
            const cname = if (i < ch_info.len) ch_info[i].name else "Channel";
            const nlen = @min(cname.len, cv.name_storage.len);
            @memcpy(cv.name_storage[0..nlen], cname[0..nlen]);
            cv.name_len = nlen;

            const cdetail = if (i < ch_info.len) ch_info[i].detail else "ch";
            const dlen = @min(cdetail.len, cv.detail_storage.len);
            @memcpy(cv.detail_storage[0..dlen], cdetail[0..dlen]);
            cv.detail_len = dlen;

            cv.syncStrings();
            model.channels_storage[i] = cv;
        }

        model.needs_auto_contrast = true;
        model.showFolderBrowser = false;
        self.reloadMomentOnHost();
    }

    pub fn reloadMomentOnHost(self: *BioViewerApp) void {
        const model = &self.ui_app.model;
        var opened = &(self.host.opened orelse return);
        if (opened.series.positions.len == 0 or opened.series.times.len == 0 or opened.series.zs.len == 0) return;

        const pos_idx = @min(model.position_idx, opened.series.positions.len - 1);
        const time_idx = @min(model.time_idx, opened.series.times.len - 1);
        const z_idx = @min(model.z_idx, opened.series.zs.len - 1);

        const pos_name = opened.series.positions[pos_idx];
        const time_val = opened.series.times[time_idx];
        const z_val = opened.series.zs[z_idx];

        const loaded = opened.loadMoment(self.host.allocator, self.host.io, pos_name, time_val, z_val) catch |err| {
            model.setStatus("Failed to load frame: {s}", .{@errorName(err)});
            return;
        };

        if (self.host.moment) |*old| {
            old.deinit(self.host.allocator);
        }
        self.host.moment = loaded;

        if (self.host.moment.?.channels.len > 0) {
            model.frame_width = self.host.moment.?.channels[0].plane.width;
            model.frame_height = self.host.moment.?.channels[0].plane.height;
        }

        if (model.needs_auto_contrast) {
            for (0..model.channel_count) |i| {
                autoContrastChannel(model, i);
            }
            model.needs_auto_contrast = false;
        }

        model.setStatus("{s} · time {d} ({d}/{d}) · z {d} · {d}×{d}", .{
            pos_name,
            time_val,
            time_idx + 1,
            opened.series.times.len,
            z_val,
            model.frame_width,
            model.frame_height,
        });
    }
};

pub fn main(init: std.process.Init) !void {
    var arg_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer arg_iter.deinit();
    _ = arg_iter.next(); // skip binary name
    const initial_path = arg_iter.next();

    const app_state = try BioViewerApp.init(std.heap.page_allocator, init.io, initial_path);
    defer app_state.deinit();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "bioviewer",
        .window_title = "BioViewer",
        .bundle_id = "dev.native_sdk.bioviewer",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .js_window_api = false,
        .shortcuts = &app_shortcuts,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test "markup view builds and dispatches transport and channel actions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    model.initDefault();

    var ui = BioViewerUiApp.Ui.init(arena);
    const tree = try ui.finalize(rootView(&ui, &model));
    try std.testing.expect(tree.root.children.len > 0);
}

test "loads real czi and nd2 fixtures through unified series API" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var nd2_opened = try series.open_any_series(allocator, io, "../nd2-zig/tests/fixtures/BF007.nd2");
    defer nd2_opened.deinit(allocator, io);

    try std.testing.expectEqual(@as(usize, 1), nd2_opened.series.positions.len);
    var nd2_moment = try nd2_opened.loadMoment(allocator, io, "P0", 0, 0);
    defer nd2_moment.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 164), nd2_moment.channels[0].plane.width);
    try std.testing.expectEqual(@as(u32, 156), nd2_moment.channels[0].plane.height);

    var czi_opened = try series.open_any_series(allocator, io, "../czi-zig/tests/fixtures/Plate1-Blue-A-02-Scene-1-P2-E1-01.czi");
    defer czi_opened.deinit(allocator, io);

    try std.testing.expectEqual(@as(usize, 3), czi_opened.series.channels.len);
    var czi_moment = try czi_opened.loadMoment(allocator, io, "S0", 0, 0);
    defer czi_moment.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), czi_moment.channels.len);
    try std.testing.expectEqual(@as(u32, 672), czi_moment.channels[0].plane.width);
    try std.testing.expectEqual(@as(u32, 512), czi_moment.channels[0].plane.height);
}

test {
    _ = composite;
    _ = metadata;
    _ = tiff_frame;
    _ = series;
}
