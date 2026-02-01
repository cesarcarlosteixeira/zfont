const std = @import("std");
const clap = @import("clap");
const zfont = @import("zfont");

const SubCommands = enum {
    download,
    set,
    list,
    remove,
};
const Params = []const clap.Param(clap.Help);

const main_parsers = .{
    .command = clap.parsers.enumeration(SubCommands),
};
const main_params = clap.parseParamsComptime(
    \\-h, --help
    \\<command>     download, remove, set, list
);

const CommandOptions = struct {
    allocator: std.mem.Allocator,
    iter: *std.process.ArgIterator,
    prefix: []const u8,
};

const MainArgs = clap.ResultEx(clap.Help, &main_params, main_parsers);

pub fn main() !void {
    const exit = std.process.exit;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var iter = try std.process.ArgIterator.initWithAllocator(allocator);
    defer iter.deinit();
    _ = iter.next();

    const prefix = prefix_init: {
        const alt_prefix = ".termux";

        const base_prefix = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => not_found: {
                std.log.warn("Could not find environment var $HOME, using {s} instead", .{alt_prefix});

                const cwd = try std.process.getCwdAlloc(allocator);

                const cwd_prefix = try std.fs.path.join(allocator, &.{ cwd, alt_prefix });
                defer allocator.free(cwd_prefix);

                break :not_found cwd_prefix;
            },

            else => {
                return err;
            },
        };
        defer allocator.free(base_prefix);

        const full_prefix = try std.fs.path.join(allocator, &.{ base_prefix, ".termux" });
        break :prefix_init full_prefix;
    };
    defer allocator.free(prefix);

    var diagnostic: clap.Diagnostic = .{};
    var res = clap.parseEx(
        clap.Help,
        &main_params,
        &main_parsers,
        &iter,
        .{
            .diagnostic = &diagnostic,
            .allocator = allocator,
            .terminating_positional = 0,
        },
    ) catch |err| {
        try diagnostic.reportToFile(.stderr(), err);
        exit(1);
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.helpToFile(.stderr(), clap.Help, &main_params, .{});
    }

    const command = res.positionals[0] orelse {
        try clap.helpToFile(.stderr(), clap.Help, &main_params, .{});
        return error.MissingCommand;
    };

    const command_options: CommandOptions = .{ .allocator = allocator, .iter = &iter, .prefix = prefix };

    const command_err = switch (command) {
        .download => downloadMain(command_options),
        .set => setMain(command_options),
        .list => listMain(command_options),
        .remove => removeMain(command_options),
    };

    command_err catch |err| {
        std.log.err("{}{s}", .{ err, guide(err) });
        exit(1);
    };
}

fn guide(source: anyerror) []const u8 {
    return switch (source) {
        error.OpenPrefixDirectory => ", does ~/.termux exists?",
        error.InvalidHttpResponse => ", is the font available at " ++ zfont.base_url ++ "?",
        error.SetFontFile => ", is the font saved?",
        error.DeleteFontFile => ", does the font file exists?",
        else => "",
    };
}

fn downloadMain(opts: CommandOptions) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help
        \\<string>... fonts to download
    );
    var res = try getResults(opts.allocator, &params, opts.iter);
    defer res.deinit();

    if (res.args.help != 0) {
        return sendHelp(&params);
    }

    if (res.positionals[0].len < 1) {
        return error.MissingFonts;
    }

    try zfont.downloadFonts(opts.allocator, res.positionals[0], opts.prefix);
}

fn setMain(opts: CommandOptions) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help
        \\<string> font to set
    );

    var res = try getResults(opts.allocator, &params, opts.iter);
    defer res.deinit();

    if (res.args.help != 0) {
        return sendHelp(&params);
    }

    const font = res.positionals[0] orelse return error.MissingFont;
    try zfont.setFont(opts.allocator, font, opts.prefix);
}

fn removeMain(opts: CommandOptions) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help
        \\-a, --all   removes all fonts including the current used font
        \\--except-current excludes the current used font
        \\<string>... fonts to remove
    );

    var res = try getResults(opts.allocator, &params, opts.iter);
    defer res.deinit();

    if (res.args.help != 0) {
        return sendHelp(&params);
    }

    const except_current = res.args.@"except-current" != 0;
    if (res.args.all != 0) {
        return zfont.removeAllFonts(opts.prefix, except_current);
    }

    const fonts = res.positionals[0];

    if (fonts.len < 1) {
        return error.MissingFonts;
    }

    return zfont.removeFonts(opts.allocator, fonts, opts.prefix, except_current);
}

fn listMain(opts: CommandOptions) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help
    );
    var res = try getResults(opts.allocator, &params, opts.iter);
    defer res.deinit();

    if (res.args.help != 0) {
        return sendHelp(&params);
    }

    const fonts = try zfont.listFonts(opts.allocator, opts.prefix);
    defer {
        for (fonts) |font| {
            opts.allocator.free(font);
        }

        opts.allocator.free(fonts);
    }

    var stdout_buf: [128]u8 = undefined;
    var stdout_file = std.fs.File.stdout();
    defer stdout_file.close();

    var stdout_writer = stdout_file.writer(&stdout_buf);
    var stdout = &stdout_writer.interface;

    for (fonts) |font| {
        try stdout.print("{s}\n", .{font});
    }

    try stdout.flush();
}

inline fn getResults(
    allocator: std.mem.Allocator,
    comptime params: Params,
    iter: *std.process.ArgIterator,
) !clap.ResultEx(clap.Help, params, clap.parsers.default) {
    const res = try clap.parseEx(
        clap.Help,
        params,
        clap.parsers.default,
        iter,
        .{ .allocator = allocator },
    );

    return res;
}

inline fn sendHelp(params: Params) !void {
    return clap.helpToFile(.stderr(), clap.Help, params, .{});
}
