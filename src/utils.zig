const std = @import("std");
const fmt = @import("fmt.zig");
const server = @import("server.zig");
const Context = server.Context;
const Callback = server.Callback;
const dynamo = @import("dynamo.zig");
const auth = @import("auth.zig");
const sql = @import("sql.zig");

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

pub fn stampUTC(allocator: std.mem.Allocator) ![]const u8 { 

    var ts_buf: [32]u8 = undefined;
    dynamo.c.iso_timestamp(&ts_buf, ts_buf.len);
    const ts = try allocator.dupe(u8, std.mem.sliceTo(&ts_buf, 0));
    return ts;
}

const AssignmentAccess = struct {
    OWNER: []const u8,
    sharedWith: [][]const u8 = &.{},
};


pub fn checkAssignmentAccess(allocator: std.mem.Allocator, user_email: []const u8, class_id: []const u8, assignment_id: []const u8) !bool {
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



fn isItemNew(allocator: std.mem.Allocator, user_email: []const u8, cache_type:[]const u8, pk: []const u8, sk: []const u8) !bool {

    // 1. Check item cache (ignore staleness)
    const cached = sql.getAll(allocator, "SELECT data FROM fetch_cache WHERE data_type = '?' AND name = ? LIMIT 1", .{cache_type, user_email}) catch null;
    if (cached) |rows| {
        if (rows.len > 0 and rows[0].len > 11) {
            const data = rows[0][9 .. rows[0].len - 2];
            if (std.mem.containsAtLeast(u8, data, 1, sk)) {
                std.debug.print("{s} {s} found in cache, is existing\n", .{cache_type, sk});
                return false;
            }
        }
    }

    // 2. Not in cache — check DynamoDB
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
        std.debug.print("{s} {s} found in dynamo, is existing\n", .{cache_type, sk});
        return false;
    }

    std.debug.print("{s} {s} not found in cache or dynamo, is new\n", .{cache_type, sk});
    return true;
}
