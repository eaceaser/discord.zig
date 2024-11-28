const Self = @This();

const std = @import("std");
const ws = @import("websocket");
const xev = @import("xev");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.discord);
const json = std.json;

const discordApiRoot = "https://discord.com/api/v10";

const OpCode = enum(u32) {
    heartbeat = 1,
    identify = 2,

    hello = 10,
    _,
};

fn _dummyCallback(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: xev.Timer.RunError!void) xev.CallbackAction {
    log.debug("dummy callback", .{});
    return .disarm;
}

pub fn Event(comptime T: type) type {
    return struct {
        op: u32,
        d: ?T,
        s: ?i32 = null,
        t: ?[]const u8 = null,
    };
}

// clients
http_client: std.http.Client,
ws_client: ws.Client,

allocator: Allocator,
token: []const u8,
bot_token: []const u8,
loop: xev.Loop,

ws_thread: std.Thread = undefined,
loop_thread: std.Thread = undefined,

heartbeat_timer: xev.Timer,
heartbeat_timer_c: xev.Completion = .{},

seq: ?u64 = null,
heartbeat_interval: ?u64 = null,

pub const Opts = struct {
    token: []const u8,
};

pub fn init(allocator: Allocator, opts: Opts) !Self {
    var http_client = std.http.Client{
        .allocator = allocator,
    };
    errdefer http_client.deinit();

    // TODO(eac): inject me?
    var l = try xev.Loop.init(.{});
    errdefer l.deinit();

    var timer = try xev.Timer.init();
    errdefer timer.deinit();

    const bot_token = try std.mem.concat(allocator, u8, &.{ "Bot ", opts.token });
    errdefer allocator.free(bot_token);

    return .{
        .allocator = allocator,
        .token = opts.token,
        .http_client = http_client,
        .ws_client = undefined,
        .loop = l,
        .heartbeat_timer = timer,
        .bot_token = bot_token,
    };
}

pub fn deinit(self: *Self) void {
    self.http_client.deinit();
    self.loop.deinit();
    self.heartbeat_timer.deinit();
    self.allocator.free(self.bot_token);
}

// pub fn run(self: *Self) !void {
//     const thread = try std.Thread.spawn(.{}, loop, .{self});
//     thread.join();
// }

// pub fn stop(self: *Discord) void {}

pub fn threadEnter(self: *Self) !void {
    log.debug("in client thread", .{});

    var body = std.ArrayList(u8).init(self.allocator);
    defer body.deinit();

    const resp = try self.http_client.fetch(.{ .method = .GET, .location = .{ .url = discordApiRoot ++ "/gateway" }, .headers = .{
        .authorization = .{ .override = self.bot_token },
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
    // const tls = std.mem.eql(u8, uri.scheme, "wss");
    // if tls, use default wss port, otherwise use default ws port
    // const port = if (tls) 443 else 80;
    // var client = try ws.Client.init(self.allocator, .{
    //     .host = uri.host.?.percent_encoded,
    //     .port = 443,
    //     .tls = tls,
    // });

    // TODO(eac): ownership id kinda broken here, fix me
    var ws_client = try ws.connect(self.allocator, uri.host.?.percent_encoded, 443, .{ .tls = true, .handle_close = true });
    self.ws_client = ws_client;
    defer ws_client.deinit();

    var ws_headers = std.ArrayList(u8).init(self.allocator);
    defer ws_headers.deinit();
    try ws_headers.writer().print("Host: {s}", .{uri.host.?.percent_encoded});

    try ws_client.handshake("/", .{ .headers = ws_headers.items });

    self.ws_thread = try ws_client.readLoopInNewThread(self);
    // TODO(eac): add shutdown signal handler
    self.ws_thread.join();
}

pub fn handle(self: *Self, msg: ws.Message) !void {
    log.debug("got a message? {s}", .{msg.data});

    var parsedEvent = try json.parseFromSlice(json.Value, self.allocator, msg.data, .{});
    defer parsedEvent.deinit();

    const op: OpCode = @enumFromInt(parsedEvent.value.object.get("op").?.integer);
    switch (op) {
        .hello => {
            log.debug("got a hello message", .{});
            const payload = try json.parseFromValue(struct {
                heartbeat_interval: u64,
            }, self.allocator, parsedEvent.value.object.get("d").?, .{ .ignore_unknown_fields = true });
            defer payload.deinit();

            log.debug("parsed heartbeat payload: {}", .{payload});
            if (parsedEvent.value.object.get("s")) |v| switch (v) {
                .integer => |i| self.seq = @intCast(i),
                else => {},
            };

            // TODO(eac): jitter after rand changes in 0.13
            self.heartbeat_interval = payload.value.heartbeat_interval;
            self.heartbeat_timer.run(&self.loop, &self.heartbeat_timer_c, self.heartbeat_interval.?, Self, self, &heartbeatCallback);
            self.loop_thread = try std.Thread.spawn(.{}, loopThread, .{self});
            self.loop_thread.detach();

            const identify_payload: Event(struct {
                token: []const u8,
                intents: u64,
                properties: struct {
                    os: []const u8,
                    browser: []const u8,
                    device: []const u8,
                },
            }) = .{
                .op = @intFromEnum(OpCode.identify),
                .d = .{
                    .token = self.bot_token,
                    .intents = 1,
                    .properties = .{
                        .os = "linux",
                        .browser = "discord_zig",
                        .device = "discord_zig",
                    },
                },
            };

            const body = try json.stringifyAlloc(self.allocator, identify_payload, .{});
            log.debug("sending identify payload: {s}", .{body});
            defer self.allocator.free(body);
            try self.ws_client.writeText(body);
        },
        else => {
            log.debug("got an unknown message: {}", .{parsedEvent.value.object});
        },
    }
}

fn loopThread(self: *Self) !void {
    log.debug("running event loop", .{});
    try self.loop.run(.until_done);
}

fn heartbeatCallback(self_: ?*Self, loop: *xev.Loop, completion: *xev.Completion, err: xev.Timer.RunError!void) xev.CallbackAction {
    const self = self_ orelse unreachable;
    _ = loop;
    _ = completion;
    _ = err catch unreachable;

    const payload: Event(u64) = .{
        .op = @intFromEnum(OpCode.heartbeat),
        .d = self.seq,
    };

    log.debug("heartbeat payload: {any}", .{payload});
    const body = json.stringifyAlloc(self.allocator, payload, .{}) catch unreachable;
    defer self.allocator.free(body);
    self.ws_client.writeText(body) catch unreachable;

    // enqueue next heartbeat
    self.heartbeat_timer.run(&self.loop, &self.heartbeat_timer_c, self.heartbeat_interval.?, Self, self, &heartbeatCallback);

    return .disarm;
}

pub fn close(_: *Self) void {
    log.debug("websocket connection closed", .{});
    unreachable;
}
