const std = @import("std");
const auth = @import("auth.zig");
const sql = @import("sql.zig");

// CREATE TABLE IF NOT EXISTS task_queue (
//     id INTEGER PRIMARY KEY AUTOINCREMENT,
//     task TEXT NOT NULL,
//     step INTEGER DEFAULT 0,
//     token TEXT NOT NULL, -- used for other services to be able to make updates to a specific task
//     user_email TEXT NOT NULL,
//     status TEXT NOT NULL DEFAULT 'ready' CHECK (status IN ('ready', 'stopped', 'running', 'complete', 'error')),
//     is_complete INTEGER DEFAULT 0,
//     meta_data TEXT NOT NULL CHECK (json_valid(meta_data)),
//     created_at DATETIME DEFAULT (datetime('now', 'utc')),
//     updated_at DATETIME DEFAULT (datetime('now', 'utc'))
// );
pub fn createTask(allocator: std.mem.Allocator, task: []const u8, email: []const u8, meta: anytype) ![]const u8 {
    const token = auth.generateSecureToken() catch |err| {
        std.log.err("generateSecureToken failed: {}\n", .{err});
        return err;
    };
    std.log.info("token {s}\n", .{token});

    sql.exec("INSERT INTO task_queue (task, token, user_email, meta_data) VALUES (?, ?, ?, ?)", .{ task, token, email, meta }) catch |err| {
        std.log.err("task insert failed: {}\n", .{err});
        return err;
    };
    return try allocator.dupe(u8, token);
}

pub fn getTask(allocator: std.mem.Allocator, token: []const u8, email: []const u8) !?[]const u8 {
    return sql.getOne(allocator, "SELECT * FROM task_queue WHERE token = ? AND user_email = ?", .{ token, email });
}

pub fn updateTask(allocator: std.mem.Allocator, token: []const u8, status: []const u8, step: usize, is_complete: bool, meta: anytype) !void {
    const has_meta = switch (@typeInfo(@TypeOf(meta))) {
        .null => false,
        .optional => meta != null,
        else => true,
    };
    if (has_meta) {
        const md = try std.json.Stringify.valueAlloc(allocator, meta, .{ .emit_null_optional_fields = false });
        defer allocator.free(md);
        try sql.exec("UPDATE task_queue SET status = ?, step = ?, is_complete = ?, meta_data = ? WHERE token = ?", .{ status, step, is_complete, md, token });
    } else {
        try sql.exec("UPDATE task_queue SET status = ?, step = ?, is_complete = ? WHERE token = ?", .{ status, step, is_complete, token });
    }
}



pub fn markError(allocator: std.mem.Allocator, token: []const u8, meta: anytype) !void {
    const has_meta = switch (@typeInfo(@TypeOf(meta))) {
        .null => false,
        .optional => meta != null,
        else => true,
    };
    if (has_meta) {
        const md = try std.json.Stringify.valueAlloc(allocator, meta, .{ .emit_null_optional_fields = false });
        defer allocator.free(md);
        try sql.exec("UPDATE task_queue SET status = 'error', meta_data = ? WHERE token = ?", .{md, token });
    } else {
        try sql.exec("UPDATE task_queue SET status = 'error' WHERE token = ?", .{token });
    }
}
