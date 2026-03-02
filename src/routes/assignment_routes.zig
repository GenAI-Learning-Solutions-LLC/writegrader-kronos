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



// router.get("/", authMiddleware, async (req: Request, res: Response) => {
//     try {
//         const assignments: Assignment[] = (
//             await getItemsOwnerDT(req.user.email, "ASSIGNMENT")
//         ).filter((a) => !a.pk.toLowerCase().includes("shared"));
//         console.log("assignments", assignments.length);
//         res.json(assignments);
//         return;
//     } catch (err) {
//         console.error("Error in GET /:", err);
//         res.status(500).json({ message: "Internal server error" });
//         return;
//     }
// });


pub fn getAllAssignments(c: *Context) !void {
    const user = try dynamo.getUser(c);
    const headers = try server.makeHeaders(c.allocator, c.request);

    const cached = sql.getAll(c.allocator, "SELECT data FROM fetch_cache WHERE data_type = 'assignments' AND name = ? AND updated_at > datetime('now', '-10 minutes') LIMIT 1", .{user.email}) catch null;
    if (cached) |rows| {
        if (rows.len > 0) {
            const data = rows[0][9 .. rows[0].len - 2];
            try c.request.respond(data, .{ .extra_headers = headers });
            return;
        }
    }

    const cuid = try c.allocator.dupeZ(u8, user.email);
   
    const all = dynamo.c.get_items_owner_dt(cuid, "ASSIGNMENT");
    defer dynamo.c.item_list_free(all);
 
    const json_body = try std.json.Stringify.valueAlloc(c.allocator, all.items, .{ .emit_null_optional_fields = false }); 

    sql.exec("INSERT OR REPLACE INTO fetch_cache (data_type, user, name, data) VALUES ('assignments', ?, ?, ?)", .{ user.email, user.email, json_body }) catch |err| {
        server.debugPrint("cache write failed: {}\n", .{err});
    };

    try c.request.respond(json_body, .{ .extra_headers = headers });
}





