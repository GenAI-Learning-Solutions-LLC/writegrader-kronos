const std = @import("std");
const server = @import("server.zig");
const Context = server.Context;

pub const c = @cImport({
    @cInclude("dynamo.h");
    @cInclude("stdlib.h");
});


const dynamo = @cImport({
    @cInclude("dynamo.h");
});

pub const ItemList = struct {
    items: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ItemList) void {
        for (self.items) |item| self.allocator.free(item);
        self.allocator.free(self.items);
    }
};

pub fn getItemPkSk(comptime T: type, allocator: std.mem.Allocator, prefix: []const u8, pk: []const u8, sk: []const u8) !?T {
    const cpx = try allocator.dupeZ(u8, prefix);
    defer allocator.free(cpx);
    const cpk = try allocator.dupeZ(u8, pk);
    defer allocator.free(cpk);
    const csk = try allocator.dupeZ(u8, sk);
    defer allocator.free(csk);
    const result = dynamo.get_item_pk_sk(cpx, cpk, csk) orelse return null;
    defer std.c.free(result);
    return try std.json.parseFromSliceLeaky(T, allocator, std.mem.span(result), .{
        .ignore_unknown_fields = true,
    });
}

pub fn deleteItemPkSk(allocator: std.mem.Allocator, prefix: []const u8, pk: []const u8, sk: []const u8, owner: ?[]const u8) !void {
    const cpx = try allocator.dupeZ(u8, prefix);
    defer allocator.free(cpx);
    const cpk = try allocator.dupeZ(u8, pk);
    defer allocator.free(cpk);
    const csk = try allocator.dupeZ(u8, sk);
    defer allocator.free(csk);
    const cow = if (owner) |o| blk: {
        const z = try allocator.dupeZ(u8, o);
        break :blk z;
    } else null;
    defer if (cow) |z| allocator.free(z);
    const rc = dynamo.delete_item_pk_sk(cpx, cpk, csk, cow);
    if (rc != 0) return error.DynamoError;
}

pub fn deleteItemsPk(allocator: std.mem.Allocator, prefix: []const u8, pk: []const u8, owner: ?[]const u8) !usize {
    const cpx = try allocator.dupeZ(u8, prefix);
    defer allocator.free(cpx);
    const cpk = try allocator.dupeZ(u8, pk);
    defer allocator.free(cpk);
    const cow = if (owner) |o| blk: {
        const z = try allocator.dupeZ(u8, o);
        break :blk z;
    } else null;
    defer if (cow) |z| allocator.free(z);
    const n = dynamo.delete_items_pk(cpx, cpk, cow);
    if (n < 0) return error.DynamoError;
    return @intCast(n);
}

fn dupeItemList(allocator: std.mem.Allocator, raw: dynamo.ItemList) !ItemList {
    const items = try allocator.alloc([]const u8, raw.count);
    for (0..raw.count) |i| {
        items[i] = try allocator.dupe(u8, std.mem.span(raw.items[i]));
    }
    return .{ .items = items, .allocator = allocator };
}

pub fn getItemsOwnerDt(allocator: std.mem.Allocator, user_id: []const u8, datatype: []const u8) !ItemList {
    const cuid = try allocator.dupeZ(u8, user_id);
    defer allocator.free(cuid);
    const cdt = try allocator.dupeZ(u8, datatype);
    defer allocator.free(cdt);
    var raw = dynamo.get_items_owner_dt(cuid, cdt);
    defer dynamo.item_list_free(&raw);
    return dupeItemList(allocator, raw);
}

pub fn getItemsDatatypePk(allocator: std.mem.Allocator, datatype: []const u8, pk: []const u8) !ItemList {
    const cdt = try allocator.dupeZ(u8, datatype);
    defer allocator.free(cdt);
    const cpk = try allocator.dupeZ(u8, pk);
    defer allocator.free(cpk);
    var raw = dynamo.get_items_datatype_pk(cdt, cpk);
    defer dynamo.item_list_free(&raw);
    return dupeItemList(allocator, raw);
}

pub fn getItemsOwnerPk(comptime T: type, allocator: std.mem.Allocator, prefix: []const u8, user_id: []const u8, aid: []const u8) ![]T {
    const cpx = try allocator.dupeZ(u8, prefix);
    defer allocator.free(cpx);
    const cuid = try allocator.dupeZ(u8, user_id);
    defer allocator.free(cuid);
    const caid = try allocator.dupeZ(u8, aid);
    defer allocator.free(caid);
    var raw = dynamo.get_items_owner_pk(cpx, cuid, caid);
    defer dynamo.item_list_free(&raw);
    const result = try allocator.alloc(T, raw.count);
    server.debugPrint("result count {d} \n", .{result.len});
    for (0..raw.count) |i| {
        result[i] = try std.json.parseFromSliceLeaky(T, allocator, std.mem.span(raw.items[i]), .{ .ignore_unknown_fields = true });
    }
    return result;
}

pub fn saveItem(allocator: std.mem.Allocator, item_json: []const u8, owner: ?[]const u8) !void {
    const cjson = try allocator.dupeZ(u8, item_json);
    defer allocator.free(cjson);
    const cow = if (owner) |o| blk: {
        const z = try allocator.dupeZ(u8, o);
        break :blk z;
    } else null;
    defer if (cow) |z| allocator.free(z);
    const rc = dynamo.save_item(cjson, cow);
    if (rc != 0) return error.DynamoError;
}
pub const SubscriptionInfo = struct {
    cancelAt: ?f64 = null,
    credits: ?f64 = 10,
    approvals: ?f64 = 0,
    creditsUsed: f64 = 0,
    totalUsed: f64 = 0,
    endDate: ?[]const u8 = null,
    plan: []const u8 = "starter",
    premium: bool = false,
    refreshDate: ?[]const u8 = null,
    startDate: ?[]const u8 = null,
    status: []const u8,
    stripeCid: []const u8,
    stripePid: []const u8,
};

pub fn getUser(ctx: *Context) !User {
    const slice = ctx.get("user") orelse {
        try ctx.request.respond("", .{ .status = .forbidden, .keep_alive = false });
        return error.Unauthorized;
    };
    const parsed = try std.json.parseFromSlice(User, ctx.allocator, slice, .{
        .ignore_unknown_fields = true,
    });
    return parsed.value;
}

pub const User = struct {
    pk: []const u8,
    sk: []const u8,
    DATATYPE: []const u8 = "USER",
    email: []const u8,
    group: ?[]const u8 = null,
    isAdmin: bool = false,
    groupAdmin: bool = false,
    metaData: ?std.json.Value = null,
    name: []const u8,
    OWNER: []const u8 = "USER",
    settings: ?std.json.Value = null,
    subscriptionInfo: SubscriptionInfo,
    createdAt: ?[]const u8 = null,
    updatedAt: ?[]const u8 = null,
};

pub const GradeItem = struct {
    metaData: ?std.json.Value = null,
    rationale: []const u8 = "",
    name: []const u8 = "",
    score: f64 = 0,
    points: ?f64 = 0,
};

pub const Considerations = struct {
    listRecommendations: GradeItem = .{},
    aiCheck: GradeItem = .{},
    factCheck: GradeItem = .{},
    relevanceCheck: GradeItem = .{},
    evaluateLogic: GradeItem = .{},
    citationsCheck: GradeItem = .{},
};

pub const Submission = struct {
    pk: []const u8,
    sk: []const u8,
    severity: f64 = 0,
    DATATYPE: []const u8 = "SUBMISSION",
    name: []const u8,
    studentName: []const u8,
    assignmentId: []const u8,
    rubricId: []const u8,
    simpleHash: []const u8,
    classId: []const u8,
    OWNER: []const u8,
    text: []const u8,
    isStarred: bool = false,
    status: []const u8,
    externalId: []const u8,
    overallFeedback: GradeItem = .{},
    wordCount: ?f64 = null,
    shareableLink: []const u8,
    considerations: Considerations = .{},
    criteria: []GradeItem = &.{},
    modelUsed: []const u8,
    teachersComments: ?GradeItem = null,
    rawTextS3Link: []const u8,
    createdAt: ?[]const u8 = null,
    updatedAt: ?[]const u8 = null,
};
