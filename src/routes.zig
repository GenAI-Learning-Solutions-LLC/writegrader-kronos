const std = @import("std");

const Config = @import("config.zig");
const fmt = @import("fmt.zig");
const server = @import("server.zig");

const stdout = std.io.getStdOut().writer();

pub const routes = &[_]server.Route{
    .{ .path = "/", .callback = index },
};




const IndexQuery = struct {
    value: ?[]const u8,
};
/// return index.html to the home route
fn index(c: server.Context) !void {
    var value: []const u8 = "This is a template string";
    const query = server.Parser.query(IndexQuery, c.allocator, c.request);
    if (query != null) {
        value = try fmt.urlDecode(query.?.value orelse "default", c.allocator);
    }
    const heap = std.heap.page_allocator;
    const body = try fmt.renderTemplate(c.io, "./static/index.html", .{ .value = value }, heap);
    defer heap.free(body);
    try c.request.respond(body, .{ .status = .ok, .keep_alive = false });
}


