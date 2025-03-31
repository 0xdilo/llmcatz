const std = @import("std");
const Thread = std.Thread;
const Mutex = Thread.Mutex;

const Options = struct {
    print: bool = false,
    output: ?[]const u8 = null,
    exclude: std.ArrayList([]const u8),
    threads: u32 = 4,
    targets: std.ArrayList([]const u8),
    fzf_mode: bool = false, // New flag for fzf mode
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Options {
        return .{
            .exclude = std.ArrayList([]const u8).init(allocator),
            .targets = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Options) void {
        // Free all allocated strings in exclude list
        for (self.exclude.items) |item| {
            self.allocator.free(item);
        }
        self.exclude.deinit();
        
        // Free all allocated strings in targets list
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
        \\TARGETS can be:
        \\  - Files
        \\  - Directory paths
        \\  - URLs
        \\  - GitHub repository URLs
        \\
        \\Options:
        \\  -p, --print     Print results to stdout
        \\  -o, --output    Specify output file
        \\  -e, --exclude   Exclude paths or patterns (can be used multiple times)
        \\  -t, --threads   Number of threads to use (default: 4)
        \\  -f, --fzf       Use fzf to select files interactively
        \\  -h, --help      Display this help message
        \\
    ;
    std.debug.print("{s}", .{help_text});
}

fn should_exclude(path: []const u8, exclude: []const []const u8) bool {
    for (exclude) |pattern| {
        if (std.mem.eql(u8, path, pattern)) {
            return true;
        }
        
        if (std.mem.endsWith(u8, path, pattern)) {
            return true;
        }
        
        if (std.mem.indexOf(u8, path, pattern) != null) {
            return true;
        }
        
        const dir_pattern = if (std.mem.endsWith(u8, pattern, "/")) 
            pattern 
        else 
            std.fmt.allocPrint(std.heap.page_allocator, "{s}/", .{pattern}) catch pattern;
            
        if (std.mem.startsWith(u8, path, dir_pattern)) {
            return true;
        }
    }
    return false;
}

fn copy_to_clipboard(allocator: std.mem.Allocator, text: []const u8) !void {
    if (std.posix.getenv("WAYLAND_DISPLAY")) |_| {
        const wayland_cmd = &[_][]const u8{"wl-copy"};
        var wayland_child = std.process.Child.init(wayland_cmd, allocator);
        wayland_child.stdin_behavior = .Pipe;

        if (wayland_child.spawn()) |_| {
            if (wayland_child.stdin) |*stdin| {
                stdin.writeAll(text) catch {
                    stdin.close();
                    wayland_child.stdin = null;
                    return try fallback_to_xclip(allocator, text);
                };
                stdin.close();
                wayland_child.stdin = null;
            }

            const term = try wayland_child.wait();
            if (term == .Exited and term.Exited == 0) {
                return;
            }
        } else |_| {}

        return try fallback_to_xclip(allocator, text);
    } else {
        return try fallback_to_xclip(allocator, text);
    }
}

fn fallback_to_xclip(allocator: std.mem.Allocator, text: []const u8) !void {
    const xorg_cmd = &[_][]const u8{ "xclip", "-selection", "clipboard" };
    var xorg_child = std.process.Child.init(xorg_cmd, allocator);
    xorg_child.stdin_behavior = .Pipe;

    xorg_child.spawn() catch |err| {
        std.debug.print("Failed to spawn xclip: {any}\n", .{err});
        return error.ClipboardFailed;
    };

    if (xorg_child.stdin) |*stdin| {
        std.debug.print("Writing {d} bytes to xclip...\n", .{text.len});
        try stdin.writeAll(text);
        stdin.close();
        xorg_child.stdin = null;
    }

    const term = try xorg_child.wait();
    std.debug.print("xclip completed with {any}\n", .{term});
    switch (term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("xclip exited with non-zero code: {d}\n", .{code});
            return error.ClipboardFailed;
        },
        else => return error.ClipboardFailed,
    }
}

const FileTask = struct {
    path: []const u8,
    is_full_path: bool,
    target: ?[]const u8 = null,
};

fn process_file(
    allocator: std.mem.Allocator,
    task: FileTask,
    buffer: *std.ArrayList(u8),
    mutex: *Mutex,
    _: []const []const u8, // Unused parameter, marked with underscore
) !void {
    var local_buffer = std.ArrayList(u8).init(allocator);
    defer local_buffer.deinit();

    const writer = local_buffer.writer();

    const full_path = if (task.is_full_path)
        try allocator.dupe(u8, task.path)
    else
        try std.fs.path.join(allocator, &[_][]const u8{ task.target.?, task.path });
    defer allocator.free(full_path);

    try writer.print("[ {s} ]\n\n", .{full_path});

    const content = std.fs.cwd().readFileAlloc(allocator, full_path, 10 * 1024 * 1024) catch |err| {
        try writer.print("Error reading file: {any}\n\n", .{err});
        return;
    };
    defer allocator.free(content);

    try writer.writeAll(content);
    try writer.writeAll("\n\n");

    // Acquire mutex before writing to shared buffer
    mutex.lock();
    defer mutex.unlock();
    try buffer.appendSlice(local_buffer.items);
}

fn process_targets(allocator: std.mem.Allocator, options: Options) !void {
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    const writer = buffer.writer();

    try writer.writeAll("[ DIRECTORY STRUCTURE ]\n");

    for (options.targets.items) |target| {
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

    try writer.writeAll("\n");

    var tasks = std.ArrayList(FileTask).init(allocator);
    defer tasks.deinit();

    for (options.targets.items) |target| {
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
                }
            }
        } else if (stat.kind == .file) {
            try tasks.append(.{
                .path = try allocator.dupe(u8, target),
                .is_full_path = true,
            });
        }
    }

    var mutex = Mutex{};
    const thread_count = @min(options.threads, @as(u32, @intCast(tasks.items.len)));

    if (thread_count == 0) {
        if (options.print) {
            std.debug.print("{s}", .{buffer.items});
        }
        return;
    }

    if (thread_count == 1 or tasks.items.len == 1) {
        for (tasks.items) |task| {
            try process_file(allocator, task, &buffer, &mutex, options.exclude.items);
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
            exclude: []const []const u8,
            next_task: *std.atomic.Value(usize),
        };

        const context = ThreadContext{
            .allocator = allocator,
            .tasks = tasks.items,
            .buffer = &buffer,
            .mutex = &mutex,
            .exclude = options.exclude.items,
            .next_task = &next_task,
        };

        const thread_fn = struct {
            fn work(ctx: ThreadContext) !void {
                while (true) {
                    const task_index = ctx.next_task.fetchAdd(1, .monotonic);
                    if (task_index >= ctx.tasks.len) break;

                    const task = ctx.tasks[task_index];
                    try process_file(ctx.allocator, task, ctx.buffer, ctx.mutex, ctx.exclude);
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

    if (options.print) {
        std.debug.print("{s}", .{buffer.items});
    }

    if (options.output) |output_path| {
        std.fs.cwd().writeFile(.{
            .sub_path = output_path,
            .data = buffer.items,
        }) catch |err| {
            std.debug.print("Error writing to output file: {any}\n", .{err});
        };
        std.debug.print(
            \\
            \\      |\      _,,,---,,_
            \\ZZZzz /,`.-'`'    -.  ;-;;,_
            \\     |,4-  ) )-,_. ,\ (  `'-'
            \\    '---''(_/--'  `-'\_) 
            \\Meow! Content successfully written to file: {s}
        , .{output_path});
    } else if (!options.print) {
        copy_to_clipboard(allocator, buffer.items) catch |err| {
            std.debug.print("Failed to copy to clipboard: {any}\n", .{err});
            return;
        };
        std.debug.print(
            \\
            \\      |\      _,,,---,,_
            \\ZZZzz /,`.-'`'    -.  ;-;;,_
            \\     |,4-  ) )-,_. ,\ (  `'-'
            \\    '---''(_/--'  `-'\_) 
            \\Meow! Content successfully copied to clipboard!
        , .{});
    }
    std.debug.print("", .{});
}

fn run_fzf(allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    var targets = std.ArrayList([]const u8).init(allocator);
    
    var file_list = std.ArrayList([]const u8).init(allocator);
    defer {
        for (file_list.items) |path| {
            allocator.free(path);
        }
        file_list.deinit();
    }

    var dir = std.fs.cwd().openDir(".", .{ .iterate = true }) catch |err| {
        std.debug.print("Error opening current directory: {any}\n", .{err});
        return error.DirectoryAccessFailed;
    };
    defer dir.close();

    var walker = dir.walk(allocator) catch |err| {
        std.debug.print("Error walking directory: {any}\n", .{err});
        return error.DirectoryWalkFailed;
    };
    defer walker.deinit();

    while (walker.next() catch |err| {
        std.debug.print("Error during directory traversal: {any}\n", .{err});
        return error.DirectoryTraversalFailed;
    }) |entry| {
        if (entry.kind == .file) {
            const path = try allocator.dupe(u8, entry.path);
            try file_list.append(path);
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
    
    which_process.spawn() catch {
        std.debug.print("Error: fzf is not installed or not in PATH.\n", .{});
        return error.FzfNotInstalled;
    };
    
    const which_term = try which_process.wait();
    if (which_term != .Exited or which_term.Exited != 0) {
        std.debug.print("Error: fzf is not installed or not in PATH.\n", .{});
        return error.FzfNotInstalled;
    }
    
    const fzf_cmd = &[_][]const u8{
        "fzf",
        "-m", // Allow multiple selections
        "--height=40%",
        "--border",
        "--preview", "cat {}",
    };
    
    var fzf_process = std.process.Child.init(fzf_cmd, allocator);
    fzf_process.stdin_behavior = .Pipe;
    fzf_process.stdout_behavior = .Pipe;

    fzf_process.spawn() catch |err| {
        std.debug.print("Error spawning fzf: {any}\n", .{err});
        return error.FzfSpawnFailed;
    };

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
    if (term != .Exited or term.Exited != 0) {
        return error.FzfFailed;
    }

    var lines = std.mem.splitScalar(u8, selected_files.items, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len > 0) {
                try targets.append(try allocator.dupe(u8, trimmed));
            }
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

    if (args.len <= 1) {
        options.fzf_mode = true;
    }

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

    if (options.fzf_mode and options.targets.items.len == 0) {
        var fzf_targets = run_fzf(allocator) catch |err| {
            std.debug.print("Failed to run fzf: {any}\n", .{err});
            print_help();
            return;
        };
        defer {
            for (fzf_targets.items) |path| {
                allocator.free(path);
            }
            fzf_targets.deinit();
        }
        
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

