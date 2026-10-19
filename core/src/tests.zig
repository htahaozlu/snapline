//! Test root for `zig build test`: pure modules + engine against the mock.
//! Platform code (platform/*.zig) is compile-checked by the library build instead.
//! The inert core (tools/snapshot only) is compiled and tested here too, so it cannot rot
//! between snapshot runs; in a test build root.zig exports no platform symbol, so its
//! `nk_core_*` exports do not collide.
comptime {
    _ = @import("types.zig");
    _ = @import("geometry.zig");
    _ = @import("layout.zig");
    _ = @import("zones.zig");
    _ = @import("rules.zig");
    _ = @import("abi.zig");
    _ = @import("mock.zig");
    _ = @import("engine_test.zig");
    _ = @import("root.zig");
    _ = @import("inert.zig");
}
