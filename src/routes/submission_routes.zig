const std = @import("std");

const fmt = @import("../fmt.zig");
const server = @import("../server.zig");
const Context = server.Context;
const Callback = server.Callback;
const dynamo = @import("../dynamo.zig");
const auth = @import("../auth.zig");
const sql = @import("../sql.zig");

const headers = &[_]std.http.Header{
    .{ .name = "Content-Type", .value = "application/json" },
    .{ .name = "Connection", .value = "close" },
    .{ .name = "Access-Control-Allow-Origin", .value = "http://localhost:5173" },
    .{ .name = "Access-Control-Allow-Credentials", .value = "true" },
};
const IndexParams = struct {
    cid: []const u8,
    aid: []const u8,
};
pub fn index(c: *Context) !void {
    const user = try dynamo.getUser(c);

    server.debugPrint("Here\n", .{});
    const params = server.Parser.params(IndexParams, c) catch {
        try c.request.respond("<h1>nothing found</h1>", .{ .status = .ok });
        return;
    };
    server.debugPrint("Here {s}\n", .{params.aid});
    const submissions = try dynamo.getItemsOwnerPk(dynamo.Submission, c.allocator, "SUBMISSION", user.email, params.aid);

    try server.sendJson(c.allocator, c.request, submissions, .{ .extra_headers = headers });
}

//todo check ownership using shared access
const SubmissionParams = struct {
    cid: []const u8,
    aid: []const u8,
    sid: []const u8,
};

pub fn get_submission(c: *Context) !void {
    const user = try dynamo.getUser(c);
    server.debugPrint("Here\n", .{});
    const params = server.Parser.params(SubmissionParams, c) catch {
        try c.request.respond("", .{ .status = .bad_request });
        return;
    };
    server.debugPrint("Here {s}\n", .{params.aid});
    const submission = try dynamo.getItemPkSk(dynamo.Submission, c.allocator, "SUBMISSION", params.aid, params.sid);
    if (submission) |s| {
        if (std.mem.eql(u8, user.email, s.OWNER)) {
            try server.sendJson(c.allocator, c.request, s, .{ .extra_headers = headers });
            return;
        }
    }
    try server.sendJson(c.allocator, c.request, null, .{ .extra_headers = headers });
}
