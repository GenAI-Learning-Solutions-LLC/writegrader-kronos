const std = @import("std");

const fmt = @import("../fmt.zig");
const server = @import("../server.zig");
const Context = server.Context;
const Callback = server.Callback;
const dynamo = @import("../dynamo.zig");
const auth = @import("../auth.zig");
const sql = @import("../sql.zig");
const utils = @import("../utils.zig");
const schema = @import("../schema/assignment.zig");

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

fn stringStem(s: []const u8) []const u8 {
    return if (std.mem.indexOf(u8, s, "#")) |idx| s[idx + 1 ..] else s;
}

fn gradeItemBoolMeta(item: dynamo.GradeItem, key: []const u8) bool {
    const md = item.metaData orelse return false;
    return switch (md) {
        .object => |o| if (o.get(key)) |v| switch (v) {
            .bool => |b| b,
            else => false,
        } else false,
        else => false,
    };
}

fn getCriterionPoints(criterion: dynamo.GradeItem, severity: f64) f64 {
    if (criterion.score == 0) return 0;
    const points = criterion.points orelse 0;
    if (points < 0) return 0; // deductions simplified
    const s = severity / 100.0 + 1.0;
    const virtual_points = points * s;
    var out = (criterion.score / 100.0) * virtual_points;
    out = @round(out * 10.0) / 10.0;
    return out;
}

fn getMaxPoints(criteria: []const dynamo.GradeItem) f64 {
    var points: f64 = 0;
    for (criteria) |c| {
        const teacher_only = gradeItemBoolMeta(c, "teacherOnly");
        const feedback_only = gradeItemBoolMeta(c, "feedbackOnly");
        if ((c.points orelse 0) >= 0 and !teacher_only and !feedback_only) {
            points += c.points orelse 0;
        }
    }
    return @round(points * 10.0) / 10.0;
}

fn getScore(severity: f64, criteria: []const dynamo.GradeItem, status: []const u8) f64 {
    const bounce_stati = [_][]const u8{ "rejected", "failed_grading", "failed_parsing", "error_grading", "error_parsing" };
    for (bounce_stati) |bs| {
        if (std.mem.eql(u8, status, bs)) return 0;
    }
    if (criteria.len == 0) return 100;

    var score: f64 = 0;
    var points: f64 = 0;
    var all_special = true;

    for (criteria) |c| {
        const teacher_only = gradeItemBoolMeta(c, "teacherOnly");
        const feedback_only = gradeItemBoolMeta(c, "feedbackOnly");
        if (!teacher_only and !feedback_only) {
            all_special = false;
            const s = getCriterionPoints(c, severity);
            score += if (std.math.isNan(s)) 0 else s;
            if ((c.points orelse 0) >= 0) points += c.points orelse 0;
        }
    }

    if (all_special) return 100;
    if (points == 0) return 100;
    if (score == 0) return 0;

    const pct = (score / points) * 100.0;
    return @max(0.0, @min(pct, 100.0));
}

fn rangeLabel(value: f64, item: dynamo.GradeItem) []const u8 {
    const md = item.metaData orelse return "";
    const sub_criterion = switch (md) {
        .object => |o| o.get("subCriterion") orelse return "",
        else => return "",
    };
    const arr = switch (sub_criterion) {
        .array => |a| a.items,
        else => return "",
    };

    var closest_label: []const u8 = "";
    var min_distance: f64 = std.math.inf(f64);

    for (arr) |sc| {
        const sc_obj = switch (sc) {
            .object => |o| o,
            else => continue,
        };
        const name_val = sc_obj.get("name") orelse continue;
        const name = switch (name_val) {
            .string => |s| s,
            else => continue,
        };
        const range_val = sc_obj.get("range") orelse continue;
        const range = switch (range_val) {
            .array => |a| a.items,
            else => continue,
        };
        if (range.len < 2) continue;
        const r0 = switch (range[0]) {
            .float => |f| f,
            .integer => |i| @as(f64, @floatFromInt(i)),
            else => continue,
        };
        const r1 = switch (range[1]) {
            .float => |f| f,
            .integer => |i| @as(f64, @floatFromInt(i)),
            else => continue,
        };
        const rmin = @min(r0, r1);
        const rmax = @max(r0, r1);
        if (value >= rmin and value <= rmax) return name;
        const distance = if (value < rmin) rmin - value else value - rmax;
        if (distance < min_distance) {
            min_distance = distance;
            closest_label = name;
        }
    }
    return closest_label;
}

fn gradeItemToValue(allocator: std.mem.Allocator, item: dynamo.GradeItem) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("name", .{ .string = item.name });
    try obj.put("rationale", .{ .string = item.rationale });
    try obj.put("score", .{ .float = item.score });
    if (item.points) |pts| try obj.put("points", .{ .float = pts });
    if (item.metaData) |md| try obj.put("metaData", md);
    return .{ .object = obj };
}

const ClassBasic = struct {
    name: []const u8 = "none",
};

fn createAndSaveReport(
    allocator: std.mem.Allocator,
    owner: []const u8,
    submission: dynamo.Submission,
    assignment: schema.Assignment,
    class_name: []const u8,
) !void {
    var obj = std.json.ObjectMap.init(allocator);

    const pk_stem = stringStem(submission.pk);
    const sk_stem = stringStem(submission.sk);
    const report_pk = try std.fmt.allocPrint(allocator, "STUDENT_REPORT#{s}", .{pk_stem});
    const report_sk = try std.fmt.allocPrint(allocator, "STUDENT_REPORT#{s}", .{sk_stem});

    try obj.put("pk", .{ .string = report_pk });
    try obj.put("sk", .{ .string = report_sk });
    try obj.put("OWNER", .{ .string = submission.OWNER });
    try obj.put("DATATYPE", .{ .string = "STUDENT_REPORT" });
    try obj.put("submissionName", .{ .string = submission.name });
    try obj.put("assignmentName", .{ .string = assignment.name });
    try obj.put("className", .{ .string = class_name });
    try obj.put("wordCount", .{ .float = submission.wordCount orelse 0 });
    try obj.put("createdAt", .{ .string = try utils.stampUTC(allocator) });

    // overallFeedback with computed score/points
    const max_pts = getMaxPoints(submission.criteria);
    const score_pct = getScore(assignment.severity, submission.criteria, submission.status);
    var of = std.json.ObjectMap.init(allocator);
    try of.put("name", .{ .string = submission.overallFeedback.name });
    try of.put("rationale", .{ .string = submission.overallFeedback.rationale });
    try of.put("points", .{ .float = max_pts });
    try of.put("score", .{ .float = (score_pct / 100.0) * max_pts });
    try of.put("metaData", .{ .object = std.json.ObjectMap.init(allocator) });
    try obj.put("overallFeedback", .{ .object = of });

    if (submission.teachersComments) |tc| {
        try obj.put("teacherComments", try gradeItemToValue(allocator, tc));
    }

    // criteria: filter teacherOnly, map with computed score/points
    var criteria_arr = std.json.Array.init(allocator);
    for (submission.criteria) |criterion| {
        if (gradeItemBoolMeta(criterion, "teacherOnly")) continue;

        const feedback_only = gradeItemBoolMeta(criterion, "feedbackOnly");
        const pts: f64 = if (feedback_only) 0 else (criterion.points orelse 0);
        const score = getCriterionPoints(criterion, assignment.severity);
        const label = rangeLabel(score, criterion);

        var c_meta = std.json.ObjectMap.init(allocator);
        try c_meta.put("label", .{ .string = label });
        if (criterion.metaData) |md| try c_meta.put("feedbackOnly", md);

        var c_obj = std.json.ObjectMap.init(allocator);
        try c_obj.put("score", .{ .float = score });
        try c_obj.put("name", .{ .string = criterion.name });
        try c_obj.put("points", .{ .float = pts });
        try c_obj.put("rationale", .{ .string = criterion.rationale });
        try c_obj.put("metaData", .{ .object = c_meta });
        try criteria_arr.append(.{ .object = c_obj });
    }
    try obj.put("criteria", .{ .array = criteria_arr });

    // considerations: filter by settings.isTurnedOn, exclude aiCheck
    var cons_arr = std.json.Array.init(allocator);
    const cons_items = [_]struct { item: dynamo.GradeItem, is_on: bool }{
        .{ .item = submission.considerations.listRecommendations, .is_on = assignment.settings.listRecommendations.isTurnedOn },
        .{ .item = submission.considerations.factCheck, .is_on = assignment.settings.factCheck.isTurnedOn },
        .{ .item = submission.considerations.relevanceCheck, .is_on = assignment.settings.relevanceCheck.isTurnedOn },
        .{ .item = submission.considerations.evaluateLogic, .is_on = assignment.settings.evaluateLogic.isTurnedOn },
        .{ .item = submission.considerations.citationsCheck, .is_on = assignment.settings.citationsCheck.isTurnedOn },
    };
    for (cons_items) |ci| {
        if (!ci.is_on) continue;
        try cons_arr.append(try gradeItemToValue(allocator, ci.item));
    }
    try obj.put("considerations", .{ .array = cons_arr });

    const report_json = try std.json.Stringify.valueAlloc(
        allocator,
        std.json.Value{ .object = obj },
        .{ .emit_null_optional_fields = false },
    );
    try dynamo.saveItem(allocator, report_json, owner);
}

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

    // Fetch existing to detect status transition
    const pk_stem = stringStem(parsed.pk);
    const sk_stem = stringStem(parsed.sk);
    const existing = try dynamo.getItemPkSk(dynamo.Submission, c.allocator, "SUBMISSION", pk_stem, sk_stem);
    const was_approved = if (existing) |ex| std.mem.eql(u8, ex.status, "approved") else false;

    parsed.status = "approved";
    parsed.updatedAt = utils.stampUTC(c.allocator) catch parsed.updatedAt;
    server.debugPrint("approved\n", .{});
    dynamo.saveObj(c.allocator, parsed, parsed.OWNER) catch {
        try c.request.respond("{\"error\":\"Internal Server Error\"}", .{ .status = .internal_server_error, .extra_headers = headers });
        return;
    };
    _ = was_approved;
    // Create/update report on approval transition
    // Fetch assignment: pk=classId, sk=assignmentId (which is the stem of submission.pk)
    const assignment_sk = parsed.assignmentId; // already a stem
    if (try dynamo.getItemPkSk(schema.Assignment, c.allocator, "ASSIGNMENT", parsed.classId, assignment_sk)) |assignment| {
        // Fetch class for its name
        const class_name = blk: {
            if (try dynamo.getItemPkSk(ClassBasic, c.allocator, "CLASS", user.email, parsed.classId)) |cls| {
                break :blk cls.name;
            }
            break :blk @as([]const u8, "none");
        };
        createAndSaveReport(c.allocator, user.email, parsed, assignment, class_name) catch |err| {
            std.debug.print("createAndSaveReport failed: {}\n", .{err});
        };
    } else {
        std.debug.print("approveSubmission: assignment not found for classId={s} assignmentId={s}\n", .{ parsed.classId, assignment_sk });
    }

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
