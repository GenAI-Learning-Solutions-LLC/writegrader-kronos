const std = @import("std");
const config = @import("config.zig");
const server = @import("server.zig");
const fmt = @import("fmt.zig");
const builtin = @import("builtin");
const crypto = std.crypto;
const dynamo = @import("dynamo.zig");
pub var io: ? std.Io = null;
pub const AuthBody = struct {
    exp: u64,
    iat: u64,
    login: u64,
    user: []const u8,
    value: []const u8,
};

pub const execresult = struct {
    stdout: []const u8,
    stderr: []const u8,
};

const indexquery = struct {
    value: ?[]const u8,
};

/// Generates a cryptographically secure random string of `len` bytes, hex-encoded.
/// Caller owns the returned slice.
pub fn generateSecureToken(allocator: std.mem.Allocator, len: usize) ![]u8 {
    const bytes = try allocator.alloc(u8, len);
    defer allocator.free(bytes);
    io.?.random(bytes);
    const hex = try allocator.alloc(u8, len * 2);
    return try std.fmt.hexToBytes(hex, hex);
}

pub fn decodeAuth(T: type, allocator: std.mem.Allocator, cookie: []const u8, secret_key: ?[]const u8) !T {
    if (secret_key == null){
        return error.NoSecret;
    }
    const secret = secret_key.?;
    // Split JWT into parts
    var parts = std.mem.splitScalar(u8, cookie, '.');
    const header_b64 = parts.next() orelse return error.InvalidJWT;
    const payload_b64 = parts.next() orelse return error.InvalidJWT;
    const signature_b64 = parts.next() orelse return error.InvalidJWT;
    std.debug.print("{d}\n", .{45});
    // Verify signature
    const message = cookie[0..(header_b64.len + 1 + payload_b64.len)];
    
    const decoder = std.base64.url_safe_no_pad.Decoder;
    
    // Decode signature
    var sig_buf: [64]u8 = undefined;
    const sig_len = try decoder.calcSizeForSlice(signature_b64);
    try decoder.decode(sig_buf[0..sig_len], signature_b64);
    const sig_decoded = sig_buf[0..sig_len];
    
    // Calculate expected signature
    var expected_sig: [crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    crypto.auth.hmac.sha2.HmacSha256.create(&expected_sig, message, secret);
    
    if (!std.mem.eql(u8, sig_decoded, &expected_sig)) {
        return error.InvalidSignature;
    }
    
    // Decode payload
    const decoded_size = try decoder.calcSizeForSlice(payload_b64);
    const decoded = try allocator.alloc(u8, decoded_size);
    defer allocator.free(decoded);
    
    try decoder.decode(decoded, payload_b64);
    server.debugPrint("debug: {s}\n", .{decoded});
    // Parse JSON
    const parsed = try std.json.parseFromSlice(T, allocator, decoded, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    
    return parsed.value;
}
