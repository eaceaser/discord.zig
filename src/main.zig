const std = @import("std");
const discord = @import("./discord.zig");

pub const std_options = std.Options{
    .log_level = .debug,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const token = try std.process.getEnvVarOwned(allocator, "TEST_DISCORD_TOKEN");
    defer allocator.free(token);
    var client = try discord.Discord.init(allocator, .{
        .token = token,
    });
    defer client.deinit();
    try client.run();
}
