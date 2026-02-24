const std = @import("std");

const fmt = @import("../fmt.zig");
const server = @import("../server.zig");
const Context = server.Context;
const Callback = server.Callback;
const dynamo = @import("../dynamo.zig");
const auth = @import("../auth.zig");

const IndexParams = struct {
        cid: []const u8,
        aid: []const u8,
        sid: []const u8,
};

pub fn index(c: *Context) !void {
    const user = try dynamo.getUser(c);
    const params = server.Parser.params(IndexParams, c) catch {
        try c.request.respond("", .{.status = .bad_request});
        return;
    };
    _ = params;
    const body = try fmt.renderTemplate(c.io, "./static/index.html", .{ .value = user.pk }, c.allocator);
    defer c.allocator.free(body);
    try c.request.respond(body, .{ .status = .ok, .keep_alive = false });
}


