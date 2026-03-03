const std = @import("std");

const fmt = @import("../fmt.zig");
const server = @import("../server.zig");
const Context = server.Context;
const Callback = server.Callback;
const dynamo = @import("../dynamo.zig");
const auth = @import("../auth.zig");
const sql = @import("../sql.zig");
const utils = @import("../utils.zig");

const SubmissionIndexParams = struct {
    cid: []const u8,
    aid: []const u8,
};

// router.put("/", authMiddleware, async (req: Request, res: Response) => {
//     try {
//         const input = v.parse(SubmissionSchema, req.body);
//         input.assignmentId = stringStem(input.pk);
//         await checkSubmissionAccess(req, input);
//         if (!input.classId) {
//             const assignments: Assignment[] = await getItemsOwnerDT(
//                 req.user.email,
//                 "ASSIGNMENT"
//             );
//
//             for (let i = 0; i < assignments.length; i++) {
//                 const assignment = assignments[i];
//                 if (stringStem(assignment.sk) == input.assignmentId) {
//                     input.classId = stringStem(assignment.pk);
//                 }
//             }
//         }
//
//         const sub = req?.user?.subscriptionInfo || {};
//         const exists: Submission = await getItemPkSk(
//             "SUBMISSION",
//             input.pk,
//             input.sk
//         );
//         if (!req.user.group && !exists && !req.user.isAdmin) {
//             if (sub.credits - sub.creditsUsed + (sub.bonus || 0) <= 0) {
//                 res.status(403).json({
//                     error: "Upload credits are below 0",
//                 });
//                 return;
//             }
//         }
//         if (!exists) {
//             await updateCreditsUsed(req.user);
//         }
//         if (exists?.status != "approved" && input?.status == "approved") {
//             await updateApprovals(req.user);
//             try {
//                 const ping = await fetchIPC("/approval", {
//                     ...input,
//                     group: req.user.group || "INDIVIDUAL",
//                 });
//             } catch (err) {
//                 console.error(err);
//             }
//             const assignment: Assignment = await getItemPkSk(
//                 "ASSIGNMENT",
//                 exists.classId,
//                 exists.pk
//             );
//             const c = await getItemPkSk(
//                 "CLASS",
//                 req.user.email,
//                 exists.classId
//             );
//
//             const report = createReport(input as Submission, assignment, c);
//             if (input.externalId) {
//                 await upsertAndAppendToList(
//                     "externalApproval",
//                     `${req.user.email}:${input.externalId.split(":")[2]}:${input.externalId.split(":")[4]}:${input.externalId.split(":")[1]}:${input.externalId.split(":")[3]}:${input.externalId.split(":")[0]}`,
//                     req.user.group || "INDIVIDUAL"
//                 );
//             } else {
//                 await upsertAndAppendToList(
//                     "directApproval",
//                     `${req.user.email}:${stringStem(input.sk)}`,
//                     req.user.group || "INDIVIDUAL"
//                 );
//             }
//
//             await saveItem(report, {
//                 owner: req.user.email,
//             });
//         } else if (
//             exists?.status == "approved" &&
//             input?.status != "approved"
//         ) {
//             const assignment: Assignment = await getItemPkSk(
//                 "ASSIGNMENT",
//                 exists.classId,
//                 exists.pk
//             );
//             const c = await getItemPkSk(
//                 "CLASS",
//                 req.user.email,
//                 exists.classId
//             );
//
//             const report = createReport(input as Submission, assignment, c);
//             if (input.externalId) {
//                 await upsertAndAppendToList(
//                     "externalUnapproval",
//                     `${req.user.email}:${input.externalId.split(":")[2]}:${input.externalId.split(":")[4]}:${input.externalId.split(":")[1]}:${input.externalId.split(":")[3]}:${input.externalId.split(":")[0]}`,
//                     req.user.group || "INDIVIDUAL"
//                 );
//             } else {
//                 await upsertAndAppendToList(
//                     "directUnapproval",
//                     `${req.user.email}:${stringStem(input.sk)}`,
//                     req.user.group || "INDIVIDUAL"
//                 );
//             }
//
//             await saveItem(report, {
//                 owner: req.user.email,
//             });
//         }
//
//         const output = await saveItem(input);
//
//         res.json(output);
//         return;
//     } catch (err) {
//         console.error("Error in PUT /:", err.issues[0].path);
//         res.status(500).json({ message: "Internal server error" });
//         return;
//     }
// });
//

pub fn approveSubmission(c: *Context) !void {
    const user = try dynamo.getUser(c);
    const headers = try server.makeHeaders(c.allocator, c.request);
    const content_length = c.request.head.content_length orelse {
        try c.request.respond("", .{ .status = .bad_request });
        return;
    };
    const read_buf = try c.allocator.alloc(u8, 4096);
    const reader = try c.request.readerExpectContinue(read_buf);
    const body = try reader.readAlloc(c.allocator, content_length);
    var parsed: dynamo.Submission = try std.json.parseFromSliceLeaky(dynamo.Submission, c.allocator, body, .{ .allocate = .alloc_always });
    const has_access = utils.checkAssignmentAccess(c.allocator, user.email, parsed.classId, parsed.assignmentId) catch |err| blk: {
        server.debugPrint("{any}\n", .{err});
        break :blk false;
    };
    if (!has_access) {
        try c.request.respond("{\"error\":\"You do not have access to this submission\"}", .{ .status = .forbidden, .extra_headers = headers });
        return;
    }
    const is_new = try utils.isItemNew(c.allocator, user.email, "submission", parsed.pk, parsed.sk);
    if (is_new and (if (user.group) |g| g.len == 0 else true) and !user.isAdmin) {
        try c.request.respond("{\"error\":\"Cannot approve new submission\"}", .{ .status = .bad_request, .extra_headers = headers });
        return;
    }
    parsed.status = "approved";
    parsed.updatedAt = utils.stampUTC(c.allocator) catch parsed.updatedAt;
    server.debugPrint("approved\n", .{});
    dynamo.saveObj(c.allocator, parsed, parsed.OWNER) catch {
        try c.request.respond("{\"error\":\"Internal Server Error\"}", .{ .status = .internal_server_error, .extra_headers = headers });
    };
    try server.sendJson(c.allocator, c.request, .{ .message = "success" }, .{ .extra_headers = headers });
}

fn stampAndNormalise(allocator: std.mem.Allocator, obj: *std.json.ObjectMap) !void {
    var ts_buf: [32]u8 = undefined;
    dynamo.c.iso_timestamp(&ts_buf, ts_buf.len);
    const ts = try allocator.dupe(u8, std.mem.sliceTo(&ts_buf, 0));
    try obj.put("updatedAt", .{ .string = ts });

    if (obj.get("pk")) |pk_val| {
        switch (pk_val) {
            .string => |pk| {
                const stem = if (std.mem.indexOf(u8, pk, "#")) |idx| pk[idx + 1 ..] else pk;
                try obj.put("assignmentId", .{ .string = stem });
            },
            else => {},
        }
    }
}
