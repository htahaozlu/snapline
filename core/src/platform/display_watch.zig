//! CGDisplayRegisterReconfigurationCallback → Engine.displaysChanged() (cache invalidation).
//! CG invokes the callback on the event-processing (main) thread; the begin-configuration
//! pass is ignored, the per-display "after" passes each invalidate (cheap, idempotent).
//! Dock / menu bar changes are not reported here: the shell calls nk_core_displays_changed.

const Engine = @import("../engine.zig").Engine;
const cg = @import("cg.zig");

pub const DisplayWatch = struct {
    engine: *Engine,
    registered: bool = false,

    pub fn start(self: *DisplayWatch) bool {
        if (self.registered) return true;
        if (cg.CGDisplayRegisterReconfigurationCallback(callback, self) != cg.success) return false;
        self.registered = true;
        return true;
    }

    /// Idempotent.
    pub fn stop(self: *DisplayWatch) void {
        if (!self.registered) return;
        _ = cg.CGDisplayRemoveReconfigurationCallback(callback, self);
        self.registered = false;
    }
};

fn callback(display: cg.DisplayID, flags: u32, user_info: ?*anyopaque) callconv(.c) void {
    _ = display;
    if (flags & cg.display_begin_configuration_flag != 0) return;
    const self: *DisplayWatch = @ptrCast(@alignCast(user_info orelse return));
    if (!self.registered) return;
    self.engine.displaysChanged();
}
