const std = @import("std");

const fmt = @import("../fmt.zig");
const server = @import("../server.zig");
const Context = server.Context;
const Callback = server.Callback;
const dynamo = @import("../dynamo.zig");
const User = dynamo.User;

const auth = @import("../auth.zig");

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



pub fn index(c: *Context) !void {
    const user = try dynamo.getUser(c);
    const body = try fmt.renderTemplate(c.io, "./static/index.html", .{ .value = user.pk }, c.allocator);
    defer c.allocator.free(body);
    try c.request.respond(body, .{ .status = .ok, .keep_alive = false });
}

const TestParams = struct {
    param: []const u8,
};

fn param_test(c: *Context) !void {
    const params = server.Parser.params(TestParams, c) catch TestParams{ .param = "Could not parse" };
    try c.request.respond(params.param, .{ .status = .ok, .keep_alive = false });
}

const PubCounter = struct {
    value: i64,
    lock: std.Io.Mutex,
};

var pubCounter = PubCounter{
    .value = 0,
    .lock = .init,
};

const PostInput = struct {
    request: []const u8,
};
const PostResponse = struct {
    message: []const u8,
    endpoint: []const u8,
    counter: i64,
};

fn postEndpoint(c: *Context) !void {
    _ = try pubCounter.lock.lock(c.io);
    pubCounter.value += 1;
    _ = pubCounter.lock.unlock(c.io);
    const reqBody = try server.Parser.json(PostInput, c.allocator, c.request);
    const out = PostResponse{
        .message = "Hello from Zoi!",
        .endpoint = "",
        .counter = if (std.mem.eql(u8, reqBody.request, "counter")) pubCounter.value else 0,
    };
    const headers = &[_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };
    try server.sendJson(c.allocator, c.request, out, .{ .status = .ok, .keep_alive = false, .extra_headers = headers });
}
