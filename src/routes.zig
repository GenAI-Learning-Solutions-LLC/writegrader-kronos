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
const sql = @import("sql.zig");
pub const routes = &[_]server.Route{
    .{ .path = "/*", .method = .OPTIONS, .callback = preflight },
    .{ .path = "/", .middleware = &[_]Callback{
        authMiddleware,
    }, .callback = user_routes.index },
    .{ .path = "/courses/:cid/assignments/:aid/submissions", .middleware = &[_]Callback{
        authMiddleware,
    }, .callback = sub_routes.assignmentSubs },
    .{ .path = "/static/*", .callback = server.static },

};

pub fn preflight(c: *Context) !void {
    const headers = &[_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Connection", .value = "close" },
        .{ .name = "Access-Control-Allow-Origin", .value = "http://localhost:5173" },
        .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, PUT, DELETE, OPTIONS" },
        .{ .name = "Access-Control-Allow-Headers", .value = "Content-Type" },
        .{ .name = "Access-Control-Allow-Credentials", .value = "true" },
    };
    try c.request.respond("", .{ .status = .ok, .keep_alive = false,.extra_headers = headers });



}

pub fn index(c: *Context) !void {
    const user = try dynamo.getUser(c);
    const body = try fmt.renderTemplate(c.io, "./static/index.html", .{ .value = user.pk }, c.allocator);
    defer c.allocator.free(body);
    try c.request.respond(body, .{ .status = .ok, .keep_alive = false });
}


fn authMiddleware(c: *Context) !void {
    const cookies = try server.Parser.parseCookies(c.allocator, c.request);
    const token = cookies.get("userToken");
    if (token == null) {
        try c.request.respond("", .{ .status = .forbidden, .keep_alive = false });
        return error.Client;
    }
    const decoded = try auth.decodeAuth(c.allocator, token.?);

    const cached = sql.getAll(c.allocator, "SELECT data FROM fetch_cache WHERE data_type = 'user' AND name = ? AND updated_at > datetime('now', '-5 minutes') LIMIT 1", .{decoded.user}) catch null;
    if (cached) |rows| {
        if (rows.len > 0) {
            const data = rows[0][9 .. rows[0].len - 2];
            std.debug.print("cached user:{s}\n", .{data});
            try c.put("user", data);
            return;
        }
    }

    const c_str = try std.heap.c_allocator.dupeZ(u8, decoded.user);
    defer std.heap.c_allocator.free(c_str);
    const result = dynamo.c.get_item_pk_sk("USER", c_str, c_str);
    if (result == null) {
        try c.request.respond("", .{ .status = .forbidden, .keep_alive = false });
        return;
    }
    defer std.c.free(result);
    const slice = std.mem.span(result);

    sql.exec("INSERT OR REPLACE INTO fetch_cache (data_type, user, name, data) VALUES ('user', ?, ?,?)", .{ decoded.user, decoded.user, slice }) catch |err| {
        std.debug.print("cache write failed: {}\n", .{err});
        try c.request.respond("", .{ .status = .internal_server_error, .keep_alive = false });
        return err;
    };

    const owned = try c.allocator.dupe(u8, slice);
    try c.put("user", owned);
}
