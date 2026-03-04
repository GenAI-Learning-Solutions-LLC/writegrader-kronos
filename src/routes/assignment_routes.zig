const std = @import("std");

const fmt = @import("../fmt.zig");
const server = @import("../server.zig");
const Context = server.Context;
const Callback = server.Callback;
const dynamo = @import("../dynamo.zig");
const auth = @import("../auth.zig");
const sql = @import("../sql.zig");
const utils = @import("../utils.zig");
const types = @import("../schema.zig");

const AssignmentParams = struct {
    cid: []const u8,
    aid: []const u8,
};
pub fn getAssignment(c: *Context) !void {
    const headers = try server.makeHeaders(c.allocator, c.request);
    const params = try server.Parser.params(AssignmentParams, c);
    server.debugPrint("\n\n\n-------route: {s}", .{c.request.head.target});
    const user = dynamo.getUser(c) catch {
        try c.request.respond("", .{ .status = .forbidden, .extra_headers = headers });
        return;
    };
    const pk = blk: {
        if (std.ascii.indexOfIgnoreCase(params.cid, "shared") != null) {
            break :blk try std.fmt.allocPrint(c.allocator, "Shared:{s}", .{user.group orelse ""});
        }
        break :blk params.cid;
    };
    const assignment = (try dynamo.getItemPkSk(types.assignment.Assignment, c.allocator, "ASSIGNMENT", pk, params.aid)) orelse {
        server.debugPrint("----houston we have a null {s}\n", .{c.request.head.target});

        try server.sendJson(c.allocator, c.request, null, .{ .status = .not_found, .extra_headers = headers });

        return;
    };
    if (!std.mem.eql(u8, assignment.OWNER, user.email)) {
        try c.request.respond("", .{ .status = .forbidden, .extra_headers = headers });
        return;
    }
    server.debugPrint("----houston we have an object {s}\n", .{assignment.sk});

    try server.sendJson(c.allocator, c.request, assignment, .{ .extra_headers = headers });
    return;
}

pub fn getAllAssignments(c: *Context) !void {
    const headers = try server.makeHeaders(c.allocator, c.request);
    const user = dynamo.getUser(c) catch {
        try c.request.respond("", .{ .status = .forbidden, .extra_headers = headers });
        return;
    };

    const cached = sql.getAll(c.allocator, "SELECT data FROM fetch_cache WHERE data_type = 'assignments' AND name = ? AND updated_at > datetime('now', '-10 minutes') LIMIT 1", .{user.email}) catch null;
    if (cached) |rows| {
        if (rows.len > 0) {
            const data = rows[0][9 .. rows[0].len - 2];
            try c.request.respond(data, .{ .extra_headers = headers });
            return;
        }
    }

    const cuid = try c.allocator.dupeZ(u8, user.email);
    defer c.allocator.free(cuid);
    const cdt = try c.allocator.dupeZ(u8, "ASSIGNMENT");
    defer c.allocator.free(cdt);

    var raw = dynamo.c.get_items_owner_dt(cuid, cdt);
    defer dynamo.c.item_list_free(&raw);

    var list: std.ArrayList(u8) = .{};
    try list.append(c.allocator, '[');
    var first = true;
    for (0..@intCast(raw.count)) |i| {
        const item = std.mem.span(raw.items[i]);
        const PkOnly = struct { pk: []const u8 };
        const pk_check = std.json.parseFromSliceLeaky(PkOnly, c.allocator, item, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch continue;
        if (std.ascii.indexOfIgnoreCase(pk_check.pk, "shared") != null) continue;
        if (!first) try list.append(c.allocator, ',');
        try list.appendSlice(c.allocator, item);
        first = false;
    }
    try list.append(c.allocator, ']');
    const json_body = try list.toOwnedSlice(c.allocator);

    sql.exec("INSERT OR REPLACE INTO fetch_cache (data_type, user_email, name, data) VALUES ('assignments', ?, ?, ?)", .{ user.email, user.email, json_body }) catch |err| {
        server.debugPrint("cache write failed: {}\n", .{err});
    };

    try c.request.respond(json_body, .{ .extra_headers = headers });
}

pub fn saveAssignment(c: *Context) !void {
    const user = try dynamo.getUser(c);
    const headers = try server.makeHeaders(c.allocator, c.request);

    const content_length = c.request.head.content_length orelse {
        try c.request.respond("", .{ .status = .bad_request });
        return;
    };
    const read_buf = try c.allocator.alloc(u8, 4096);
    const reader = try c.request.readerExpectContinue(read_buf);
    const body = try reader.readAlloc(c.allocator, content_length);

    var parsed = std.json.parseFromSliceLeaky(types.assignment.Assignment, c.allocator, body, .{ .allocate = .alloc_always }) catch {
        try c.request.respond("", .{ .status = .bad_request, .extra_headers = headers });
        return;
    };
    parsed.updatedAt = utils.stampUTC(c.allocator) catch parsed.updatedAt;

    const has_access = utils.checkAssignmentAccess(c.allocator, user.email, parsed.pk, parsed.sk) catch false;
    if (!has_access) {
        try c.request.respond("", .{ .status = .forbidden, .extra_headers = headers });
        return;
    }

    const modified_body = try std.json.Stringify.valueAlloc(c.allocator, parsed, .{ .emit_null_optional_fields = false });
    dynamo.saveItem(c.allocator, modified_body, user.email) catch {
        try c.request.respond("", .{ .status = .internal_server_error, .extra_headers = headers });
        return;
    };

    invalidateAssignmentCache(user.email);
    try server.sendJson(c.allocator, c.request, .{ .message = "success" }, .{ .extra_headers = headers });
}

pub fn invalidateAssignmentCache(user_email: []const u8) void {
    sql.exec("DELETE FROM fetch_cache WHERE data_type IN ('assignments', 'assignment') AND user_email = ?", .{user_email}) catch |err| {
        std.debug.print("cache invalidate failed: {}\n", .{err});
    };
}
