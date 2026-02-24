const std = @import("std");

const Config = @import("config.zig");
const fmt = @import("fmt.zig");
const server = @import("server.zig");
const Context = server.Context;
const Callback = server.Callback;
const dynamo = @import("dynamo.zig");
const auth = @import("auth.zig");
const user_routes = @import("routes/user_routes.zig");
const sub_routes = @import("routes/submission_routes.zig");
pub const routes = &[_]server.Route{
    .{ .path = "/", .middleware = &[_]Callback{
        authMiddleware,
    }, .callback = user_routes.index },
    .{ .path = "/courses/:cid/assignments/:aid/submissions", .middleware = &[_]Callback{
        authMiddleware,
    }, .callback = sub_routes.index },
    .{ .path = "/static/*", .callback = server.static },
};




fn authMiddleware(c: *Context) !void {
    const cookies = try server.Parser.parseCookies(c.allocator, c.request);
    const token = cookies.get("userToken");
    if (token == null) {
        try c.request.respond("", .{ .status = .forbidden, .keep_alive = false });
        return error.Client;
    }
    const decoded = try auth.decodeAuth(c.allocator, token.?);
    const c_str = try std.heap.c_allocator.dupeZ(u8, decoded.user);
    defer std.heap.c_allocator.free(c_str);
    const result = dynamo.c.get_item_pk_sk("USER", c_str, c_str);
    if (result == null) {
        try c.request.respond("", .{ .status = .forbidden, .keep_alive = false });
        return;
    }
    defer std.c.free(result);
    const slice = std.mem.span(result);
    const owned = try c.allocator.dupe(u8, slice);
    try c.put("user", owned);
}


