//! App exclusion rules. Fixed capacity, no allocation; matching is exact and ASCII
//! case-insensitive on bundle identifiers.

const std = @import("std");

pub const max_rules = 64;
pub const max_id_len = 255;

pub const Rules = struct {
    ids: [max_rules][max_id_len]u8 = undefined,
    lens: [max_rules]u8 = @splat(0),
    count: usize = 0,

    pub const Error = error{ TooMany, TooLong };

    pub fn clear(self: *Rules) void {
        self.count = 0;
    }

    /// Replaces the list. On error the previous list is kept.
    pub fn set(self: *Rules, ids: []const []const u8) Error!void {
        if (ids.len > max_rules) return error.TooMany;
        for (ids) |id| if (id.len > max_id_len) return error.TooLong;
        self.count = 0;
        for (ids) |id| {
            if (id.len == 0) continue;
            if (self.contains(id)) continue;
            const n = self.count;
            for (id, 0..) |ch, i| self.ids[n][i] = std.ascii.toLower(ch);
            self.lens[n] = @intCast(id.len);
            self.count += 1;
        }
    }

    pub fn contains(self: *const Rules, bundle_id: []const u8) bool {
        for (0..self.count) |i| {
            if (std.ascii.eqlIgnoreCase(self.ids[i][0..self.lens[i]], bundle_id)) return true;
        }
        return false;
    }

    pub fn isExcluded(self: *const Rules, bundle_id: ?[]const u8) bool {
        const id = bundle_id orelse return false;
        if (id.len == 0) return false;
        return self.contains(id);
    }
};

const testing = std.testing;

test "exclusion matching" {
    var r = Rules{};
    try r.set(&.{ "com.Example.App", "org.other", "", "com.example.app" });
    try testing.expectEqual(@as(usize, 2), r.count);
    try testing.expect(r.isExcluded("com.example.app"));
    try testing.expect(r.isExcluded("ORG.OTHER"));
    try testing.expect(!r.isExcluded("com.example"));
    try testing.expect(!r.isExcluded(null));
    try testing.expect(!r.isExcluded(""));
}

test "limits keep previous list" {
    var r = Rules{};
    try r.set(&.{"a.b"});
    var long: [300]u8 = @splat('x');
    try testing.expectError(error.TooLong, r.set(&.{long[0..]}));
    try testing.expect(r.isExcluded("a.b"));
}
