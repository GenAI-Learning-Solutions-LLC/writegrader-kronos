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



pub fn getAllSubmissions(c: *Context) !void {
    const user = try dynamo.getUser(c);

    const cached = sql.getAll(c.allocator, "SELECT data FROM fetch_cache WHERE data_type = 'submissions' AND name = ? AND updated_at > datetime('now', '-3 minutes') LIMIT 1", .{user.email}) catch null;
    if (cached) |rows| {
        if (rows.len > 0) {
            const data = rows[0][9 .. rows[0].len - 2];
            try c.request.respond(data, .{ .extra_headers = headers });
            return;
        }
    }

    const all = try dynamo.getItemsOwnerDtProjRaw(c.allocator, user.email, "SUBMISSION",
        "pk, sk, severity, DATATYPE, #n, studentName, assignmentId, rubricId, simpleHash, classId, #owner, isStarred, #s, externalId",
        "\"#n\":\"name\",\"#s\":\"status\"");

    var total_len: usize = 2; // [ and ]
    for (all) |item| {
        if (!std.mem.containsAtLeast(u8, item, 1, "BACKUP")) total_len += item.len + 1; // +1 for comma
    }
    const json_body = try c.allocator.alloc(u8, total_len);
    var pos: usize = 0;
    json_body[pos] = '['; pos += 1;
    var first = true;
    for (all) |item| {
        if (std.mem.containsAtLeast(u8, item, 1, "BACKUP")) continue;
        if (!first) { json_body[pos] = ','; pos += 1; }
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

pub fn saveSubmission(c: *Context) !void {
    const user = try dynamo.getUser(c);

    const content_length = c.request.head.content_length orelse {
        try c.request.respond("", .{ .status = .bad_request });
        return;
    };

    const read_buf = try c.allocator.alloc(u8, 4096);
    const reader = try c.request.readerExpectContinue(read_buf);
    const body = try reader.readAlloc(c.allocator, content_length);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, c.allocator, body, .{ .allocate = .alloc_always });

    switch (parsed) {
        .object => |*obj| {
            var ts_buf: [32]u8 = undefined;
            dynamo.c.iso_timestamp(&ts_buf, ts_buf.len);
            const ts = try c.allocator.dupe(u8, std.mem.sliceTo(&ts_buf, 0));
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
        },
        else => {},
    }

    const modified_body = try std.json.Stringify.valueAlloc(c.allocator, parsed, .{});

    dynamo.saveItem(c.allocator, modified_body, user.email) catch {
        try c.request.respond("", .{ .status = .forbidden });
        return;
    };

    invalidateSubmissionCache(user.email);
    try server.sendJson(c.allocator, c.request, .{ .message = "success" }, .{ .extra_headers = headers });
}
