const std = @import("std");

const server = @import("../server.zig");
const Context = server.Context;
const dynamo = @import("../dynamo.zig");
const tasks = @import("../tasks.zig");
const sql = @import("../sql.zig");

const UpdateBody = struct {
    taskToken: []const u8,
    status: []const u8,
    step: usize = 0,
};

pub fn updateTask(c: *Context) !void {
    var origin: []const u8 = "";
    var it = c.request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "origin")) {
            origin = h.value;
            break;
        }
    }
    const h = &[_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Connection", .value = "close" },
        .{ .name = "Access-Control-Allow-Origin", .value = origin },
        .{ .name = "Access-Control-Allow-Credentials", .value = "true" },
    };
    const content_length = c.request.head.content_length orelse {
        try c.request.respond("", .{ .status = .bad_request });
        return;
    };

    const read_buf = try c.allocator.alloc(u8, 4096);
    const reader = try c.request.readerExpectContinue(read_buf);
    const body = try reader.readAlloc(c.allocator, content_length);

    const parsed = try std.json.parseFromSliceLeaky(UpdateBody, c.allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });

    const is_complete = std.mem.eql(u8, parsed.status, "complete");
    if (!std.mem.eql(u8, parsed.status, "error")) {
        tasks.updateTask(c.allocator, parsed.taskToken, parsed.status, parsed.step, is_complete, null) catch {};
    } else {
        tasks.markError(c.allocator, parsed.taskToken, null) catch {};
    }
    try server.sendJson(c.allocator, c.request, .{ .message = "ok" }, .{ .extra_headers = h });
}

pub fn getGradingStatus(c: *Context) !void {
    const user = try dynamo.getUser(c);
    const headers = try server.makeHeaders(c.allocator, c.request);

    const rows = sql.getAll(
        c.allocator,
        "SELECT status, step, meta_data FROM task_queue WHERE user_email = ? AND task = 'grade_submission' AND is_complete = 0 ORDER BY created_at DESC LIMIT 1",
        .{user.email},
    ) catch null;

    try server.sendJson(c.allocator, c.request , rows, .{ .extra_headers = headers });
}
