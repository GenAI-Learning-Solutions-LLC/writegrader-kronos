const std = @import("std");


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

