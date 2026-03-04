const std = @import("std");

const server = @import("../server.zig");
const Context = server.Context;
const tasks = @import("../tasks.zig");

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
    if (!std.mem.eql(u8, parsed.status, "error")){
        tasks.updateTask(c.allocator, parsed.taskToken, parsed.status, parsed.step, is_complete, null) catch {};
    } else {
        tasks.markError(c.allocator, parsed.taskToken, null) catch {};
    }
    try server.sendJson(c.allocator, c.request, .{ .message = "ok" }, .{ .extra_headers = h });
}
