const std = @import("std");

const server = @import("../server.zig");
const Context = server.Context;
const dynamo = @import("../dynamo.zig");
const sub_routes = @import("submission_routes.zig");
const tasks = @import("../tasks.zig");
const sql = @import("../sql.zig");

const GradeBodyPartial = struct {
    revisionModel: ?[]const u8 = null,
    sk: []const u8,
};

pub fn grade(c: *Context) !void {
    const user = try dynamo.getUser(c);
    const headers = try server.makeHeaders(c.allocator, c.request);

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
    const current_task = sql.getOne(
        c.allocator,
        "SELECT status, json_extract(json_extract(meta_data, '$.body'), '$.sk') as sk, json_extract(json_extract(meta_data, '$.body'), '$.pk') as pk, step, 5 steps FROM task_queue WHERE user_email = ? AND task = 'grade_submission' AND is_complete = 0 AND json_extract(json_extract(meta_data, '$.body'), '$.sk') = ? AND updated_at >= datetime('now', '-1 minutes', 'utc')",
        .{ user.email, partial.sk },
    ) catch null;
    if (current_task != null) {
        std.log.info("debouncing grade attempts\n", .{});
        try server.sendJson(c.allocator, c.request, .{ .message = "success" }, .{ .extra_headers = headers });
        return;
    }
     const token = tasks.createTask(c.allocator, "grade_submission", user.email, .{.body = body}) catch |err| {
        std.log.err("user-{s} err-{any}\n", .{user.email, err});
        try c.request.respond("", .{ .status = .internal_server_error, .extra_headers = headers });
        return;
    };

    const rev_model = if (partial.revisionModel) |rm|
        try std.fmt.allocPrint(c.allocator, "\"{s}\"", .{rm})
    else
        "null";

    const use_claude = if (dynamo.c.getenv("FORCE_CLAUDE") != null) "true" else "false";
    const user_json = c.get("user") orelse "{}";
    const task_endpoint = dynamo.c.getenv("OWN_URL");
    const payload = try std.fmt.allocPrint(c.allocator,
        \\{{"action":"gradeSubmission","pr":true,"req":{{"pr":true,"body":{s},"user":{s},"query":{{}},"params":{{}},"useClaude":{s}}},"revisionModel":{s},"taskToken":"{s}","callback":"{s}/tasks/update"}}
    , .{ body, user_json, use_claude, rev_model, token, task_endpoint });

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

    sub_routes.invalidateSubmissionCache(user.email);
    try server.sendJson(c.allocator, c.request, .{ .message = "success" }, .{ .extra_headers = headers });
}



const GradeCritBodyPartial = struct {
    revisionModel: ?[]const u8 = null,
    instructions: ?[]const u8 = null,

    criterion: []const u8,
};
pub fn gradeCriterion(c: *Context) !void {
    const user = try dynamo.getUser(c);
    const headers = try server.makeHeaders(c.allocator, c.request);

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

    const criterion_json = try std.json.Stringify.valueAlloc(c.allocator, partial.criterion, .{});
    const instructions_json = try std.json.Stringify.valueAlloc(c.allocator, partial.instructions, .{});
    const token = tasks.createTask(c.allocator, "grade_criterion", user.email, .{.criterion = partial.criterion, .instructions = partial.instructions}) catch |err| {
        std.debug.print("{any}\n", .{err});
        try c.request.respond("", .{ .status = .internal_server_error, .extra_headers = headers });
        return;
    };
    const payload = try std.fmt.allocPrint(c.allocator,
        \\{{"action":"gradeCriterion","pr":true,"req":{{"criterion":{s},"instructions":{s},"pr":true,"body":{s},"user":{s},"query":{{}},"params":{{}},"useClaude":{s}}},"revisionModel":{s}}}
    , .{ criterion_json, instructions_json, body, user_json, use_claude, rev_model });
    
    
    const cpayload = try std.heap.c_allocator.dupeZ(u8, payload);
    defer std.heap.c_allocator.free(cpayload);
    const response: ?[*:0]u8 = if (dynamo.c.getenv("LOCAL_PARSER") != null) blk: {
        break :blk dynamo.c.http_post_sync("http://localhost:3002", cpayload);
    } else blk: {
        const fn_env = dynamo.c.getenv("PARSER");
        const cname: [*c]const u8 = if (fn_env != null) fn_env else "ai-parser-AiParserLambda8BD704BF-vi2FDv4rLltq";
        break :blk dynamo.c.invoke_lambda_sync(cname, cpayload);
    };

    if (response == null) {
        try c.request.respond("", .{ .status = .internal_server_error });
        try tasks.updateTask(c.allocator, token, "error", 0, false, .{.criterion = criterion_json, .instructions = instructions_json, .response = response});

        return;
    }
    try tasks.updateTask(c.allocator, token, "complete", 0, true, .{.criterion =  partial.criterion, .instructions = partial.instructions, .response = response});

    defer std.c.free(response);

    try c.request.respond(std.mem.span(response.?), .{ .extra_headers = headers });
}



pub fn gradeCriterionAsync(c: *Context) !void {
    const user = try dynamo.getUser(c);
    const headers = try server.makeHeaders(c.allocator, c.request);

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

    const criterion_json = try std.json.Stringify.valueAlloc(c.allocator, partial.criterion, .{});

    const payload = try std.fmt.allocPrint(c.allocator,
        \\{{"action":"gradeCriterion","pr":true,"req":{{"criterion":{s},"pr":true,"body":{s},"user":{s},"query":{{}},"params":{{}},"useClaude":{s}}},"revisionModel":{s}}}
    , .{ criterion_json, body, user_json, use_claude, rev_model });

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

    sub_routes.invalidateSubmissionCache(user.email);
    try server.sendJson(c.allocator, c.request, .{ .message = "success" }, .{ .extra_headers = headers });
}






