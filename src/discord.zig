const Self = @This();

const std = @import("std");
const ws = @import("websocket");
const xev = @import("xev");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.discord);
const json = std.json;

const discordApiRoot = "https://discord.com/api/v10";

const OpCode = enum(u8) {
    hello = 10,
};

fn _dummyCallback(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: xev.Timer.RunError!void) xev.CallbackAction {
    log.debug("dummy callback", .{});
    return .disarm;
}

pub fn Event(comptime T: type) type {
    return struct {
        op: i32,
        d: ?T,
        s: ?i32,
        t: ?[]const u8,
    };
}

allocator: Allocator,
token: []const u8,
client: std.http.Client,
loop: xev.Loop,

_wsThread: std.Thread = undefined,
loopThread: std.Thread,

heartbeat_timer: xev.Timer,
heartbeat_timer_c: xev.Completion = .{},

seq: u64,

// _heartbeat_interval: u64,

pub const Opts = struct {
    token: []const u8,
};

const CallbackCtx = struct {
    self: *Self,
};

pub fn init(allocator: Allocator, opts: Opts) !Self {
    var client = std.http.Client{
        .allocator = allocator,
    };
    errdefer client.deinit();

    // TODO(eac): inject me?
    const l = try xev.Loop.init(.{});
    errdefer l.deinit();

    var timer = try xev.Timer.init();
    errdefer timer.deinit();

    return .{
        .allocator = allocator,
        .token = opts.token,
        .client = client,
        .loop = l,
        .heartbeat_timer = timer,
        .seq = 0,
    };
}

pub fn deinit(self: *Self) void {
    self.client.deinit();
    self.loop.deinit();
}

// pub fn run(self: *Self) !void {
//     const thread = try std.Thread.spawn(.{}, loop, .{self});
//     thread.join();
// }

// pub fn stop(self: *Discord) void {}

pub fn threadEnter(self: *Self) !void {
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
    // const tls = std.mem.eql(u8, uri.scheme, "wss");
    // if tls, use default wss port, otherwise use default ws port
    // const port = if (tls) 443 else 80;
    // var client = try ws.Client.init(self.allocator, .{
    //     .host = uri.host.?.percent_encoded,
    //     .port = 443,
    //     .tls = tls,
    // });
    var client = try ws.connect(self.allocator, uri.host.?.percent_encoded, 443, .{ .tls = true });
    defer client.deinit();

    var wsHeaders = std.ArrayList(u8).init(self.allocator);
    defer wsHeaders.deinit();
    try wsHeaders.writer().print("Host: {s}", .{uri.host.?.percent_encoded});

    try client.handshake("/", .{ .headers = wsHeaders.items });

    self._wsThread = try client.readLoopInNewThread(self);
    // TODO(eac): add shutdown signal handler
    self._wsThread.join();
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
            self.seq = parsedEvent.value.object.get("s").?.integer;

            const ctx: CallbackCtx = .{ .self = self };
            self.heartbeat_timer.run(&self.loop, &self.heartbeat_timer_c, payload.value.heartbeat_interval, CallbackCtx, &ctx, &heartbeatCallback);
        },
        // else => {
        //     log.debug("got an unknown message: {}", .{op});
        // },
    }
}

fn heartbeatCallback(ctx: *CallbackCtx, loop: *xev.Loop, completion: *xev.Completion, err: xev.Timer.RunError!void) xev.CallbackAction {
    log.debug("in heartbeat callback", .{});
    const self = ctx.self;

    const payload: Event(u64) = .{
        .op = 1,
        .d = self.seq,
    };
}

pub fn close(_: *Self) void {}
