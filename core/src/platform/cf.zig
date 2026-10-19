//! CoreFoundation: hand-written extern declarations (no @cImport) + small helpers.
//! Values verified against MacOSX.sdk CoreFoundation headers.

pub const TypeRef = *const anyopaque;
pub const String = opaque {};
pub const StringRef = *const String;
pub const Array = opaque {};
pub const ArrayRef = *const Array;
pub const Dictionary = opaque {};
pub const DictionaryRef = *const Dictionary;
pub const BooleanObj = opaque {};
pub const BooleanRef = *const BooleanObj;
pub const RunLoop = opaque {};
pub const RunLoopRef = *RunLoop;
pub const RunLoopSource = opaque {};
pub const RunLoopSourceRef = *RunLoopSource;
pub const MachPort = opaque {};
pub const MachPortRef = *MachPort;
pub const Allocator = opaque {};
pub const AllocatorRef = *const Allocator;
pub const ArrayCallBacks = opaque {};
pub const DictionaryKeyCallBacks = opaque {};
pub const DictionaryValueCallBacks = opaque {};

pub const Index = isize;
pub const TypeID = usize;
/// MacTypes.h `Boolean` (unsigned char).
pub const Boolean = u8;

/// CFStringBuiltInEncodings.kCFStringEncodingUTF8
pub const string_encoding_utf8: u32 = 0x08000100;

pub extern fn CFRetain(cf: TypeRef) TypeRef;
pub extern fn CFRelease(cf: TypeRef) void;
pub extern fn CFEqual(a: TypeRef, b: TypeRef) Boolean;
pub extern fn CFGetTypeID(cf: TypeRef) TypeID;

pub extern fn CFStringGetTypeID() TypeID;
pub extern fn CFStringCreateWithCString(alloc: ?AllocatorRef, c_str: [*:0]const u8, encoding: u32) ?StringRef;
pub extern fn CFStringGetCString(s: StringRef, buffer: [*]u8, buffer_size: Index, encoding: u32) Boolean;

pub extern fn CFArrayGetTypeID() TypeID;
pub extern fn CFArrayCreate(alloc: ?AllocatorRef, values: [*]const ?*const anyopaque, num_values: Index, callbacks: ?*const ArrayCallBacks) ?ArrayRef;
pub extern fn CFArrayGetCount(a: ArrayRef) Index;
pub extern fn CFArrayGetValueAtIndex(a: ArrayRef, idx: Index) ?*const anyopaque;
pub extern const kCFTypeArrayCallBacks: ArrayCallBacks;

pub extern fn CFDictionaryCreate(
    alloc: ?AllocatorRef,
    keys: [*]const ?*const anyopaque,
    values: [*]const ?*const anyopaque,
    num_values: Index,
    key_callbacks: ?*const DictionaryKeyCallBacks,
    value_callbacks: ?*const DictionaryValueCallBacks,
) ?DictionaryRef;
pub extern const kCFTypeDictionaryKeyCallBacks: DictionaryKeyCallBacks;
pub extern const kCFTypeDictionaryValueCallBacks: DictionaryValueCallBacks;

pub extern fn CFBooleanGetTypeID() TypeID;
pub extern fn CFBooleanGetValue(b: BooleanRef) Boolean;
pub extern const kCFBooleanTrue: BooleanRef;
pub extern const kCFBooleanFalse: BooleanRef;

pub extern fn CFRunLoopGetMain() RunLoopRef;
pub extern fn CFRunLoopAddSource(rl: RunLoopRef, source: RunLoopSourceRef, mode: StringRef) void;
pub extern fn CFRunLoopRemoveSource(rl: RunLoopRef, source: RunLoopSourceRef, mode: StringRef) void;
pub extern const kCFRunLoopCommonModes: StringRef;
pub extern const kCFRunLoopDefaultMode: StringRef;

pub extern fn CFMachPortCreateRunLoopSource(alloc: ?AllocatorRef, port: MachPortRef, order: Index) ?RunLoopSourceRef;
pub extern fn CFMachPortInvalidate(port: MachPortRef) void;

// ---- helpers ------------------------------------------------------------

pub inline fn release(cf: anytype) void {
    CFRelease(@ptrCast(cf));
}

pub inline fn retain(cf: anytype) void {
    _ = CFRetain(@ptrCast(cf));
}

pub fn isType(cf: TypeRef, id: TypeID) bool {
    return CFGetTypeID(cf) == id;
}

/// Creates an immortal CFString from a literal (the CFSTR() equivalent). Called once per
/// constant by the caches in ax.zig; never released.
pub fn makeString(s: [*:0]const u8) ?StringRef {
    return CFStringCreateWithCString(null, s, string_encoding_utf8);
}

/// Creates an immortal CFArray of CFStrings (attribute lists for multi-attribute reads).
pub fn makeStringArray(items: []const StringRef) ?ArrayRef {
    var buf: [8]?*const anyopaque = undefined;
    if (items.len > buf.len) return null;
    for (items, 0..) |it, i| buf[i] = it;
    return CFArrayCreate(null, &buf, @intCast(items.len), &kCFTypeArrayCallBacks);
}

/// Copies a CFString as UTF-8 into `buf` (NUL excluded from the returned slice).
pub fn stringUtf8(s: StringRef, buf: []u8) ?[]const u8 {
    if (buf.len == 0) return null;
    if (CFStringGetCString(s, buf.ptr, @intCast(buf.len), string_encoding_utf8) == 0) return null;
    var n: usize = 0;
    while (n < buf.len and buf[n] != 0) : (n += 1) {}
    return buf[0..n];
}

/// Interprets a CFTypeRef as CFBoolean.
pub fn boolValue(cf: TypeRef) ?bool {
    if (!isType(cf, CFBooleanGetTypeID())) return null;
    return CFBooleanGetValue(@ptrCast(cf)) != 0;
}

/// Element `i` of an array, borrowed (not retained).
pub fn arrayAt(a: ArrayRef, i: usize) ?TypeRef {
    if (i >= @as(usize, @intCast(@max(CFArrayGetCount(a), 0)))) return null;
    return CFArrayGetValueAtIndex(a, @intCast(i));
}

/// Four-character code ('keyb' etc.) as used by Carbon and OSType.
pub fn fourcc(comptime s: *const [4]u8) u32 {
    return (@as(u32, s[0]) << 24) | (@as(u32, s[1]) << 16) | (@as(u32, s[2]) << 8) | @as(u32, s[3]);
}

test "fourcc" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 0x6B657962), fourcc("keyb"));
    try std.testing.expectEqual(@as(u32, 0x2D2D2D2D), fourcc("----"));
    try std.testing.expectEqual(@as(u32, 0x4E4B5441), fourcc("NKTA"));
}
