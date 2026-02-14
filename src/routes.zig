const std = @import("std");

const Config = @import("config.zig");
const fmt = @import("fmt.zig");
const server = @import("server.zig");

const stdout = std.io.getStdOut().writer();

pub const routes = &[_]server.Route{
    .{ .path = "/", .callback = index },
    .{ .path = "/static/*", .callback = server.static},
    .{ .path = "/", .method = .POST, .callback = postEndpoint },
    .{ .path = "/api/:endpoint", .method = .POST, .callback = postEndpoint },
};

fn index(c: server.Context) !void {
    var value: []const u8 = "This is a template string, use a query string to replace it. (?value=something)";
    const query = server.Parser.query(struct {value: ?[]const u8}, c.allocator, c.request);
    if (query != null) {
        value = try server.Parser.urlDecode(query.?.value orelse "default", c.allocator);
    }
    const heap = std.heap.page_allocator;
    const body = try fmt.renderTemplate(c.io, "./static/index.html", .{ .value = value }, heap);
    defer heap.free(body);
    try c.request.respond(body, .{ .status = .ok, .keep_alive = false });
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

fn postEndpoint(c: server.Context) !void {
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


