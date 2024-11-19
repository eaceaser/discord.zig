const std = @import("std");
const ws = @import("websocket");

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
        if (resp.status != std.http.Status.ok) {
            unreachable;
        }

        const parsed = try std.json.parseFromSlice(struct {
            url: []const u8,
        }, self.allocator, body.items, .{});
        defer parsed.deinit();

        const url = parsed.value.url;
        const uri = try std.Uri.parse(url);

        log.debug("parsed gateway url: {s}", .{url});
        const tls = std.mem.eql(u8, uri.scheme, "wss");
        // if tls, use default wss port, otherwise use default ws port
        // const port = if (tls) 443 else 80;
        var client = try ws.Client.init(self.allocator, .{
            .host = uri.host.?.percent_encoded,
            .port = 443,
            .tls = tls,
        });
        defer client.deinit();

        var wsHeaders = std.ArrayList(u8).init(self.allocator);
        defer wsHeaders.deinit();
        try wsHeaders.writer().print("Host: {s}", .{uri.host.?.percent_encoded});

        try client.handshake("/", .{ .headers = wsHeaders.items });
        log.debug("connected!", .{});

        const msg = try client.read();
        log.debug("got a message? {s}", .{msg.?.data});
    }
};
