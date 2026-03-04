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
    const token = try auth.generateSecureToken(allocator, 128);
    try sql.exec( "INSERT INTO task_queue (task, token, user_email, meta_data) VALUES (?, ?, ?, ?)", .{ task, email, meta});
    return token;
}

pub fn getTask(allocator: std.mem.Allocator, token: []const u8, email: []const u8) !void {
    try sql.getOne(allocator, "SELECT * FROM task_queue WHERE token = ? AND user_email = ?", .{ token, email});
}

pub fn updateTask(allocator: std.mem.Allocator, token: []const u8, status: []const u8, step: usize, is_complete: bool, meta: anytype) !void {
    const md = try std.json.Stringify.valueAlloc(allocator, meta, .{ .emit_null_optional_fields = false });
    defer allocator.free(md);
    if (meta != null){
        try sql.exec("UPDATE task_queue SET status = ?, step = ?, is_complete = ?, meta_data = ? WHERE token = ?", .{ status, step, md, is_complete, token });
    } else {
        try sql.exec("UPDATE task_queue SET status = ?, step = ?, is_complete = ? WHERE token = ?", .{ status, step, is_complete, token });
    }
}
