const std = @import("std");
const Config = @import("config.zig");
const server = @import("server.zig");
const r = @import("routes.zig");


const stdout = std.io.getStdOut().writer();
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var settings = try Config.init(init.io, "config.json", allocator);
    defer settings.deinit(allocator);
    
    var routes = std.ArrayList(server.Route){};
    try routes.appendSlice(allocator, r.routes);
    defer routes.deinit(allocator);
    var s = try server.Server.init(init.gpa, init.io, &settings);
    try s.runServer(.{ .routes = routes });
}
