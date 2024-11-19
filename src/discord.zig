const std = @import("std");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.discord);
const discordApiRoot = "https://discord.com/api/v10";

pub const Discord = struct {
    allocator: Allocator,
    token: []const u8,
    client: std.http.Client,

    pub const Opts = struct {
        token: []const u8,
    };

    pub fn init(allocator: Allocator, opts: Opts) !Discord {
        const client = std.http.Client{
            .allocator = allocator,
        };

        return .{ .allocator = allocator, .token = opts.token, .client = client };
    }

    pub fn deinit(self: *Discord) void {
        self.client.deinit();
    }

    pub fn run(self: *Discord) !void {
        const thread = try std.Thread.spawn(.{}, loop, .{self});
        thread.join();
    }

    // pub fn stop(self: *Discord) void {}

    fn loop(self: *Discord) !void {
        var authHeader = std.ArrayList(u8).init(self.allocator);
        defer authHeader.deinit();
        try authHeader.writer().print("Bot {s}", .{self.token});

        log.debug("in client thread", .{});

        var body = std.ArrayList(u8).init(self.allocator);
        defer body.deinit();

        const resp = try self.client.fetch(.{ .method = .GET, .location = .{ .url = discordApiRoot ++ "/gateway" }, .headers = .{
            .authorization = .{ .override = authHeader.items },
        }, .response_storage = .{
            .dynamic = &body,
        } });

        log.debug("got response {x} {s}", .{ resp.status, body.items });
    }
};
