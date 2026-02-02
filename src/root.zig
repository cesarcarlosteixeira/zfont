//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const path = std.fs.path;
const mem = std.mem;

pub const base_url = "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/";

pub const IoError = error{
    CreateTemporaryZipFile,
    CreateTemporaryDirectory,
    CreateFontDirectory,
    CreateTemporaryWalker,
    CreateFontWalker,
    DeleteTemporaryDirectory,
    DeleteTemporaryZipFile,
    OpenTemporaryDirectory,
    OpenPrefixDirectory,
    OpenTemporaryZipFile,
    OpenFontDirectory,
    FailedZipExtraction,
    WalkerEntry,
    SaveFontFile,
    SetFontFile,
    CopyFontFile,
    DeleteFontFile,
    DeleteFontDirectory,
    ReadPrefixPath,
    CheckFontPath,
    FlushTemporaryZipFile,
};

pub const DownloadError = error{InvalidHttpResponse};
pub const FontError = DownloadError || mem.Allocator.Error || error{FontNotFound} || IoError;

pub fn downloadFonts(allocator: mem.Allocator, font_names: []const []const u8, prefix: []const u8) !void {
    var prefix_dir = try openPrefixDir(prefix, .{ .iterate = true });
    defer prefix_dir.close();

    for (font_names) |font_name| {
        try downloadFont(allocator, font_name, prefix_dir);
    }
}

pub fn setFont(allocator: mem.Allocator, font: []const u8, prefix: []const u8) FontError!void {
    var prefix_dir = openPrefixDir(prefix, .{}) catch return IoError.OpenPrefixDirectory;
    defer prefix_dir.close();

    const font_path = font_path: {
        const font_file_name = try mem.concat(allocator, u8, &.{ font, ".ttf" });
        defer allocator.free(font_file_name);

        const res = try path.join(allocator, &.{ "fonts", font_file_name });
        break :font_path res;
    };

    defer allocator.free(font_path);

    std.log.info("copying font file at {s}/{s} to {s}/font.ttf", .{ prefix, font_path, prefix });
    prefix_dir.copyFile(font_path, prefix_dir, "font.ttf", .{}) catch return IoError.SetFontFile;
}

pub fn listFonts(allocator: mem.Allocator, prefix: []const u8) FontError![]const []const u8 {
    var fonts: std.ArrayList([]const u8) = .empty;

    var prefix_dir = openPrefixDir(prefix, .{}) catch return IoError.OpenPrefixDirectory;

    std.log.debug("opening font dir {s}/fonts", .{prefix});
    var font_dir = prefix_dir.openDir("fonts", .{ .iterate = true }) catch return IoError.OpenFontDirectory;

    defer {
        prefix_dir.close();
        font_dir.close();
    }

    var walker = font_dir.walk(allocator) catch return IoError.CreateFontWalker;
    defer walker.deinit();

    while (walker.next() catch return IoError.WalkerEntry) |entry| {
        const name = try allocator.dupe(u8, path.stem(entry.basename));
        try fonts.append(allocator, name);
    }

    return try fonts.toOwnedSlice(allocator);
}

pub fn removeFonts(allocator: mem.Allocator, fonts: []const []const u8, prefix: []const u8, current_font: bool) !void {
    var prefix_dir = try openPrefixDir(prefix, .{});
    defer prefix_dir.close();

    for (fonts) |font| {
        try removeFont(allocator, font, prefix_dir);
    }

    if (current_font)
        try removeCurrentFont(prefix_dir, prefix);
}

pub fn removeAllFonts(prefix: []const u8, exclude_current_font: bool) !void {
    var prefix_dir = try openPrefixDir(prefix, .{});
    defer prefix_dir.close();

    std.log.info("deleting {s}/fonts/", .{prefix});
    prefix_dir.deleteTree("fonts") catch return IoError.DeleteFontDirectory;

    if (!exclude_current_font)
        try removeCurrentFont(prefix_dir, prefix);
}

fn removeCurrentFont(prefix_dir: std.fs.Dir, prefix: []const u8) !void {
    std.log.info("deleting {s}/font.ttf", .{prefix});
    prefix_dir.deleteFile("font.ttf") catch return IoError.DeleteFontFile;
}

fn downloadFont(allocator: mem.Allocator, font_name: []const u8, prefix_dir: std.fs.Dir) FontError!void {
    var prefix_buff: [std.fs.max_path_bytes]u8 = undefined;
    const prefix = try prefixFromDir(prefix_dir, &prefix_buff);

    prefix_dir.deleteDir("tmp") catch |err| if (err != error.FileNotFound) return IoError.DeleteTemporaryDirectory;
    prefix_dir.makeDir("tmp") catch return IoError.OpenTemporaryDirectory;

    var tmp_dir = prefix_dir.openDir("tmp", .{ .iterate = true }) catch return IoError.OpenTemporaryDirectory;
    var font_dir = prefix_dir.openDir("fonts", .{}) catch |err| switch (err) {
        error.FileNotFound => not_found: {
            std.log.debug("{s}/fonts don't exist, creating it", .{prefix});
            prefix_dir.makeDir("fonts") catch return IoError.CreateFontDirectory;
            break :not_found prefix_dir.openDir("fonts", .{}) catch return IoError.CreateFontDirectory;
        },
        else => return IoError.OpenFontDirectory,
    };

    defer {
        tmp_dir.close();
        font_dir.close();

        std.log.debug("deleting {s}/tmp/", .{prefix});
        prefix_dir.deleteTree("tmp") catch {};

        std.log.debug("deleting {s}/tmp.zig", .{prefix});
        prefix_dir.deleteFile("tmp.zig") catch {};
    }

    prefix_dir.deleteFile(
        "tmp.zig",
    ) catch |err| if (err != error.FileNotFound) return IoError.DeleteTemporaryDirectory;

    std.log.debug("creating tmp.zig file in {s}", .{prefix});
    var zip_file = prefix_dir.createFile(
        "tmp.zig",
        .{ .read = true },
    ) catch return IoError.CreateTemporaryZipFile;
    defer zip_file.close();

    const mb = 1 << 20;
    const file_bufs_size = 8 * mb;

    const file_writer_buf = try allocator.alloc(u8, file_bufs_size);
    const file_reader_buf = try allocator.alloc(u8, file_bufs_size);
    defer {
        allocator.free(file_writer_buf);
        allocator.free(file_reader_buf);
    }
    var zip_file_writer = zip_file.writer(file_writer_buf);
    var zip_file_reader = zip_file.reader(file_reader_buf);
    var zip_writer = &zip_file_writer.interface;

    try fetchFont(allocator, font_name, zip_writer);

    zip_writer.flush() catch return IoError.FlushTemporaryZipFile;

    std.log.debug("extracting to tmp.zig", .{});
    std.zip.extract(tmp_dir, &zip_file_reader, .{}) catch |err| {
        std.debug.print("{}\n", .{err});
        return IoError.FailedZipExtraction;
    };

    return saveFont(allocator, tmp_dir, prefix_dir, font_name);
}

fn fetchFont(allocator: mem.Allocator, font_name: []const u8, writer: *std.Io.Writer) !void {
    const url = try std.fmt.allocPrint(
        allocator,
        base_url ++ "{s}.zip",
        .{font_name},
    );
    defer allocator.free(url);

    std.log.info("fetching {s}...", .{url});
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const res = client.fetch(
        .{
            .response_writer = writer,
            .method = .GET,
            .location = .{ .url = url },
        },
    ) catch return DownloadError.InvalidHttpResponse;

    if (res.status != .ok) {
        return DownloadError.InvalidHttpResponse;
    }
}

fn saveFont(
    allocator: mem.Allocator,
    stored_dir: std.fs.Dir,
    prefix_dir: std.fs.Dir,
    font_name: []const u8,
) !void {
    const save_file_path = try mem.concat(allocator, u8, &.{ font_name, ".ttf" });
    defer allocator.free(save_file_path);
    const save_path = try path.join(
        allocator,
        &.{ "fonts", save_file_path },
    );
    defer allocator.free(save_path);

    if (exists(prefix_dir, save_path) catch return IoError.CheckFontPath) {
        std.log.info("font save path {s} already exists, deleting it", .{save_path});
        std.fs.deleteFileAbsolute(
            save_path,
        ) catch return IoError.DeleteFontFile;
    }

    var walker = stored_dir.walk(allocator) catch return IoError.CreateTemporaryWalker;
    defer walker.deinit();

    while (walker.next() catch return IoError.WalkerEntry) |entry| {
        if (entry.kind == .file and try isRegularFont(allocator, entry.basename, font_name)) {
            const font_path = try path.join(allocator, &.{ "tmp", entry.basename });
            defer allocator.free(font_path);

            std.log.info("saving font {s} at {s}", .{ font_name, save_path });
            prefix_dir.copyFile(font_path, prefix_dir, save_path, .{}) catch return IoError.SaveFontFile;
            return;
        }
    }

    return error.FontNotFound;
}

fn removeFont(
    allocator: mem.Allocator,
    font: []const u8,
    prefix_dir: std.fs.Dir,
) FontError!void {
    var prefix_buf: [std.fs.max_path_bytes]u8 = undefined;
    const prefix = try prefixFromDir(prefix_dir, &prefix_buf);

    const font_file_path = try mem.concat(allocator, u8, &.{ font, ".ttf" });
    defer allocator.free(font_file_path);

    const font_path = try path.join(allocator, &.{ "fonts", font_file_path });
    defer allocator.free(font_path);

    std.log.info("deleting font file at {s}/{s}", .{ prefix, font_path });
    prefix_dir.deleteFile(font_path) catch return IoError.DeleteFontFile;
}

fn exists(dir: std.fs.Dir, sub_path: []const u8) !bool {
    _ = dir.statFile(sub_path) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.IsDir => return true,
        error.FileBusy => return true,
        error.FileTooBig => return true,
        else => return err,
    };

    return true;
}

fn existsAbsolute(abs_path: []const u8) !bool {
    var dir = std.fs.openDirAbsolute(abs_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.NotDir => return true,
        else => return err,
    };
    defer dir.close();

    return true;
}
fn isRegularFont(
    allocator: mem.Allocator,
    basename: []const u8,
    font_name: []const u8,
) !bool {
    const expected_form = try std.fmt.allocPrint(
        allocator,
        "{s}NerdFont-Regular.ttf",
        .{font_name},
    );
    defer allocator.free(expected_form);

    return mem.eql(u8, expected_form, basename);
}

fn openPrefixDir(prefix: []const u8, flags: std.fs.Dir.OpenOptions) !std.fs.Dir {
    std.log.debug("opening prefix directory {s}", .{prefix});
    return std.fs.openDirAbsolute(prefix, flags) catch return IoError.OpenFontDirectory;
}

fn prefixFromDir(dir: std.fs.Dir, buf: []u8) ![]const u8 {
    return dir.realpath(".", buf) catch return IoError.ReadPrefixPath;
}

test "downloading fonts" {
    const allocator = std.testing.allocator;
    var buf: [std.fs.max_name_bytes]u8 = undefined;

    const tmp = std.testing.tmpDir(.{ .iterate = true });
    const tmp_path = try tmp.dir.realpath(".", &buf);

    const fonts = &.{ "0xProto", "3270" };

    try downloadFonts(allocator, fonts, tmp_path);

    try setFont(allocator, "0xProto", tmp_path);
    try setFont(allocator, "3270", tmp_path);

    const has_valid_structure = access: {
        var res = true;
        inline for (fonts) |font| {
            const font_path = try path.join(
                allocator,
                &.{ "fonts", font ++ ".ttf" },
            );
            defer allocator.free(font_path);
            if (!try exists(tmp.dir, font_path)) {
                res = false;
            }
        }

        if (try exists(tmp.dir, "tmp") or
            try exists(tmp.dir, "tmp.zig"))
            res = false;

        if (!try exists(tmp.dir, "font.ttf"))
            res = false;

        break :access res;
    };
    try std.testing.expect(has_valid_structure);

    const font_names = try listFonts(allocator, tmp_path);
    defer {
        for (font_names) |font_name| {
            allocator.free(font_name);
        }

        allocator.free(font_names);
    }

    try std.testing.expect(font_names.len == fonts.len);
    const valid_font_names = compare: {
        const runtime_fonts: []const []const u8 = font_names;
        for (font_names, 0..) |font_name, idx| {
            if (!mem.eql(u8, font_name, runtime_fonts[idx])) {
                break :compare false;
            }
        }

        break :compare true;
    };
    try std.testing.expect(valid_font_names);

    const removal = access: {
        var res = true;
        try removeFonts(allocator, &.{"0xProto"}, tmp_path, true);

        res = res and !(try exists(tmp.dir, "fonts/0xProto.ttf"));
        res = res and !(try exists(tmp.dir, "font.ttf"));
        res = res and try exists(tmp.dir, "fonts/3270.ttf");
        break :access res;
    };
    try std.testing.expect(removal);

    try downloadFonts(allocator, &.{"3270"}, tmp_path);
    try std.testing.expect(try exists(tmp.dir, "fonts/3270.ttf"));

    const full_removal = access: {
        try removeAllFonts(tmp_path, true);
        break :access !(try exists(tmp.dir, "fonts/"));
    };
    try std.testing.expect(full_removal);
}
