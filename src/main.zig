const std = @import("std");
const Thread = std.Thread;
const Mutex = Thread.Mutex;
const http = std.http;

const c = @cImport({
    @cInclude("tiktoken_ffi.h");
    @cInclude("string.h");  
    @cInclude("stdlib.h"); 
});


const Options = struct {
    print: bool = false,
    output: ?[]const u8 = null,
    exclude: std.ArrayList([]const u8),
    threads: u32 = 4,
    targets: std.ArrayList([]const u8),
    fzf_mode: bool = false,
    encoding: []const u8 = "cl100k_base",
    count_files: bool = false,
    count_tokens: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Options {
        return .{
            .exclude = std.ArrayList([]const u8).init(allocator),
            .targets = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Options) void {
        for (self.exclude.items) |item| {
            self.allocator.free(item);
        }
        self.exclude.deinit();
        for (self.targets.items) |item| {
            self.allocator.free(item);
        }
        self.targets.deinit();
    }
};

fn print_help() void {
    const help_text =
        \\Usage: llmcatz [OPTIONS] [TARGETS...]
        \\
        \\TARGETS can be: Files, Directory paths, URLs (http:// or https://), GitHub repository URLs
        \\
        \\Options:
        \\  -p, --print         Print results to stdout
        \\  -o, --output        Specify output file
        \\  -e, --exclude       Exclude paths/patterns (multiple allowed)
        \\  -t, --threads       Number of threads (default: 4)
        \\  -f, --fzf           Use fzf to select files interactively
        \\  --encoding         Tokenizer encoding (e.g., o200k_base, cl100k_base)
        \\  --count-files      Print total file count
        \\  --count-tokens     Only count tokens without saving content
        \\  -h, --help          Display this help message
        \\
    ;
    std.debug.print("{s}", .{help_text});
}


fn should_exclude(path: []const u8, exclude: []const []const u8) bool {
    for (exclude) |pattern| {
        if (std.mem.eql(u8, path, pattern) or
            std.mem.endsWith(u8, path, pattern) or
            std.mem.indexOf(u8, path, pattern) != null) return true;

        const dir_pattern = if (std.mem.endsWith(u8, pattern, "/")) pattern else std.fmt.allocPrint(std.heap.page_allocator, "{s}/", .{pattern}) catch pattern;
        if (std.mem.startsWith(u8, path, dir_pattern)) return true;
    }
    return false;
}

fn copy_to_clipboard(allocator: std.mem.Allocator, text: []const u8) !void {
    if (std.posix.getenv("WAYLAND_DISPLAY")) |_| {
        const wayland_cmd = &[_][]const u8{"wl-copy"};
        var wayland_child = std.process.Child.init(wayland_cmd, allocator);
        wayland_child.stdin_behavior = .Pipe;
        try wayland_child.spawn();
        if (wayland_child.stdin) |*stdin| {
            try stdin.writeAll(text);
            stdin.close();
            wayland_child.stdin = null;
        }
        const term = try wayland_child.wait();
        if (term == .Exited and term.Exited == 0) return;
        return try fallback_to_xclip(allocator, text);
    } else {
        return try fallback_to_xclip(allocator, text);
    }
}

fn fallback_to_xclip(allocator: std.mem.Allocator, text: []const u8) !void {
    const xorg_cmd = &[_][]const u8{ "xclip", "-selection", "clipboard" };
    var xorg_child = std.process.Child.init(xorg_cmd, allocator);
    xorg_child.stdin_behavior = .Pipe;
    try xorg_child.spawn();
    if (xorg_child.stdin) |*stdin| {
        try stdin.writeAll(text);
        stdin.close();
        xorg_child.stdin = null;
    }
    const term = try xorg_child.wait();
    if (term != .Exited or term.Exited != 0) return error.ClipboardFailed;
}

const FileTask = struct {
    path: []const u8,
    is_full_path: bool,
    is_url: bool = false,
    target: ?[]const u8 = null,
};

fn fetch_url(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    const headers = &[_]http.Header{
        .{ .name = "User-Agent", .value = "llmcatz/1.0" },
    };

    const response = try client.fetch(.{
        .method = .GET,
        .location = .{ .url = url },
        .extra_headers = headers,
        .response_storage = .{ .dynamic = &buffer },
    });

    if (response.status != .ok) {
        return error.HttpRequestFailed;
    }

    return try allocator.dupe(u8, buffer.items);
}




fn init_tokenizer(encoding: []const u8) !void {
    const c_str = c.strdup(encoding.ptr) orelse return error.OutOfMemory;
    defer c.free(c_str);
    const result = c.tiktoken_init(c_str);
    if (result != 0) {
        std.debug.print("Failed to initialize tokenizer with encoding '{s}': error code {d}\n", .{encoding, result});
        return error.TokenizerInitFailed;
    }
}

fn count_tokens(text: []const u8) usize {
    const c_str = c.strdup(text.ptr) orelse return 0;
    defer c.free(c_str);
    return c.tiktoken_count(c_str);
}


fn process_file(
    allocator: std.mem.Allocator,
    task: FileTask,
    buffer: *std.ArrayList(u8),
    mutex: *Mutex,
    total_tokens: *usize,
) !void {
    var local_buffer = std.ArrayList(u8).init(allocator);
    defer local_buffer.deinit();

    const writer = local_buffer.writer();
    
    if (task.is_url) {
        try writer.print("[ URL: {s} ]\n", .{task.path});
        const content = fetch_url(allocator, task.path) catch |err| {
            try writer.print("Error fetching URL: {any}\n\n", .{err});
            return;
        };
        defer allocator.free(content);

        const token_count = count_tokens(content);
        try writer.writeAll(content);
        try writer.writeAll("\n\n");

        mutex.lock();
        defer mutex.unlock();
        try buffer.appendSlice(local_buffer.items);
        total_tokens.* += token_count;
    } else {
        const full_path = if (task.is_full_path)
            try allocator.dupe(u8, task.path)
        else
            try std.fs.path.join(allocator, &[_][]const u8{ task.target.?, task.path });
        defer allocator.free(full_path);

        try writer.print("[ {s} ]\n", .{full_path});
        const content = std.fs.cwd().readFileAlloc(allocator, full_path, 10 * 1024 * 1024) catch |err| {
            try writer.print("Error reading file: {any}\n\n", .{err});
            return;
        };
        defer allocator.free(content);

        const token_count = count_tokens(content);
        try writer.writeAll(content);
        try writer.writeAll("\n\n");

        mutex.lock();
        defer mutex.unlock();
        try buffer.appendSlice(local_buffer.items);
        total_tokens.* += token_count;
    }
}



fn process_targets(allocator: std.mem.Allocator, options: Options) !void {
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var total_tokens: usize = 0;
    var file_count: usize = 0;
    const writer = buffer.writer();

    try writer.writeAll("[ STRUCTURE ]\n");
    for (options.targets.items) |target| {
        if (std.mem.startsWith(u8, target, "http://") or std.mem.startsWith(u8, target, "https://")) {
            try writer.print("URL: {s}\n", .{target});
        } else {
            const stat = std.fs.cwd().statFile(target) catch {
                try writer.print("{s}\n", .{target});
                continue;
            };

            if (stat.kind == .directory) {
                try writer.print("{s}\n", .{target});
                var dir = try std.fs.cwd().openDir(target, .{ .iterate = true });
                defer dir.close();
                var walker = try dir.walk(allocator);
                defer walker.deinit();
                while (try walker.next()) |entry| {
                    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{target, entry.path});
                    defer allocator.free(full_path);
                    if (!should_exclude(full_path, options.exclude.items) and 
                        !should_exclude(entry.path, options.exclude.items)) {
                        try writer.print("{s}{s}{s}\n", .{ target, entry.path, if (entry.kind == .directory) "/" else "" });
                    }
                }
            } else {
                try writer.print("{s}\n", .{target});
            }
        }
    }
    try writer.writeAll("\n");

    var tasks = std.ArrayList(FileTask).init(allocator);
    defer tasks.deinit();

    for (options.targets.items) |target| {
        if (std.mem.startsWith(u8, target, "http://") or std.mem.startsWith(u8, target, "https://")) {
            try tasks.append(.{
                .path = try allocator.dupe(u8, target),
                .is_full_path = true,
                .is_url = true,
            });
            file_count += 1;
        } else {
            const stat = std.fs.cwd().statFile(target) catch continue;
            if (stat.kind == .directory) {
                var dir = try std.fs.cwd().openDir(target, .{ .iterate = true });
                defer dir.close();
                var walker = try dir.walk(allocator);
                defer walker.deinit();
                while (try walker.next()) |entry| {
                    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{target, entry.path});
                    defer allocator.free(full_path);
                    if (entry.kind == .file and 
                        !should_exclude(full_path, options.exclude.items) and 
                        !should_exclude(entry.path, options.exclude.items)) {
                        try tasks.append(.{
                            .path = try allocator.dupe(u8, entry.path),
                            .is_full_path = false,
                            .target = try allocator.dupe(u8, target),
                        });
                        file_count += 1;
                    }
                }
            } else if (stat.kind == .file) {
                try tasks.append(.{
                    .path = try allocator.dupe(u8, target),
                    .is_full_path = true,
                });
                file_count += 1;
            }
        }
    }

    var mutex = Mutex{};
    const thread_count = @min(options.threads, @as(u32, @intCast(tasks.items.len)));

    if (thread_count == 0) {
        if (options.print) std.debug.print("{s}", .{buffer.items});
        return;
    }

    if (thread_count == 1 or tasks.items.len == 1) {
        for (tasks.items) |task| {
            try process_file(allocator, task, &buffer, &mutex, &total_tokens);
            allocator.free(task.path);
            if (task.target) |t| allocator.free(t);
        }
    } else {
        var threads = try allocator.alloc(Thread, thread_count);
        defer allocator.free(threads);

        var next_task = std.atomic.Value(usize).init(0);

        const ThreadContext = struct {
            allocator: std.mem.Allocator,
            tasks: []FileTask,
            buffer: *std.ArrayList(u8),
            mutex: *Mutex,
            options: Options,
            total_tokens: *usize,
            next_task: *std.atomic.Value(usize),
        };

        const context = ThreadContext{
            .allocator = allocator,
            .tasks = tasks.items,
            .buffer = &buffer,
            .mutex = &mutex,
            .options = options,
            .total_tokens = &total_tokens,
            .next_task = &next_task,
        };

        const thread_fn = struct {
            fn work(ctx: ThreadContext) !void {
                while (true) {
                    const task_index = ctx.next_task.fetchAdd(1, .monotonic);
                    if (task_index >= ctx.tasks.len) break;
                    const task = ctx.tasks[task_index];
                    try process_file(ctx.allocator, task, ctx.buffer, ctx.mutex, ctx.total_tokens);
                }
            }
        }.work;

        for (0..thread_count) |i| {
            threads[i] = try Thread.spawn(.{}, thread_fn, .{context});
        }

        for (threads) |thread| {
            thread.join();
        }

        for (tasks.items) |task| {
            allocator.free(task.path);
            if (task.target) |t| allocator.free(t);
        }
    }

    if (options.count_tokens) {
        std.debug.print(
            \\
            \\      |\      _,,,---,,_
            \\ZZZzz /,`.-'`'    -.  ;-;;,_
            \\     |,4-  ) )-,_. ,\ (  `'-'
            \\    '---''(_/--'  `-'\_) 
            \\Meow! Token count: {d}
        , .{total_tokens});
        if (options.count_files) {
            std.debug.print("\nProcessed {d} files", .{file_count});
        }
        std.debug.print("\n", .{});
        return;
    }

    if (options.print) {
        std.debug.print("{s}", .{buffer.items});
    }

    if (options.output) |output_path| {
        try std.fs.cwd().writeFile(.{ .sub_path = output_path, .data = buffer.items });
        std.debug.print(
            \\
            \\      |\      _,,,---,,_
            \\ZZZzz /,`.-'`'    -.  ;-;;,_
            \\     |,4-  ) )-,_. ,\ (  `'-'
            \\    '---''(_/--'  `-'\_) 
            \\Meow! Content written to {s}
            \\Token count: {d}
        , .{output_path, total_tokens});
    } else if (!options.print) {
        try copy_to_clipboard(allocator, buffer.items);
        var recap = std.ArrayList(u8).init(allocator);
        defer recap.deinit();
        const recap_writer = recap.writer();
        try recap_writer.print(
            \\
            \\      |\      _,,,---,,_
            \\ZZZzz /,`.-'`'    -.  ;-;;,_
            \\     |,4-  ) )-,_. ,\ (  `'-'
            \\    '---''(_/--'  `-'\_) 
            \\Meow! Content copied to clipboard!
            \\Token count: {d}
        , .{total_tokens});
        if (options.count_files) {
            try recap_writer.print("\nProcessed {d} files", .{file_count});
        }
        std.debug.print("{s}\n", .{recap.items});
    }
}

fn run_fzf(allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    var targets = std.ArrayList([]const u8).init(allocator);
    var file_list = std.ArrayList([]const u8).init(allocator);
    defer { for (file_list.items) |path| allocator.free(path); file_list.deinit(); }

    var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind == .file) {
            try file_list.append(try allocator.dupe(u8, entry.path));
        }
    }

    var fzf_input = std.ArrayList(u8).init(allocator);
    defer fzf_input.deinit();
    const writer = fzf_input.writer();
    for (file_list.items) |file| {
        try writer.print("{s}\n", .{file});
    }

    const which_cmd = &[_][]const u8{"which", "fzf"};
    var which_process = std.process.Child.init(which_cmd, allocator);
    which_process.stdout_behavior = .Ignore;
    which_process.stderr_behavior = .Ignore;
    try which_process.spawn();
    const which_term = try which_process.wait();
    if (which_term != .Exited or which_term.Exited != 0) {
        std.debug.print("Error: fzf is not installed or not in PATH.\n", .{});
        return error.FzfNotInstalled;
    }

    const fzf_cmd = &[_][]const u8{ "fzf", "-m", "--height=40%", "--border", "--preview", "cat {}" };
    var fzf_process = std.process.Child.init(fzf_cmd, allocator);
    fzf_process.stdin_behavior = .Pipe;
    fzf_process.stdout_behavior = .Pipe;
    try fzf_process.spawn();

    if (fzf_process.stdin) |*stdin| {
        try stdin.writeAll(fzf_input.items);
        stdin.close();
        fzf_process.stdin = null;
    }

    var selected_files = std.ArrayList(u8).init(allocator);
    defer selected_files.deinit();
    if (fzf_process.stdout) |stdout| {
        try stdout.reader().readAllArrayList(&selected_files, 1024 * 1024);
    }

    const term = try fzf_process.wait();
    if (term != .Exited or term.Exited != 0) return error.FzfFailed;

    var lines = std.mem.splitScalar(u8, selected_files.items, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len > 0) try targets.append(try allocator.dupe(u8, trimmed));
        }
    }
    return targets;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var options = Options.init(allocator);
    defer options.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len <= 1) options.fzf_mode = true;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--print")) {
                options.print = true;
            } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                options.output = args[i];
            } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--exclude")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                try options.exclude.append(args[i]);
            } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--threads")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                options.threads = try std.fmt.parseInt(u32, args[i], 10);
            } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--fzf")) {
                options.fzf_mode = true;
            } else if (std.mem.eql(u8, arg, "--encoding")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                options.encoding = args[i];
            } else if (std.mem.eql(u8, arg, "--count-files")) {
                options.count_files = true;
            } else if (std.mem.eql(u8, arg, "--count-tokens")) {
                options.count_tokens = true;
            } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                print_help();
                return;
            } else {
                std.debug.print("Unknown option: {s}\n", .{arg});
                print_help();
                return error.UnknownOption;
            }
        } else {
            try options.targets.append(try allocator.dupe(u8, arg));
        }
    }

    try init_tokenizer(options.encoding);
    defer c.tiktoken_cleanup();

    if (options.fzf_mode and options.targets.items.len == 0) {
        var fzf_targets = try run_fzf(allocator);
        defer { for (fzf_targets.items) |path| allocator.free(path); fzf_targets.deinit(); }
        if (fzf_targets.items.len == 0) {
            std.debug.print("No files selected.\n", .{});
            print_help();
            return;
        }
        for (fzf_targets.items) |path| {
            try options.targets.append(try allocator.dupe(u8, path));
        }
    }

    if (options.targets.items.len == 0) {
        print_help();
        return;
    }

    try process_targets(allocator, options);
}
