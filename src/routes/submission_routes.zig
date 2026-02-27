const std = @import("std");

const fmt = @import("../fmt.zig");
const server = @import("../server.zig");
const Context = server.Context;
const Callback = server.Callback;
const dynamo = @import("../dynamo.zig");
const auth = @import("../auth.zig");
const sql = @import("../sql.zig");


/// Builds a JSON array from pre-serialised JSON object strings.
/// Returns a slice of exactly the right length — no trailing garbage bytes.
pub fn buildJsonArray(allocator: std.mem.Allocator, items: []const []const u8) ![]const u8 {
    var total_len: usize = 2; // '[' and ']'
    for (items) |item| total_len += item.len + 1; // +1 reserved for comma
    const buf = try allocator.alloc(u8, total_len);
    var pos: usize = 0;
    buf[pos] = '[';
    pos += 1;
    var first = true;
    for (items) |item| {
        if (!first) { buf[pos] = ','; pos += 1; }
        @memcpy(buf[pos..][0..item.len], item);
        pos += item.len;
        first = false;
    }
    buf[pos] = ']';
    return buf[0 .. pos + 1];
}

const SubmissionIndexParams = struct {
    cid: []const u8,
    aid: []const u8,
};

pub fn index(c: *Context) !void {
    const user = try dynamo.getUser(c);
    const headers = try server.makeHeaders(c.allocator, c.request);

    server.debugPrint("Here\n", .{});
    const params = server.Parser.params(SubmissionIndexParams, c) catch {
        try c.request.respond("<h1>nothing found</h1>", .{ .status = .ok });
        return;
    };
    server.debugPrint("Here {s}\n", .{params.aid});
    const submissions = try dynamo.getItemsOwnerPk(dynamo.Submission, c.allocator, "SUBMISSION", user.email, params.aid);

    try server.sendJson(c.allocator, c.request, submissions, .{ .extra_headers = headers });
}

pub fn getAssignmentSubmissions(c: *Context) !void {
    const user = try dynamo.getUser(c);
    const headers = try server.makeHeaders(c.allocator, c.request);

    const params = server.Parser.params(SubmissionIndexParams, c) catch {
        try c.request.respond("", .{ .status = .bad_request });
        return;
    };
    std.debug.print("stuff {s} {s}\n", .{ params.cid, params.cid });
    const has_access = checkAssignmentAccess(c.allocator, user.email, params.cid, params.aid) catch false;
    if (!has_access) {
        try c.request.respond("", .{ .status = .forbidden });
      return;
    }

    var list = try dynamo.getItemsDatatypePk(c.allocator, "SUBMISSION", params.aid);
    std.debug.print("list {d}\n", .{list.items.len});

    defer list.deinit();

    var total_len: usize = 2;
    for (list.items) |item| total_len += item.len + 1;
    const json_body = try c.allocator.alloc(u8, total_len);
    var pos: usize = 0;
    json_body[pos] = '[';
    pos += 1;
    var first = true;
    for (list.items) |item| {
        if (!first) {
            json_body[pos] = ',';
            pos += 1;
        }
        @memcpy(json_body[pos..][0..item.len], item);
        pos += item.len;
        first = false;
    }
    json_body[pos] = ']';
    std.debug.print("{s}\n", .{json_body[0 .. pos + 1]});

    try c.request.respond(json_body[0 .. pos + 1], .{ .extra_headers = headers });
}

pub fn getAllSubmissions(c: *Context) !void {
    const user = try dynamo.getUser(c);
    const headers = try server.makeHeaders(c.allocator, c.request);

    const cached = sql.getAll(c.allocator, "SELECT data FROM fetch_cache WHERE data_type = 'submissions' AND name = ? AND updated_at > datetime('now', '-3 minutes') LIMIT 1", .{user.email}) catch null;
    if (cached) |rows| {
        if (rows.len > 0) {
            const data = rows[0][9 .. rows[0].len - 2];
            try c.request.respond(data, .{ .extra_headers = headers });
            return;
        }
    }

    const all = try dynamo.getItemsOwnerDtProjRaw(c.allocator, user.email, "SUBMISSION", "pk, sk, severity, DATATYPE, #n, studentName, assignmentId, rubricId, simpleHash, classId, #owner, isStarred, #s, externalId", "\"#n\":\"name\",\"#s\":\"status\"");

    var total_len: usize = 2; // [ and ]
    for (all) |item| {
        if (!std.mem.containsAtLeast(u8, item, 1, "BACKUP")) total_len += item.len + 1; // +1 for comma
    }
    const json_body = try c.allocator.alloc(u8, total_len);
    var pos: usize = 0;
    json_body[pos] = '[';
    pos += 1;
    var first = true;
    for (all) |item| {
        if (std.mem.containsAtLeast(u8, item, 1, "BACKUP")) continue;
        if (!first) {
            json_body[pos] = ',';
            pos += 1;
        }
        @memcpy(json_body[pos..][0..item.len], item);
        pos += item.len;
        first = false;
    }
    json_body[pos] = ']';

    sql.exec("INSERT OR REPLACE INTO fetch_cache (data_type, user, name, data) VALUES ('submissions', ?, ?, ?)", .{ user.email, user.email, json_body }) catch |err| {
        std.debug.print("cache write failed: {}\n", .{err});
    };

    try c.request.respond(json_body, .{ .extra_headers = headers });
}

pub fn getUnapprovedSubmissions(c: *Context) !void {
    const user = try dynamo.getUser(c);
    const headers = try server.makeHeaders(c.allocator, c.request);

    const cached = sql.getAll(c.allocator, "SELECT data FROM fetch_cache WHERE data_type = 'submissions_unapproved' AND name = ? AND updated_at > datetime('now', '-3 minutes') LIMIT 1", .{user.email}) catch null;
    if (cached) |rows| {
        if (rows.len > 0) {
            const data = rows[0][9 .. rows[0].len - 2];
            try c.request.respond(data, .{ .extra_headers = headers });
            return;
        }
    }

    const all = try dynamo.getItemsOwnerDt(dynamo.Submission, c.allocator, user.email, "SUBMISSION");
    var count: usize = 0;
    for (all) |s| {
        if (!std.mem.eql(u8, s.status, "graded") and !std.mem.containsAtLeast(u8, s.sk, 1, "BACKUP")) count += 1;
    }
    const unapproved = try c.allocator.alloc(dynamo.Submission, count);
    var i: usize = 0;
    for (all) |s| {
        if (!std.mem.eql(u8, s.status, "graded") and !std.mem.containsAtLeast(u8, s.sk, 1, "BACKUP")) {
            unapproved[i] = s;
            i += 1;
        }
    }
    const json_body = try std.json.Stringify.valueAlloc(c.allocator, unapproved, .{});

    sql.exec("INSERT OR REPLACE INTO fetch_cache (data_type, user, name, data) VALUES ('submissions_unapproved', ?, ?, ?)", .{ user.email, user.email, json_body }) catch |err| {
        std.debug.print("cache write failed: {}\n", .{err});
    };

    try c.request.respond(json_body, .{ .extra_headers = headers });
}

//todo check ownership using shared access
const SubmissionParams = struct {
    cid: []const u8,
    aid: []const u8,
    sid: []const u8,
};

pub fn get_submission(c: *Context) !void {
    const user = try dynamo.getUser(c);
    const headers = try server.makeHeaders(c.allocator, c.request);
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

pub fn invalidateSubmissionCache(user_email: []const u8) void {
    sql.exec("DELETE FROM fetch_cache WHERE data_type IN ('submissions', 'submissions_unapproved') AND user = ?", .{user_email}) catch |err| {
        std.debug.print("cache invalidate failed: {}\n", .{err});
    };
}

const AssignmentAccess = struct {
    OWNER: []const u8,
    sharedWith: [][]const u8 = &.{},
};

fn checkAssignmentAccess(allocator: std.mem.Allocator, user_email: []const u8, class_id: []const u8, assignment_id: []const u8) !bool {
    if (class_id.len == 0 or assignment_id.len == 0) return false;

    const cache_key = try std.fmt.allocPrint(allocator, "{s}#{s}", .{ class_id, assignment_id });

    const cached = sql.getAll(allocator, "SELECT data FROM fetch_cache WHERE data_type = 'assignment' AND name = ? AND updated_at > datetime('now', '-5 minutes') LIMIT 1", .{cache_key}) catch null;
    if (cached) |rows| {
        if (rows.len > 0) {
            const data = rows[0][9 .. rows[0].len - 2];
            const assignment = std.json.parseFromSliceLeaky(AssignmentAccess, allocator, data, .{ .ignore_unknown_fields = true }) catch return false;
            if (std.mem.eql(u8, user_email, assignment.OWNER)) return true;
            for (assignment.sharedWith) |sw| {
                if (std.mem.eql(u8, user_email, sw)) return true;
            }
            return false;
        }
    }

    const cpx = try std.heap.c_allocator.dupeZ(u8, "ASSIGNMENT");
    defer std.heap.c_allocator.free(cpx);
    const cpk = try std.heap.c_allocator.dupeZ(u8, class_id);
    defer std.heap.c_allocator.free(cpk);
    const csk = try std.heap.c_allocator.dupeZ(u8, assignment_id);
    defer std.heap.c_allocator.free(csk);

    const result = dynamo.c.get_item_pk_sk(cpx, cpk, csk);
    if (result == null) return false;
    defer std.c.free(result);
    const slice = std.mem.span(result);

    sql.exec("INSERT OR REPLACE INTO fetch_cache (data_type, user, name, data) VALUES ('assignment', ?, ?, ?)", .{ cache_key, cache_key, slice }) catch |err| {
        std.debug.print("assignment cache write failed: {}\n", .{err});
    };

    const assignment = std.json.parseFromSliceLeaky(AssignmentAccess, allocator, slice, .{ .ignore_unknown_fields = true }) catch return false;
    if (std.mem.eql(u8, user_email, assignment.OWNER)) return true;
    for (assignment.sharedWith) |sw| {
        if (std.mem.eql(u8, user_email, sw)) return true;
    }
    return false;
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

fn isSubmissionNew(allocator: std.mem.Allocator, user_email: []const u8, pk_str: ?[]const u8, sk_str: ?[]const u8) !bool {
    const sk = sk_str orelse return true;

    // 1. Check submissions cache (ignore staleness)
    const cached = sql.getAll(allocator,
        "SELECT data FROM fetch_cache WHERE data_type = 'submissions' AND name = ? LIMIT 1",
        .{user_email}) catch null;
    if (cached) |rows| {
        if (rows.len > 0 and rows[0].len > 11) {
            const data = rows[0][9 .. rows[0].len - 2];
            if (std.mem.containsAtLeast(u8, data, 1, sk)) {
                std.debug.print("submission {s} found in cache, is existing\n", .{sk});
                return false;
            }
        }
    }

    // 2. Not in cache — check DynamoDB
    const pk = pk_str orelse return true;
    const pk_stem = if (std.mem.indexOf(u8, pk, "#")) |idx| pk[idx + 1 ..] else pk;
    const sk_stem = if (std.mem.indexOf(u8, sk, "#")) |idx| sk[idx + 1 ..] else sk;
    const cpx = try std.heap.c_allocator.dupeZ(u8, "SUBMISSION");
    defer std.heap.c_allocator.free(cpx);
    const cpk = try std.heap.c_allocator.dupeZ(u8, pk_stem);
    defer std.heap.c_allocator.free(cpk);
    const csk = try std.heap.c_allocator.dupeZ(u8, sk_stem);
    defer std.heap.c_allocator.free(csk);
    const result = dynamo.c.get_item_pk_sk(cpx, cpk, csk);
    if (result != null) {
        std.c.free(result);
        std.debug.print("submission {s} found in dynamo, is existing\n", .{sk});
        return false;
    }

    std.debug.print("submission {s} not found in cache or dynamo, is new\n", .{sk});
    return true;
}

fn hasAvailableCredits(user: dynamo.User) bool {
    const sub = user.subscriptionInfo;
    const available = (sub.credits orelse 0) - sub.creditsUsed + (sub.bonus orelse 0);
    std.debug.print("credit check: credits={d} creditsUsed={d} bonus={d} available={d}\n", .{
        sub.credits orelse 0, sub.creditsUsed, sub.bonus orelse 0, available,
    });
    return available > 0;
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

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, c.allocator, body, .{ .allocate = .alloc_always });
    const obj = switch (parsed) {
        .object => |*o| o,
        else => {
            try c.request.respond("", .{ .status = .bad_request });
            return;
        },
    };

    try stampAndNormalise(c.allocator, obj);

    const class_id = if (obj.get("classId")) |v| switch (v) { .string => |s| s, else => "" } else "";
    const assignment_id = if (obj.get("assignmentId")) |v| switch (v) { .string => |s| s, else => "" } else "";
    const has_access = checkAssignmentAccess(c.allocator, user.email, class_id, assignment_id) catch false;
    if (!has_access) {
        try c.request.respond("", .{ .status = .forbidden });
        return;
    }

    const pk_str: ?[]const u8 = if (obj.get("pk")) |v| switch (v) { .string => |s| s, else => null } else null;
    const sk_str: ?[]const u8 = if (obj.get("sk")) |v| switch (v) { .string => |s| s, else => null } else null;
    const is_new = try isSubmissionNew(c.allocator, user.email, pk_str, sk_str);

    if (is_new and (if (user.group) |g| g.len == 0 else true) and !user.isAdmin) {
        if (!hasAvailableCredits(user)) {
            try c.request.respond("{\"error\":\"Upload credits are below 0\"}", .{ .status = .forbidden, .extra_headers = headers });
            return;
        }
    }

    const modified_body = try std.json.Stringify.valueAlloc(c.allocator, parsed, .{});
    dynamo.saveItem(c.allocator, modified_body, null) catch {
        try c.request.respond("", .{ .status = .internal_server_error });
        return;
    };

    if (is_new) {
        std.debug.print("new submission for {s}, calling updateCreditsUsed\n", .{user.email});
        dynamo.updateCreditsUsed(c.allocator, user.email) catch |err| {
            std.debug.print("updateCreditsUsed failed: {}\n", .{err});
        };
    }

    invalidateSubmissionCache(user.email);
    try server.sendJson(c.allocator, c.request, .{ .message = "success" }, .{ .extra_headers = headers });
}


pub fn saveSubmission(c: *Context) !void {
    const user = try dynamo.getUser(c);
    const headers = try server.makeHeaders(c.allocator, c.request);

    const content_length = c.request.head.content_length orelse {
        try c.request.respond("", .{ .status = .bad_request });
        return;
    };
    const read_buf = try c.allocator.alloc(u8, 4096);
    const reader = try c.request.readerExpectContinue(read_buf);
    const body = try reader.readAlloc(c.allocator, content_length);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, c.allocator, body, .{ .allocate = .alloc_always });
    const obj = switch (parsed) {
        .object => |*o| o,
        else => {
            try c.request.respond("", .{ .status = .bad_request });
            return;
        },
    };

    try stampAndNormalise(c.allocator, obj);

    const class_id = if (obj.get("classId")) |v| switch (v) { .string => |s| s, else => "" } else "";
    const assignment_id = if (obj.get("assignmentId")) |v| switch (v) { .string => |s| s, else => "" } else "";
    const has_access = checkAssignmentAccess(c.allocator, user.email, class_id, assignment_id) catch false;
    if (!has_access) {
        try c.request.respond("", .{ .status = .forbidden });
        return;
    }

    const pk_str: ?[]const u8 = if (obj.get("pk")) |v| switch (v) { .string => |s| s, else => null } else null;
    const sk_str: ?[]const u8 = if (obj.get("sk")) |v| switch (v) { .string => |s| s, else => null } else null;
    const is_new = try isSubmissionNew(c.allocator, user.email, pk_str, sk_str);

    if (is_new and (if (user.group) |g| g.len == 0 else true) and !user.isAdmin) {
        if (!hasAvailableCredits(user)) {
            try c.request.respond("{\"error\":\"Upload credits are below 0\"}", .{ .status = .forbidden, .extra_headers = headers });
            return;
        }
    }

    const modified_body = try std.json.Stringify.valueAlloc(c.allocator, parsed, .{});
    dynamo.saveItem(c.allocator, modified_body, null) catch {
        try c.request.respond("", .{ .status = .internal_server_error });
        return;
    };

    if (is_new) {
        std.debug.print("new submission for {s}, calling updateCreditsUsed\n", .{user.email});
        dynamo.updateCreditsUsed(c.allocator, user.email) catch |err| {
            std.debug.print("updateCreditsUsed failed: {}\n", .{err});
        };
    }

    invalidateSubmissionCache(user.email);
    try server.sendJson(c.allocator, c.request, .{ .message = "success" }, .{ .extra_headers = headers });
}
