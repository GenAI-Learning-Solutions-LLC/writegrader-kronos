const std = @import("std");

const server = @import("../server.zig");
const Context = server.Context;
const dynamo = @import("../dynamo.zig");

const headers = &[_]std.http.Header{
    .{ .name = "Content-Type", .value = "application/json" },
    .{ .name = "Connection", .value = "close" },
    .{ .name = "Access-Control-Allow-Origin", .value = "http://localhost:5173" },
    .{ .name = "Access-Control-Allow-Credentials", .value = "true" },
};

const GradeBodyPartial = struct {
    revisionModel: ?[]const u8 = null,
};

pub fn grade(c: *Context) !void {
    const user = try dynamo.getUser(c);
    _ = user;

    const content_length = c.request.head.content_length orelse {
        try c.request.respond("", .{ .status = .bad_request });
        return;
    };

    const read_buf = try c.allocator.alloc(u8, 4096);
    const reader = try c.request.readerExpectContinue(read_buf);
    const body = try reader.readAlloc(c.allocator, content_length);

    const partial = try std.json.parseFromSliceLeaky(GradeBodyPartial, c.allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });

    const rev_model = if (partial.revisionModel) |rm|
        try std.fmt.allocPrint(c.allocator, "\"{s}\"", .{rm})
    else
        "null";

    const use_claude = if (dynamo.c.getenv("FORCE_CLAUDE") != null) "true" else "false";
    const user_json = c.get("user") orelse "{}";

    const payload = try std.fmt.allocPrint(c.allocator,
        \\{{"action":"gradeSubmission","pr":true,"req":{{"pr":true,"body":{s},"user":{s},"query":{{}},"params":{{}},"useClaude":{s}}},"revisionModel":{s}}}
    , .{ body, user_json, use_claude, rev_model });

    const cpayload = try std.heap.c_allocator.dupeZ(u8, payload);
    defer std.heap.c_allocator.free(cpayload);

    const rc = if (dynamo.c.getenv("LOCAL_PARSER") != null) blk: {
        break :blk dynamo.c.http_post("http://localhost:3002", cpayload);
    } else blk: {
        const fn_env = dynamo.c.getenv("PARSER");
        const cname: [*c]const u8 = if (fn_env != null) fn_env else "ai-parser-AiParserLambda8BD704BF-vi2FDv4rLltq";
        break :blk dynamo.c.invoke_lambda(cname, cpayload);
    };

    if (rc != 0) {
        try c.request.respond("", .{ .status = .internal_server_error });
        return;
    }

    try server.sendJson(c.allocator, c.request, .{ .message = "success" }, .{ .extra_headers = headers });
}



const GradeCritBodyPartial = struct {
    revisionModel: ?[]const u8 = null,
    criterion: []const u8,
};
pub fn gradeCriterion(c: *Context) !void {
    const user = try dynamo.getUser(c);
    _ = user;

    const content_length = c.request.head.content_length orelse {
        try c.request.respond("", .{ .status = .bad_request });
        return;
    };

    const read_buf = try c.allocator.alloc(u8, 4096);
    const reader = try c.request.readerExpectContinue(read_buf);
    const body = try reader.readAlloc(c.allocator, content_length);

    const partial = try std.json.parseFromSliceLeaky(GradeCritBodyPartial, c.allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });

    const rev_model = if (partial.revisionModel) |rm|
        try std.fmt.allocPrint(c.allocator, "\"{s}\"", .{rm})
    else
        "null";

    const use_claude = if (dynamo.c.getenv("FORCE_CLAUDE") != null) "true" else "false";
    const user_json = c.get("user") orelse "{}";

    const payload = try std.fmt.allocPrint(c.allocator,
        \\{{"action":"gradeCriterion","pr":true,"req":{{"criterion":"{s}", "pr":true,"body":{s},"user":{s},"query":{{}},"params":{{}},"useClaude":{s}}},"revisionModel":{s}}}
    , .{ partial.criterion,body, user_json, use_claude, rev_model });

    const cpayload = try std.heap.c_allocator.dupeZ(u8, payload);
    defer std.heap.c_allocator.free(cpayload);

    const rc = if (dynamo.c.getenv("LOCAL_PARSER") != null) blk: {
        break :blk dynamo.c.http_post("http://localhost:3002", cpayload);
    } else blk: {
        const fn_env = dynamo.c.getenv("PARSER");
        const cname: [*c]const u8 = if (fn_env != null) fn_env else "ai-parser-AiParserLambda8BD704BF-vi2FDv4rLltq";
        break :blk dynamo.c.invoke_lambda(cname, cpayload);
    };

    if (rc != 0) {
        try c.request.respond("", .{ .status = .internal_server_error });
        return;
    }

    try server.sendJson(c.allocator, c.request, rc, .{ .extra_headers = headers });
}



