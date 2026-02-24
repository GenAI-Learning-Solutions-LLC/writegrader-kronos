const std = @import("std");

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

// Thread-local storage - each thread gets its own connection and statement
threadlocal var thread_db: ?*c.sqlite3 = null;
threadlocal var thread_stmt: ?*c.sqlite3_stmt = null;
threadlocal var thread_initialized: bool = false;

// Template cache (shared across all threads, read-only after init)
var template_cache: []const u8 = undefined;
var template_allocator: std.mem.Allocator = undefined;

pub fn init(allocator: std.mem.Allocator) !void {
    // Create a single write connection for initialization
    var db: ?*c.sqlite3 = null;
    var rc = c.sqlite3_open_v2("main.db", &db, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX, null);
    if (rc != c.SQLITE_OK) {
        std.debug.print("sqlite3_prepare_v2 error: {s}\n", .{std.mem.span(c.sqlite3_errmsg(thread_db))});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_close(db);

    // Optimize PRAGMA settings
    _ = c.sqlite3_exec(db, "PRAGMA journal_mode=WAL;", null, null, null);
    _ = c.sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", null, null, null);
    _ = c.sqlite3_exec(db, "PRAGMA cache_size=-256000;", null, null, null);
    _ = c.sqlite3_exec(db, "PRAGMA temp_store=MEMORY;", null, null, null);
    _ = c.sqlite3_exec(db, "PRAGMA mmap_size=268435456;", null, null, null);

    // Bulk insert with transaction
    rc = c.sqlite3_exec(db, "BEGIN TRANSACTION;", null, null, null);
    if (rc != c.SQLITE_OK) {
        std.debug.print("sqlite3_prepare_v2 error: {s}\n", .{std.mem.span(c.sqlite3_errmsg(thread_db))});
        return error.PrepareFailed;
    }

   
    if (rc != c.SQLITE_OK) {
        std.debug.print("sqlite3_prepare_v2 error: {s}\n", .{std.mem.span(c.sqlite3_errmsg(thread_db))});
        return error.PrepareFailed;
    }

    // Load and cache the template
    template_allocator = allocator;
    const file = try std.fs.cwd().openFile("pages/resp.html", .{});
    defer file.close();

    const file_size = (try file.stat()).size;
    const buffer = try allocator.alloc(u8, file_size);
    const bytes_read = try file.readAll(buffer);
    template_cache = buffer[0..bytes_read];
}

fn initThreadLocal() !void {
    if (thread_initialized) return;

    const rc = c.sqlite3_open_v2(
        "main.db",
        &thread_db,
        c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX,
        null,
    );
    if (rc != c.SQLITE_OK) {
        std.debug.print("initThreadLocal error: {s}\n", .{std.mem.span(c.sqlite3_errmsg(thread_db))});
        return error.OpenFailed;
    }

    _ = c.sqlite3_exec(thread_db, "PRAGMA journal_mode=WAL;", null, null, null);
    _ = c.sqlite3_exec(thread_db, "PRAGMA synchronous=NORMAL;", null, null, null);
    _ = c.sqlite3_exec(thread_db, "PRAGMA temp_store=MEMORY;", null, null, null);
    _ = c.sqlite3_exec(thread_db, "PRAGMA cache_size=-64000;", null, null, null);

    thread_initialized = true;
}
pub fn exec(sql: []const u8, args: anytype) !void {
    try initThreadLocal();
    if (thread_db == null) {
        std.debug.print("thread_db is null after initThreadLocal\n", .{});
        return error.DatabaseError;
    }
    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(thread_db.?, sql.ptr, @intCast(sql.len), &stmt, null);
    if (rc != c.SQLITE_OK) {
        std.debug.print("sqlite3_prepare_v2 error: {s}\n", .{std.mem.span(c.sqlite3_errmsg(thread_db.?))});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    inline for (fields, 0..) |field, i| {
        const val = @field(args, field.name);
        switch (@typeInfo(@TypeOf(val))) {
            .int, .comptime_int => _ = c.sqlite3_bind_int64(stmt, @intCast(i + 1), @intCast(val)),
            .float, .comptime_float => _ = c.sqlite3_bind_double(stmt, @intCast(i + 1), @floatCast(val)),
            .bool => _ = c.sqlite3_bind_int(stmt, @intCast(i + 1), if (val) 1 else 0),
            .null => _ = c.sqlite3_bind_null(stmt, @intCast(i + 1)),
            .optional => {
                if (val) |v| {
                    _ = c.sqlite3_bind_int64(stmt, @intCast(i + 1), @intCast(v));
                } else {
                    _ = c.sqlite3_bind_null(stmt, @intCast(i + 1));
                }
            },
            .pointer => |ptr| {
                if (ptr.child == u8) {
                    _ = c.sqlite3_bind_text(stmt, @intCast(i + 1), val.ptr, @intCast(val.len), c.SQLITE_STATIC);
                }
            },
            else => @compileError("unsupported bind type: " ++ @typeName(@TypeOf(val))),
        }
    }
    const step_rc = c.sqlite3_step(stmt);
    if (step_rc != c.SQLITE_DONE and step_rc != c.SQLITE_ROW) {
        std.debug.print("sqlite3_step error: {s}\n", .{std.mem.span(c.sqlite3_errmsg(thread_db.?))});
        return error.ExecFailed;
    }
}

pub fn getAll(allocator: std.mem.Allocator, sql: []const u8, args: anytype) ![][]const u8 {
    try initThreadLocal();

    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(thread_db, sql.ptr, @intCast(sql.len), &stmt, null);
    if (rc != c.SQLITE_OK) {
        std.debug.print("sqlite3_prepare_v2 error: {s}\n", .{std.mem.span(c.sqlite3_errmsg(thread_db.?))});
        return error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    inline for (fields, 0..) |field, i| {
        const val = @field(args, field.name);
        switch (@typeInfo(@TypeOf(val))) {
            .int, .comptime_int => _ = c.sqlite3_bind_int64(stmt, @intCast(i + 1), @intCast(val)),
            .float, .comptime_float => _ = c.sqlite3_bind_double(stmt, @intCast(i + 1), @floatCast(val)),
            .bool => _ = c.sqlite3_bind_int(stmt, @intCast(i + 1), if (val) 1 else 0),
            .null => _ = c.sqlite3_bind_null(stmt, @intCast(i + 1)),
            .optional => {
                if (val) |v| {
                    _ = c.sqlite3_bind_int64(stmt, @intCast(i + 1), @intCast(v));
                } else {
                    _ = c.sqlite3_bind_null(stmt, @intCast(i + 1));
                }
            },
            .pointer => |ptr| {
                if (ptr.child == u8) {
                    _ = c.sqlite3_bind_text(stmt, @intCast(i + 1), val.ptr, @intCast(val.len), c.SQLITE_STATIC);
                }
            },
            else => @compileError("unsupported bind type: " ++ @typeName(@TypeOf(val))),
        }
    }

    var rows = std.ArrayList([]const u8){};
    defer rows.deinit(allocator);

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const col_count = c.sqlite3_column_count(stmt);
        var row = std.ArrayList(u8){};
        defer row.deinit(allocator);
        try row.append(allocator, '{');
        for (0..@intCast(col_count)) |i| {
            if (i > 0) try row.append(allocator, ',');
            const col_name = std.mem.span(c.sqlite3_column_name(stmt, @intCast(i)));
            const col_str = try std.fmt.allocPrint(allocator, "\"{s}\":", .{col_name});
            defer allocator.free(col_str);
            try row.appendSlice(allocator, col_str);
            switch (c.sqlite3_column_type(stmt, @intCast(i))) {
                c.SQLITE_INTEGER => {
                    const s = try std.fmt.allocPrint(allocator, "{d}", .{c.sqlite3_column_int64(stmt, @intCast(i))});
                    defer allocator.free(s);
                    try row.appendSlice(allocator, s);
                },
                c.SQLITE_FLOAT => {
                    const s = try std.fmt.allocPrint(allocator, "{d}", .{c.sqlite3_column_double(stmt, @intCast(i))});
                    defer allocator.free(s);
                    try row.appendSlice(allocator, s);
                },
                c.SQLITE_TEXT => {
                    const s = try std.fmt.allocPrint(allocator, "\"{s}\"", .{std.mem.span(c.sqlite3_column_text(stmt, @intCast(i)))});
                    defer allocator.free(s);
                    try row.appendSlice(allocator, s);
                },
                else => try row.appendSlice(allocator, "null"),
            }
        }
        try row.append(allocator, '}');
        try rows.append(allocator, try row.toOwnedSlice(allocator));
    }

    return rows.toOwnedSlice(allocator);
}

pub fn deinit() void {
    // Clean up thread-local resources
    if (thread_stmt) |stmt| {
        _ = c.sqlite3_finalize(stmt);
        thread_stmt = null;
    }
    if (thread_db) |db| {
        _ = c.sqlite3_close(db);
        thread_db = null;
    }
    thread_initialized = false;

    // Clean up template cache
    template_allocator.free(template_cache);
}

// Call this from each thread when it exits (if you have thread cleanup)
pub fn deinitThread() void {
    if (thread_stmt) |stmt| {
        _ = c.sqlite3_finalize(stmt);
        thread_stmt = null;
    }
    if (thread_db) |db| {
        _ = c.sqlite3_close(db);
        thread_db = null;
    }
    thread_initialized = false;
}
