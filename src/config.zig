const std = @import("std");

pub const Config = @This();

address: []const u8,
port: u16,
workers: usize = 1,
hideDotFiles: bool = true,
useArena: bool = true,

/// Initialize the `Config` from a JSON file.
pub fn init(io: std.Io, filename: []const u8, allocator: std.mem.Allocator) !Config {
    const file = try std.Io.Dir.cwd().openFile(io, filename, .{ .mode = .read_only });
    defer file.close(io);
    const file_size = try file.length(io);
    const b: []u8 = try allocator.alloc(u8, file_size);
    defer allocator.free(b);
    var reader = file.reader(io, b);
    _ = try reader.interface.readSliceAll(b);

    var settings = try std.json.parseFromSlice(Config, allocator, b, .{});
    _ = &settings;
    defer settings.deinit(); // Free allocated JSON memory

    // Duplicate the address string so it remains valid
    const address_copy = try allocator.dupe(u8, settings.value.address);
    return Config{
        .address = address_copy,
        .port = settings.value.port,
        .workers = settings.value.workers,
    };
}

/// Deallocate dynamically allocated memory in `Config`.
pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
    allocator.free(self.address);
    self.* = undefined; // Prevent accidental use-after-free
}
