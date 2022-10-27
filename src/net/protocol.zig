const std = @import("std");
const crc32 = @import("../common/crc32.zig");

pub const PROTOCOL_MAGIC = [4]u8{ 'T', 'E', 'S', 'S' };
pub const HEADER_SIZE: usize = 24;

pub const Opcode = enum(u8) {
    ping = 1,
    pong = 2,
    query = 3,
    response = 4,
    err = 5,
    begin_txn = 6,
    commit_txn = 7,
    rollback_txn = 8,
    close = 9,
    _,
};

pub const ResponseStatus = enum(u8) {
    ok = 0,
    err_syntax = 1,
    err_execution = 2,
    err_conflict = 3,
    err_not_found = 4,
    err_corrupted = 5,
    _,
};

pub const MessageHeader = struct {
    magic: [4]u8 = PROTOCOL_MAGIC,
    opcode: Opcode,
    status: ResponseStatus,
    flags: u16 = 0,
    req_id: u64,
    payload_len: u32,
    checksum: u32,

    pub fn encode(self: MessageHeader, dest: *[HEADER_SIZE]u8) void {
        @memcpy(dest[0..4], &self.magic);
        dest[4] = @intFromEnum(self.opcode);
        dest[5] = @intFromEnum(self.status);
        std.mem.writeInt(u16, dest[6..8], self.flags, .little);
        std.mem.writeInt(u64, dest[8..16], self.req_id, .little);
        std.mem.writeInt(u32, dest[16..20], self.payload_len, .little);
        std.mem.writeInt(u32, dest[20..24], self.checksum, .little);
    }

    pub fn decode(src: *const [HEADER_SIZE]u8) !MessageHeader {
        if (!std.mem.eql(u8, src[0..4], &PROTOCOL_MAGIC)) {
            return error.InvalidMagic;
        }

        const opcode: Opcode = @enumFromInt(src[4]);
        const status: ResponseStatus = @enumFromInt(src[5]);
        const flags = std.mem.readInt(u16, src[6..8], .little);
        const req_id = std.mem.readInt(u64, src[8..16], .little);
        const payload_len = std.mem.readInt(u32, src[16..20], .little);
        const checksum = std.mem.readInt(u32, src[20..24], .little);

        return MessageHeader{
            .magic = PROTOCOL_MAGIC,
            .opcode = opcode,
            .status = status,
            .flags = flags,
            .req_id = req_id,
            .payload_len = payload_len,
            .checksum = checksum,
        };
    }
};

pub const Packet = struct {
    header: MessageHeader,
    payload: []const u8,

    pub fn serialize(
        allocator: std.mem.Allocator,
        opcode: Opcode,
        status: ResponseStatus,
        req_id: u64,
        payload: []const u8,
    ) ![]u8 {
        const total_len = HEADER_SIZE + payload.len;
        const buf = try allocator.alloc(u8, total_len);
        errdefer allocator.free(buf);

        const checksum = crc32.calculate(payload);
        const header = MessageHeader{
            .opcode = opcode,
            .status = status,
            .flags = 0,
            .req_id = req_id,
            .payload_len = @as(u32, @intCast(payload.len)),
            .checksum = checksum,
        };

        header.encode(buf[0..HEADER_SIZE]);
        if (payload.len > 0) {
            @memcpy(buf[HEADER_SIZE..total_len], payload);
        }

        return buf;
    }

    pub fn deserialize(bytes: []const u8) !Packet {
        if (bytes.len < HEADER_SIZE) return error.BufferTooSmall;
        const header = try MessageHeader.decode(bytes[0..HEADER_SIZE]);

        if (bytes.len < HEADER_SIZE + header.payload_len) {
            return error.IncompletePayload;
        }

        const payload = bytes[HEADER_SIZE .. HEADER_SIZE + header.payload_len];
        const actual_crc = crc32.calculate(payload);
        if (actual_crc != header.checksum) {
            return error.ChecksumMismatch;
        }

        return Packet{
            .header = header,
            .payload = payload,
        };
    }
};

test "protocol header encode and decode" {
    var header = MessageHeader{
        .opcode = .query,
        .status = .ok,
        .flags = 0x01,
        .req_id = 998877,
        .payload_len = 128,
        .checksum = 0xDEADBEEF,
    };

    var buf: [HEADER_SIZE]u8 = undefined;
    header.encode(&buf);

    const decoded = try MessageHeader.decode(&buf);
    try std.testing.expectEqual(Opcode.query, decoded.opcode);
    try std.testing.expectEqual(ResponseStatus.ok, decoded.status);
    try std.testing.expectEqual(@as(u16, 0x01), decoded.flags);
    try std.testing.expectEqual(@as(u64, 998877), decoded.req_id);
    try std.testing.expectEqual(@as(u32, 128), decoded.payload_len);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), decoded.checksum);
}

test "protocol packet serialize and deserialize with CRC" {
    const allocator = std.testing.allocator;
    const msg = "GET user:1001";

    const wire = try Packet.serialize(allocator, .query, .ok, 42, msg);
    defer allocator.free(wire);

    const pkt = try Packet.deserialize(wire);
    try std.testing.expectEqual(Opcode.query, pkt.header.opcode);
    try std.testing.expectEqual(@as(u64, 42), pkt.header.req_id);
    try std.testing.expectEqualStrings(msg, pkt.payload);
}

test "protocol checksum corruption rejection" {
    const allocator = std.testing.allocator;
    const msg = "PUT test_key 123";

    var wire = try Packet.serialize(allocator, .query, .ok, 1, msg);
    defer allocator.free(wire);

    // Corrupt one payload byte
    wire[HEADER_SIZE + 2] ^= 0xFF;

    const res = Packet.deserialize(wire);
    try std.testing.expectError(error.ChecksumMismatch, res);
}
