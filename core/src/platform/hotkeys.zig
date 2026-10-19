//! Global hotkeys via Carbon RegisterEventHotKey on the application event target.
//! One handler for kEventClassKeyboard/kEventHotKeyPressed; EventHotKeyID =
//! {signature 'NKTA', id = nk_action}. Main thread only.

const t = @import("../types.zig");
const Engine = @import("../engine.zig").Engine;
const cf = @import("cf.zig");
const carbon = @import("carbon.zig");
const dispatch = @import("dispatch.zig");

pub const signature: u32 = cf.fourcc("NKTA");

pub const Hotkeys = struct {
    engine: *Engine,
    handler: ?carbon.EventHandlerRef = null,
    refs: [t.Action.count]?carbon.EventHotKeyRef = @splat(null),
    /// Last registration attempt for the action failed (reset on unbind / uninstall).
    failed: [t.Action.count]bool = @splat(false),

    /// Installs the hot-key-pressed handler on the application event target.
    pub fn install(self: *Hotkeys) t.Result {
        if (self.handler != null) return .ok;
        const spec = [_]carbon.EventTypeSpec{.{
            .event_class = carbon.event_class_keyboard,
            .event_kind = carbon.event_hot_key_pressed,
        }};
        var ref: ?carbon.EventHandlerRef = null;
        const st = carbon.InstallEventHandler(carbon.GetApplicationEventTarget(), handle, spec.len, &spec, self, &ref);
        if (st != carbon.no_err or ref == null) return .hotkey;
        self.handler = ref;
        return .ok;
    }

    /// Unregisters every hotkey and removes the handler. Idempotent.
    pub fn uninstall(self: *Hotkeys) void {
        for (0..t.Action.count) |i| self.unregisterIndex(i);
        self.failed = @splat(false);
        if (self.handler) |h| _ = carbon.RemoveEventHandler(h);
        self.handler = null;
    }

    /// (Re)registers `action`. key == key_none just unregisters it.
    pub fn register(self: *Hotkeys, action: t.Action, hk: t.Hotkey) t.Result {
        const i: usize = @intFromEnum(action);
        self.unregisterIndex(i);
        self.failed[i] = false;
        if (action == .none or hk.key == t.key_none) return .ok;
        var ref: ?carbon.EventHotKeyRef = null;
        const st = carbon.RegisterEventHotKey(
            hk.key,
            carbon.modsToCarbon(hk.mods),
            .{ .signature = signature, .id = @intCast(i) },
            carbon.GetApplicationEventTarget(),
            carbon.hot_key_no_options,
            &ref,
        );
        if (st != carbon.no_err or ref == null) {
            self.failed[i] = true;
            return .hotkey;
        }
        self.refs[i] = ref;
        return .ok;
    }

    fn unregisterIndex(self: *Hotkeys, i: usize) void {
        if (self.refs[i]) |r| _ = carbon.UnregisterEventHotKey(r);
        self.refs[i] = null;
    }

    pub fn boundCount(self: *const Hotkeys) u32 {
        var n: u32 = 0;
        for (self.refs) |r| n += @intFromBool(r != null);
        return n;
    }

    pub fn failedCount(self: *const Hotkeys) u32 {
        var n: u32 = 0;
        for (self.failed) |f| n += @intFromBool(f);
        return n;
    }
};

fn handle(call: carbon.EventHandlerCallRef, event: carbon.EventRef, user_data: ?*anyopaque) callconv(.c) carbon.OSStatus {
    const t0 = dispatch.nowNs();
    _ = call;
    const self: *Hotkeys = @ptrCast(@alignCast(user_data orelse return carbon.event_not_handled_err));
    var id: carbon.EventHotKeyID = .{ .signature = 0, .id = 0 };
    const st = carbon.GetEventParameter(
        event,
        carbon.event_param_direct_object,
        carbon.type_event_hot_key_id,
        null,
        @sizeOf(carbon.EventHotKeyID),
        null,
        &id,
    );
    if (st != carbon.no_err or id.signature != signature) return carbon.event_not_handled_err;
    const action = t.Action.fromInt(id.id) orelse return carbon.event_not_handled_err;
    if (action == .none or self.refs[id.id] == null) return carbon.event_not_handled_err;
    _ = self.engine.perform(action, 0, .keyboard, t0);
    return carbon.no_err;
}
