const std = @import("std");

const fmt = @import("../fmt.zig");
const server = @import("../server.zig");
const Context = server.Context;
const Callback = server.Callback;
const dynamo = @import("../dynamo.zig");
const auth = @import("../auth.zig");
const sql = @import("../sql.zig");
const IndexParams = struct {
    cid: []const u8,
    aid: []const u8,
};

pub fn index(c: *Context) !void {
    const user = try dynamo.getUser(c);
    const headers = &[_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Connection", .value = "close" },
    };
    server.debugPrint("Here\n", .{});
    const params = server.Parser.params(IndexParams, c) catch {
        try c.request.respond("<h1>nothing found</h1>", .{ .status = .ok });
        return;
    };
    server.debugPrint("Here {s}\n", .{params.aid});
    const submissions = try dynamo.getItemsOwnerPk(dynamo.Submission, std.heap.c_allocator, "SUBMISSION", user.email, params.aid);
    defer std.heap.c_allocator.free(submissions);

    try server.sendJson(std.heap.c_allocator, c.request, submissions, .{ .extra_headers = headers });
}
