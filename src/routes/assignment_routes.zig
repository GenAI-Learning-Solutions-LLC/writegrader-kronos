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

// router.get("/:pk/:sk", authMiddleware, async (req: Request, res: Response) => {
//     try {
//         if ((req.params.pk as string).toLowerCase().includes("shared")) {
//             const pk = `ASSIGNMENT#Shared:${req.user.group}`;
//             const assignment: Assignment = await getItemPkSk(
//                 "ASSIGNMENT",
//                 pk,
//                 req.params.sk,
//                 { owner: req.user.email }
//             );
//             res.json(assignment);
//             return;
//         }
//         const assignment: Assignment = await getItemPkSk(
//             "ASSIGNMENT",
//             req.params.pk,
//             req.params.sk,
//             { owner: req.user.email }
//         );
//         console.log("ASSIGNMENT", assignment);
//         if (!assignment) {
//             res.status(404).json(null);
//
//             return;
//         }
//         res.json(assignment);
//         return;
//     } catch (err) {
//         if (err instanceof Error && err.message === "403") {
//             // Handle the permission error specifically
//             console.log("Permission denied - user is not the owner");
//             res.status(403).json({ message: "Internal server error" });
//             return;
//         }
//         console.error("Error in GET /:", err);
//         res.status(500).json({ message: "Internal server error" });
//         return;
//     }
// });

const AssignmentParams = struct {
    cid: []const u8,
    aid: []const u8,
};

const AssignmentOwner = struct {
    OWNER: []const u8,
};

pub fn getAssignment(c: *Context) !void {
    const headers = try server.makeHeaders(c.allocator, c.request);
    const params = try server.Parser.params(AssignmentParams, c);
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
    const raw = blk: {
        const cpx = try c.allocator.dupeZ(u8, "ASSIGNMENT");
        defer c.allocator.free(cpx);
        const cpk = try c.allocator.dupeZ(u8, pk);
        defer c.allocator.free(cpk);
        const csk = try c.allocator.dupeZ(u8, params.aid);
        defer c.allocator.free(csk);
        break :blk dynamo.c.get_item_pk_sk(cpx, cpk, csk);
    };
    if (raw == null) {
        try c.request.respond("null", .{ .status = .not_found, .extra_headers = headers });
        return;
    }
    defer std.c.free(raw);
    const slice = std.mem.span(raw);
    const owner_check = try std.json.parseFromSliceLeaky(AssignmentOwner, c.allocator, slice, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    if (!std.mem.eql(u8, owner_check.OWNER, user.email)) {
        try c.request.respond("", .{ .status = .forbidden, .extra_headers = headers });
        return;
    }
    try c.request.respond(slice, .{ .extra_headers = headers });
}
