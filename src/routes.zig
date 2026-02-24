const std = @import("std");

const Config = @import("config.zig");
const fmt = @import("fmt.zig");
const server = @import("server.zig");
const Context = server.Context;
const Callback = server.Callback;
const dynamo = @import("dynamo.zig");
const auth = @import("auth.zig");
pub const routes = &[_]server.Route{
    .{ .path = "/", .middleware = &[_]Callback{
        authMiddleware,
    }, .callback = index },
    .{ .path = "/static/*", .callback = server.static },
    .{ .path = "/:param", .callback = param_test },

    .{ .path = "/api/:endpoint", .method = .POST, .callback = postEndpoint },
};


const SubscriptionInfo = struct {
    cancelAt: ?f64 = null,
    credits: ?f64 = 10,
    approvals: ?f64 = 0,
    creditsUsed: f64 = 0,
    totalUsed: f64 = 0,
    endDate: ?[]const u8 = null,
    plan: []const u8 = "starter",
    premium: bool = false,
    refreshDate: ?[]const u8 = null,
    startDate: ?[]const u8 = null,
    status: []const u8,
    stripeCid: []const u8,
    stripePid: []const u8,
};

const User = struct {
    pk: []const u8,
    sk: []const u8,
    DATATYPE: []const u8 = "USER",
    email: []const u8,
    group: ?[]const u8 = null,
    isAdmin: bool = false,
    groupAdmin: bool = false,
    metaData: ?std.json.Value = null,
    name: []const u8,
    OWNER: []const u8 = "USER",
    settings: ?std.json.Value = null,
    subscriptionInfo: SubscriptionInfo,
    createdAt: ?[]const u8 = null,
    updatedAt: ?[]const u8 = null,
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

fn getUser(c: *Context) !User {
    const slice = c.get("user") orelse {
        try c.request.respond("", .{ .status = .forbidden, .keep_alive = false });
        return error.Unauthorized;
    };
    const parsed = try std.json.parseFromSlice(User, c.allocator, slice, .{
        .ignore_unknown_fields = true,
    });
    return parsed.value;
}


fn index(c: *Context) !void {
    const user = try getUser(c);
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
