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

pub fn getItemPkSk(allocator: std.mem.Allocator, prefix: [*:0]const u8, pk: [*:0]const u8, sk: [*:0]const u8) !?[]const u8 {
    const result = dynamo.get_item_pk_sk(prefix, pk, sk) orelse return null;
    defer std.c.free(result);
    return try allocator.dupe(u8, std.mem.span(result));
}

pub fn deleteItemPkSk(prefix: [*:0]const u8, pk: [*:0]const u8, sk: [*:0]const u8, owner: ?[*:0]const u8) !void {
    const rc = dynamo.delete_item_pk_sk(prefix, pk, sk, owner orelse null);
    if (rc != 0) return error.DynamoError;
}

pub fn deleteItemsPk(prefix: [*:0]const u8, pk: [*:0]const u8, owner: ?[*:0]const u8) !usize {
    const n = dynamo.delete_items_pk(prefix, pk, owner orelse null);
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

pub fn getItemsOwnerDt(allocator: std.mem.Allocator, user_id: [*:0]const u8, datatype: [*:0]const u8) !ItemList {
    var raw = dynamo.get_items_owner_dt(user_id, datatype);
    defer dynamo.item_list_free(&raw);
    return dupeItemList(allocator, raw);
}

pub fn getItemsDatatypePk(allocator: std.mem.Allocator, datatype: [*:0]const u8, pk: [*:0]const u8) !ItemList {
    var raw = dynamo.get_items_datatype_pk(datatype, pk);
    defer dynamo.item_list_free(&raw);
    return dupeItemList(allocator, raw);
}

pub fn getItemsOwnerPk(allocator: std.mem.Allocator, prefix: [*:0]const u8, user_id: [*:0]const u8, aid: [*:0]const u8) !ItemList {
    var raw = dynamo.get_items_owner_pk(prefix, user_id, aid);
    defer dynamo.item_list_free(&raw);
    return dupeItemList(allocator, raw);
}

pub fn saveItem(item_json: [*:0]const u8, owner: ?[*:0]const u8) !void {
    const rc = dynamo.save_item(item_json, owner orelse null);
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
