const std = @import("std");
const Thread = std.Thread;
const Mutex = Thread.Mutex;
const http = std.http;

const c = @cImport({
    @cInclude("tiktoken_ffi.h");
    @cInclude("string.h");
    @cInclude("stdlib.h");
});

const MAX_FILE_SIZE: usize = 10 * 1024 * 1024;

const unwanted_extensions = std.StaticStringMap(void).initComptime(.{
    .{ ".png", {} },      .{ ".jpg", {} },      .{ ".jpeg", {} },
    .{ ".gif", {} },      .{ ".bmp", {} },      .{ ".tiff", {} },
    .{ ".webp", {} },     .{ ".svg", {} },      .{ ".ico", {} },
    .{ ".o", {} },        .{ ".a", {} },        .{ ".so", {} },
    .{ ".dylib", {} },    .{ ".dll", {} },      .{ ".exe", {} },
    .{ ".obj", {} },      .{ ".lib", {} },      .{ ".zip", {} },
    .{ ".tar", {} },      .{ ".gz", {} },       .{ ".bz2", {} },
    .{ ".xz", {} },       .{ ".rar", {} },      .{ ".7z", {} },
    .{ ".jar", {} },      .{ ".war", {} },      .{ ".ear", {} },
    .{ ".pdf", {} },      .{ ".doc", {} },      .{ ".docx", {} },
    .{ ".ppt", {} },      .{ ".pptx", {} },     .{ ".xls", {} },
    .{ ".xlsx", {} },     .{ ".odt", {} },      .{ ".ods", {} },
    .{ ".odp", {} },      .{ ".bin", {} },      .{ ".dat", {} },
    .{ ".iso", {} },      .{ ".img", {} },      .{ ".class", {} },
    .{ ".pyc", {} },      .{ ".wasm", {} },     .{ ".ds_store", {} },
    .{ ".mp3", {} },      .{ ".mp4", {} },      .{ ".avi", {} },
    .{ ".mkv", {} },      .{ ".mov", {} },      .{ ".wav", {} },
    .{ ".flac", {} },     .{ ".ogg", {} },      .{ ".webm", {} },
    .{ ".ttf", {} },      .{ ".otf", {} },      .{ ".woff", {} },
    .{ ".woff2", {} },    .{ ".db", {} },       .{ ".sqlite", {} },
    .{ ".mdb", {} },      .{ ".idx", {} },      .{ ".pack", {} },
    .{ ".swp", {} },      .{ ".swo", {} },
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
    json: bool = false,
    markdown: bool = false,
    raw: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Options {
        return .{
            .exclude = .empty,
            .targets = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Options) void {
        for (self.exclude.items) |item| self.allocator.free(item);
        self.exclude.deinit(self.allocator);
        for (self.targets.items) |item| self.allocator.free(item);
        self.targets.deinit(self.allocator);
    }
};

fn is_github_url(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://github.com/") or
        std.mem.startsWith(u8, url, "http://github.com/");
}

const GitHubRepo = struct {
    user: []const u8,
    repo: []const u8,
    branch: []const u8,
    subdir: []const u8,

    pub fn deinit(self: *GitHubRepo, allocator: std.mem.Allocator) void {
        allocator.free(self.user);
        allocator.free(self.repo);
        allocator.free(self.branch);
        allocator.free(self.subdir);
    }
};

fn parse_github_url(
    allocator: std.mem.Allocator,
    url: []const u8,
) !GitHubRepo {
    var no_proto = url;
    if (std.mem.startsWith(u8, no_proto, "https://")) {
        no_proto = no_proto[8..];
    } else if (std.mem.startsWith(u8, no_proto, "http://")) {
        no_proto = no_proto[7..];
    }

    if (!std.mem.startsWith(u8, no_proto, "github.com/"))
        return error.InvalidGitHubUrl;
    no_proto = no_proto["github.com/".len..];

    var parts = std.mem.splitScalar(u8, no_proto, '/');
    const user = parts.next() orelse return error.InvalidGitHubUrl;
    const repo_raw = parts.next() orelse return error.InvalidGitHubUrl;

    var repo_name = repo_raw;
    if (std.mem.endsWith(u8, repo_name, ".git")) {
        repo_name = repo_name[0 .. repo_name.len - 4];
    }
    var branch: []const u8 = "main";
    var subdir: []const u8 = "";

    if (parts.next()) |next_part| {
        if (std.mem.eql(u8, next_part, "tree")) {
            branch = parts.next() orelse "main";
            subdir = parts.rest();
        }
    }

    return GitHubRepo{
        .user = try allocator.dupe(u8, user),
        .repo = try allocator.dupe(u8, repo_name),
        .branch = try allocator.dupe(u8, branch),
        .subdir = try allocator.dupe(u8, subdir),
    };
}

fn fetch_github_file_list(
    allocator: std.mem.Allocator,
    repo: GitHubRepo,
) !std.ArrayList([]const u8) {
    var files: std.ArrayList([]const u8) = .empty;

    const api_url = try std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repos/{s}/{s}/git/trees/{s}?recursive=1",
        .{ repo.user, repo.repo, repo.branch },
    );
    defer allocator.free(api_url);

    const json_data = try fetch_url(allocator, api_url);
    defer allocator.free(json_data);

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_data,
        .{},
    );
    defer parsed.deinit();

    const root_obj = parsed.value;
    const tree = root_obj.object.get("tree") orelse return error.InvalidApiResponse;
    if (tree != .array) return error.InvalidApiResponse;

    for (tree.array.items) |item| {
        if (item.object.get("type")) |typ| {
            if (std.mem.eql(u8, typ.string, "blob")) {
                if (item.object.get("path")) |path_val| {
                    const path = path_val.string;
                    if (repo.subdir.len == 0 or
                        std.mem.startsWith(u8, path, repo.subdir))
                    {
                        try files.append(allocator, try allocator.dupe(u8, path));
                    }
                }
            }
        }
    }

    return files;
}

fn print_help() void {
    const help_text =
        \\Usage: llmcatz [OPTIONS] [TARGETS...]
        \\
        \\TARGETS can be:
        \\  - Files
        \\  - Directory paths
        \\  - URLs (http:// or https://)
        \\  - GitHub repositories (https://github.com/user/repo)
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
        \\  --json             Output in JSON format
        \\  --markdown         Enable Markdown formatting for output
        \\  --raw              Output raw file contents only (no headers/structure)
        \\  -h, --help          Display this help message
        \\
    ;
    std.debug.print("{s}", .{help_text});
}

fn should_exclude(
    allocator: std.mem.Allocator,
    path: []const u8,
    exclude: []const []const u8,
) !bool {
    const normalized_path = try normalize_slashes(allocator, path);
    defer allocator.free(normalized_path);
    for (exclude) |pattern| {
        if (std.mem.eql(u8, normalized_path, pattern) or
            std.mem.endsWith(u8, normalized_path, pattern) or
            std.mem.indexOf(u8, normalized_path, pattern) != null)
            return true;

        if (std.mem.endsWith(u8, pattern, "/")) {
            if (std.mem.startsWith(u8, normalized_path, pattern)) return true;
        } else {
            const dir_pattern = try std.fmt.allocPrint(allocator, "{s}/", .{pattern});
            defer allocator.free(dir_pattern);
            if (std.mem.startsWith(u8, normalized_path, dir_pattern)) return true;
        }
    }
    return false;
}

fn copy_to_clipboard(
    allocator: std.mem.Allocator,
    text: []const u8,
) !void {
    const os_tag = @import("builtin").os.tag;

    if (os_tag == .linux) {
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
            return error.ClipboardFailed;
        }
        return try fallback_to_xclip(allocator, text);
    } else if (os_tag == .macos) {
        const pbcopy_cmd = &[_][]const u8{"pbcopy"};
        var pbcopy_child = std.process.Child.init(pbcopy_cmd, allocator);
        pbcopy_child.stdin_behavior = .Pipe;
        try pbcopy_child.spawn();
        if (pbcopy_child.stdin) |*stdin| {
            try stdin.writeAll(text);
            stdin.close();
            pbcopy_child.stdin = null;
        }
        const term = try pbcopy_child.wait();
        if (term == .Exited and term.Exited == 0) return;
        return error.ClipboardFailed;
    } else {
        return error.ClipboardFailed;
    }
}

fn fallback_to_xclip(
    allocator: std.mem.Allocator,
    text: []const u8,
) !void {
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

fn fetch_url(
    allocator: std.mem.Allocator,
    url: []const u8,
) ![]const u8 {
    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    var response_buffer = std.Io.Writer.Allocating.init(allocator);
    defer response_buffer.deinit();

    const headers = &[_]http.Header{
        .{ .name = "User-Agent", .value = "llmcatz/1.0" },
    };

    const response = try client.fetch(.{
        .method = .GET,
        .location = .{ .url = url },
        .extra_headers = headers,
        .response_writer = &response_buffer.writer,
    });

    if (response.status != .ok) {
        return error.HttpRequestFailed;
    }

    return try response_buffer.toOwnedSlice();
}

fn init_tokenizer(encoding: []const u8) !void {
    const c_alloc = std.heap.c_allocator;
    const c_str = try c_alloc.dupeZ(u8, encoding);
    defer c_alloc.free(c_str);
    const result = c.tiktoken_init(c_str.ptr);
    if (result != 0) {
        std.debug.print(
            "Failed to initialize tokenizer with encoding '{s}': error code {d}\n",
            .{ encoding, result },
        );
        return error.TokenizerInitFailed;
    }
}

fn count_tokens(text: []const u8) usize {
    if (text.len == 0) return 0;
    const c_alloc = std.heap.c_allocator;
    const c_str = c_alloc.dupeZ(u8, text) catch return 0;
    defer c_alloc.free(c_str);
    return c.tiktoken_count(c_str.ptr);
}

fn process_file(
    allocator: std.mem.Allocator,
    task: FileTask,
    buffer: *std.ArrayList(u8),
    mutex: *Mutex,
    total_tokens: *usize,
    options: Options,
    file_map: *std.StringHashMap([]const u8),
) !void {
    var local_buffer: std.ArrayList(u8) = .empty;
    defer local_buffer.deinit(allocator);

    const writer = local_buffer.writer(allocator);

    if (task.is_url) {
        if (!options.raw) {
            if (options.markdown) {
                try writer.print("## URL: {s}\n\n", .{task.path});
                try writer.print("```\n", .{});
            } else {
                try writer.print("[ URL: {s} ]\n", .{task.path});
            }
        }

        const content = fetch_url(allocator, task.path) catch |err| {
            if (!options.raw) {
                if (options.markdown) {
                    try writer.print("Error fetching URL: {any}\n```\n\n", .{err});
                } else {
                    try writer.print("Error fetching URL: {any}\n\n", .{err});
                }
            }
            return;
        };
        defer allocator.free(content);

        if (content.len == 0) {
            if (!options.raw) {
                if (options.markdown) {
                    try writer.print("[Empty content]\n```\n\n", .{});
                } else {
                    try writer.print("[Empty content]\n\n", .{});
                }
            }
        } else {
            const token_count = count_tokens(content);
            if (options.raw) {
                try writer.writeAll(content);
                try writer.writeAll("\n");
            } else if (options.markdown) {
                try writer.writeAll(content);
                try writer.print("\n```\n\n", .{});
            } else {
                try writer.writeAll(content);
                try writer.writeAll("\n\n");
            }

            mutex.lock();
            defer mutex.unlock();
            total_tokens.* += token_count;
            try buffer.appendSlice(allocator, local_buffer.items);
            if (options.json) {
                try file_map.put(
                    try allocator.dupe(u8, task.path),
                    try allocator.dupe(u8, content),
                );
            }
            return;
        }

        mutex.lock();
        defer mutex.unlock();
        try buffer.appendSlice(allocator, local_buffer.items);
    } else {
        const full_path = if (task.is_full_path)
            try allocator.dupe(u8, task.path)
        else
            try std.fs.path.join(
                allocator,
                &[_][]const u8{ task.target.?, task.path },
            );
        defer allocator.free(full_path);

        if (!options.raw) {
            if (options.markdown) {
                try writer.print("## {s}\n\n", .{full_path});
                try writer.print("```\n", .{});
            } else {
                try writer.print("[ {s} ]\n", .{full_path});
            }
        }

        const content = std.fs.cwd().readFileAlloc(
            allocator,
            full_path,
            MAX_FILE_SIZE,
        ) catch |err| {
            if (!options.raw) {
                if (options.markdown) {
                    try writer.print("Error reading file: {any}\n```\n\n", .{err});
                } else {
                    try writer.print("Error reading file: {any}\n\n", .{err});
                }
            }
            return;
        };
        defer allocator.free(content);

        if (content.len == 0) {
            if (!options.raw) {
                if (options.markdown) {
                    try writer.print("[Empty file]\n```\n\n", .{});
                } else {
                    try writer.print("[Empty file]\n\n", .{});
                }
            }
        } else {
            const token_count = count_tokens(content);
            if (options.raw) {
                try writer.writeAll(content);
                try writer.writeAll("\n");
            } else if (options.markdown) {
                try writer.writeAll(content);
                try writer.print("\n```\n\n", .{});
            } else {
                try writer.writeAll(content);
                try writer.writeAll("\n\n");
            }

            mutex.lock();
            defer mutex.unlock();
            total_tokens.* += token_count;
            try buffer.appendSlice(allocator, local_buffer.items);
            if (options.json) {
                try file_map.put(
                    try allocator.dupe(u8, full_path),
                    try allocator.dupe(u8, content),
                );
            }
            return;
        }

        mutex.lock();
        defer mutex.unlock();
        try buffer.appendSlice(allocator, local_buffer.items);
    }
}

fn process_targets(
    allocator: std.mem.Allocator,
    options: Options,
) !void {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    var total_tokens: usize = 0;
    var file_count: usize = 0;

    var tree_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (tree_list.items) |path| allocator.free(path);
        tree_list.deinit(allocator);
    }

    var file_map = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = file_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        file_map.deinit();
    }

    const writer = buffer.writer(allocator);

    if (!options.raw) {
        if (options.markdown) {
            try writer.writeAll("# Structure\n\n");
        } else {
            try writer.writeAll("[ STRUCTURE ]\n");
        }
    }

    var tasks: std.ArrayList(FileTask) = .empty;
    defer tasks.deinit(allocator);

    for (options.targets.items) |target| {
        if (is_github_url(target)) {
            var repo = try parse_github_url(allocator, target);
            defer repo.deinit(allocator);

            var file_list = try fetch_github_file_list(allocator, repo);
            defer {
                for (file_list.items) |f| allocator.free(f);
                file_list.deinit(allocator);
            }

            for (file_list.items) |file_path| {
                if (has_unwanted_extension(file_path)) continue;
                const raw_url = try std.fmt.allocPrint(
                    allocator,
                    "https://raw.githubusercontent.com/{s}/{s}/{s}/{s}",
                    .{ repo.user, repo.repo, repo.branch, file_path },
                );
                defer allocator.free(raw_url);

                if (!options.raw) {
                    if (options.markdown) {
                        try writer.print("- GitHub: `{s}`\n", .{file_path});
                    } else {
                        try writer.print("GitHub: {s}\n", .{file_path});
                    }
                }
                try tasks.append(allocator, .{
                    .path = try allocator.dupe(u8, raw_url),
                    .is_full_path = true,
                    .is_url = true,
                });
                file_count += 1;
                try tree_list.append(allocator, try allocator.dupe(u8,file_path));
            }
        } else if (std.mem.startsWith(u8, target, "http://") or
            std.mem.startsWith(u8, target, "https://"))
        {
            if (!options.raw) {
                if (options.markdown) {
                    try writer.print("- URL: `{s}`\n", .{target});
                } else {
                    try writer.print("URL: {s}\n", .{target});
                }
            }
            try tasks.append(allocator, .{
                .path = try allocator.dupe(u8, target),
                .is_full_path = true,
                .is_url = true,
            });
            file_count += 1;
            try tree_list.append(allocator, try allocator.dupe(u8,target));
        } else {
            const stat = std.fs.cwd().statFile(target) catch {
                if (!options.raw) {
                    if (options.markdown) {
                        try writer.print("- Error accessing: `{s}`\n", .{target});
                    } else {
                        try writer.print("Error accessing: {s}\n", .{target});
                    }
                }
                continue;
            };

            if (stat.kind == .directory) {
                if (!options.raw and !options.markdown) {
                    const normalized_target = try normalize_slashes(allocator, target);
                    defer allocator.free(normalized_target);
                    const display_target = if (std.mem.endsWith(u8, normalized_target, "/"))
                        normalized_target[0 .. normalized_target.len - 1]
                    else
                        normalized_target;
                    try writer.print("{s}/\n", .{display_target});
                }
                var dir = try std.fs.cwd().openDir(target, .{ .iterate = true });
                defer dir.close();
                var walker = try dir.walk(allocator);
                defer walker.deinit();

                while (try walker.next()) |entry| {
                    if (is_dot_folder(entry.path)) continue;

                    const full_path = try std.fmt.allocPrint(
                        allocator,
                        "{s}/{s}",
                        .{ target, entry.path },
                    );
                    defer allocator.free(full_path);
                    if (!try should_exclude(
                        allocator,
                        full_path,
                        options.exclude.items,
                    ) and
                        !try should_exclude(
                            allocator,
                            entry.path,
                            options.exclude.items,
                        ))
                    {
                        if (entry.kind == .file and !has_unwanted_extension(entry.path)) {
                            try tasks.append(allocator, .{
                                .path = try allocator.dupe(u8, entry.path),
                                .is_full_path = false,
                                .target = try allocator.dupe(u8, target),
                            });
                            file_count += 1;
                            try tree_list.append(allocator, try allocator.dupe(u8,entry.path));
                        }

                        if (!options.raw) {
                            const is_dir = entry.kind == .directory;
                            const raw_display_path = try std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ target, entry.path, if (is_dir) "/" else "" });
                            const display_path = try normalize_slashes(allocator, raw_display_path);
                            defer allocator.free(raw_display_path);
                            defer allocator.free(display_path);

                            if (options.markdown) {
                                try writer.print("- `{s}`\n", .{display_path});
                            } else {
                                try writer.print("{s}\n", .{display_path});
                            }
                        }
                    }
                }
            } else if (stat.kind == .file) {
                if (has_unwanted_extension(target)) {
                    if (!options.raw) {
                        if (options.markdown) {
                            try writer.print("- [skipped binary] `{s}`\n", .{target});
                        } else {
                            try writer.print("[skipped binary] {s}\n", .{target});
                        }
                    }
                    continue;
                }
                if (!options.raw) {
                    if (options.markdown) {
                        try writer.print("- `{s}`\n", .{target});
                    } else {
                        try writer.print("{s}\n", .{target});
                    }
                }
                try tasks.append(allocator, .{
                    .path = try allocator.dupe(u8, target),
                    .is_full_path = true,
                });
                file_count += 1;
                try tree_list.append(allocator, try allocator.dupe(u8,target));
            }
        }
    }

    if (!options.raw) {
        try writer.writeAll("\n");
    }

    var mutex = Mutex{};
    const thread_count = @min(options.threads, @as(u32, @intCast(tasks.items.len)));

    if (thread_count == 0) {
        if (options.print) std.debug.print("{s}", .{buffer.items});
        return;
    }

    if (thread_count == 1 or tasks.items.len == 1) {
        for (tasks.items) |task| {
            try process_file(allocator, task, &buffer, &mutex, &total_tokens, options, &file_map);
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
            file_map: *std.StringHashMap([]const u8),
        };

        const context = ThreadContext{
            .allocator = allocator,
            .tasks = tasks.items,
            .buffer = &buffer,
            .mutex = &mutex,
            .options = options,
            .total_tokens = &total_tokens,
            .next_task = &next_task,
            .file_map = &file_map,
        };

        const thread_fn = struct {
            fn work(ctx: ThreadContext) !void {
                while (true) {
                    const task_index = ctx.next_task.fetchAdd(1, .monotonic);
                    if (task_index >= ctx.tasks.len) break;
                    const task = ctx.tasks[task_index];
                    try process_file(
                        ctx.allocator,
                        task,
                        ctx.buffer,
                        ctx.mutex,
                        ctx.total_tokens,
                        ctx.options,
                        ctx.file_map,
                    );
                }
            }
        }.work;

        for (0..thread_count) |i| {
            threads[i] = try Thread.spawn(.{}, thread_fn, .{context});
        }

        for (threads) |thread| thread.join();

        for (tasks.items) |task| {
            allocator.free(task.path);
            if (task.target) |t| allocator.free(t);
        }
    }

    if (options.json) {
        var json_buffer: std.ArrayList(u8) = .empty;
        defer json_buffer.deinit(allocator);
        const jw = json_buffer.writer(allocator);

        try jw.writeAll("{\n  \"tree\": [\n");
        for (tree_list.items, 0..) |path, idx| {
            try jw.writeAll("    ");
            try jw.print("{f}", .{std.json.fmt(path, .{})});
            try jw.print("{s}\n", .{
                if (idx + 1 == tree_list.items.len) "" else ",",
            });
        }
        try jw.writeAll("  ],\n");
        try jw.print("  \"token_count\": {d}", .{total_tokens});

        var it = file_map.iterator();
        while (it.next()) |entry| {
            try jw.writeAll(",\n  ");
            try jw.print("{f}", .{std.json.fmt(entry.key_ptr.*, .{})});
            try jw.writeAll(": ");
            try jw.print("{f}", .{std.json.fmt(entry.value_ptr.*, .{})});
        }
        try jw.writeAll("\n}\n");

        if (options.print) {
            std.debug.print("{s}", .{json_buffer.items});
        } else {
            try copy_to_clipboard(allocator, json_buffer.items);
            std.debug.print(
                \\
                \\      |\      _,,,---,,_
                \\ZZZzz /,`.-'`'    -.  ;-;;,_
                \\     |,4-  ) )-,_. ,\ (  `'-'
                \\    '---''(_/--'  `-'\_) 
                \\Meow! JSON content copied to clipboard!
                \\Token count: {d}
            , .{total_tokens});
            if (options.count_files) {
                std.debug.print("\nProcessed {d} files", .{file_count});
            }
            std.debug.print("\n", .{});
        }
        return;
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
        try std.fs.cwd().writeFile(.{
            .sub_path = output_path,
            .data = buffer.items,
        });
        std.debug.print(
            \\
            \\      |\      _,,,---,,_
            \\ZZZzz /,`.-'`'    -.  ;-;;,_
            \\     |,4-  ) )-,_. ,\ (  `'-'
            \\    '---''(_/--'  `-'\_) 
            \\Meow! Content written to {s}
            \\Token count: {d}
        , .{ output_path, total_tokens });
    } else if (!options.print) {
        try copy_to_clipboard(allocator, buffer.items);
        var recap: std.ArrayList(u8) = .empty;
        defer recap.deinit(allocator);
        const recap_writer = recap.writer(allocator);
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
    var targets: std.ArrayList([]const u8) = .empty;
    var file_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (file_list.items) |path| allocator.free(path);
        file_list.deinit(allocator);
    }

    var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind == .file) {
            try file_list.append(allocator, try allocator.dupe(u8, entry.path));
        }
    }

    var fzf_input: std.ArrayList(u8) = .empty;
    defer fzf_input.deinit(allocator);
    const writer = fzf_input.writer(allocator);
    for (file_list.items) |file| {
        try writer.print("{s}\n", .{file});
    }

    const which_cmd = &[_][]const u8{ "which", "fzf" };
    var which_process = std.process.Child.init(which_cmd, allocator);
    which_process.stdout_behavior = .Ignore;
    which_process.stderr_behavior = .Ignore;
    try which_process.spawn();
    const which_term = try which_process.wait();
    if (which_term != .Exited or which_term.Exited != 0) {
        std.debug.print("Error: fzf is not installed or not in PATH.\n", .{});
        return error.FzfNotInstalled;
    }

    const fzf_cmd = &[_][]const u8{
        "fzf",
        "-m",
        "--height=40%",
        "--border",
        "--preview",
        "cat {}",
    };
    var fzf_process = std.process.Child.init(fzf_cmd, allocator);
    fzf_process.stdin_behavior = .Pipe;
    fzf_process.stdout_behavior = .Pipe;
    try fzf_process.spawn();

    if (fzf_process.stdin) |*stdin| {
        try stdin.writeAll(fzf_input.items);
        stdin.close();
        fzf_process.stdin = null;
    }

    const selected_files = if (fzf_process.stdout) |stdout|
        try stdout.readToEndAlloc(allocator, 1024 * 1024)
    else
        "";
    defer if (selected_files.len > 0) allocator.free(selected_files);

    const term = try fzf_process.wait();
    if (term != .Exited or term.Exited != 0) return error.FzfFailed;

    var lines = std.mem.splitScalar(u8, selected_files, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len > 0)
                try targets.append(allocator, try allocator.dupe(u8, trimmed));
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
            } else if (std.mem.eql(u8, arg, "-o") or
                std.mem.eql(u8, arg, "--output"))
            {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                options.output = args[i];
            } else if (std.mem.eql(u8, arg, "-e") or
                std.mem.eql(u8, arg, "--exclude"))
            {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                const normalized = try normalize_slashes(allocator, args[i]);
                try options.exclude.append(allocator, normalized);
            } else if (std.mem.eql(u8, arg, "-t") or
                std.mem.eql(u8, arg, "--threads"))
            {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                options.threads = try std.fmt.parseInt(u32, args[i], 10);
            } else if (std.mem.eql(u8, arg, "-f") or
                std.mem.eql(u8, arg, "--fzf"))
            {
                options.fzf_mode = true;
            } else if (std.mem.eql(u8, arg, "--encoding")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                options.encoding = args[i];
            } else if (std.mem.eql(u8, arg, "--count-files")) {
                options.count_files = true;
            } else if (std.mem.eql(u8, arg, "--count-tokens")) {
                options.count_tokens = true;
            } else if (std.mem.eql(u8, arg, "--json")) {
                options.json = true;
            } else if (std.mem.eql(u8, arg, "-h") or
                std.mem.eql(u8, arg, "--help"))
            {
                print_help();
                return;
            } else if (std.mem.eql(u8, arg, "--markdown")) {
                options.markdown = true;
            } else if (std.mem.eql(u8, arg, "--raw")) {
                options.raw = true;
            } else {
                std.debug.print("Unknown option: {s}\n", .{arg});
                print_help();
                return error.UnknownOption;
            }
        } else {
            try options.targets.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    try init_tokenizer(options.encoding);
    defer c.tiktoken_cleanup();

    if (options.fzf_mode and options.targets.items.len == 0) {
        var fzf_targets = try run_fzf(allocator);
        defer {
            for (fzf_targets.items) |path| allocator.free(path);
            fzf_targets.deinit(allocator);
        }
        if (fzf_targets.items.len == 0) {
            std.debug.print("No files selected.\n", .{});
            print_help();
            return;
        }
        for (fzf_targets.items) |path| {
            try options.targets.append(allocator, try allocator.dupe(u8, path));
        }
    }

    if (options.targets.items.len == 0) {
        print_help();
        return;
    }

    try process_targets(allocator, options);
}

fn normalize_slashes(
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    var last_was_slash = false;
    for (path) |char| {
        if (char == '/') {
            if (!last_was_slash) try result.append(allocator, char);
            last_was_slash = true;
        } else {
            try result.append(allocator, char);
            last_was_slash = false;
        }
    }
    return result.toOwnedSlice(allocator);
}
fn has_unwanted_extension(path: []const u8) bool {
    const dot_pos = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    const ext = path[dot_pos..];
    if (ext.len > 16) return false;
    var lower_buf: [16]u8 = undefined;
    const lower_ext = std.ascii.lowerString(&lower_buf, ext);
    return unwanted_extensions.has(lower_ext);
}
fn is_dot_folder(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len > 0 and part[0] == '.') return true;
    }
    return false;
}
