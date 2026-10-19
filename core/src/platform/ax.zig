//! Accessibility (HIServices): hand-written extern declarations + helpers.
//! Values verified against MacOSX.sdk HIServices headers (AXError.h, AXValue.h,
//! AXUIElement.h, AXAttributeConstants.h, AXRoleConstants.h, AXNotificationConstants.h).

const cf = @import("cf.zig");
const cg = @import("cg.zig");

pub const Element = opaque {};
/// AXUIElementRef
pub const ElementRef = *Element;
pub const Value = opaque {};
/// AXValueRef
pub const ValueRef = *const Value;
pub const Observer = opaque {};
/// AXObserverRef
pub const ObserverRef = *Observer;

pub const Error = i32;
pub const err = struct {
    pub const success: Error = 0;
    pub const failure: Error = -25200;
    pub const illegal_argument: Error = -25201;
    pub const invalid_ui_element: Error = -25202;
    pub const invalid_ui_element_observer: Error = -25203;
    pub const cannot_complete: Error = -25204;
    pub const attribute_unsupported: Error = -25205;
    pub const action_unsupported: Error = -25206;
    pub const notification_unsupported: Error = -25207;
    pub const not_implemented: Error = -25208;
    pub const notification_already_registered: Error = -25209;
    pub const notification_not_registered: Error = -25210;
    pub const api_disabled: Error = -25211;
    pub const no_value: Error = -25212;
};

/// AXValueType
pub const value_type = struct {
    pub const illegal: u32 = 0;
    pub const cg_point: u32 = 1;
    pub const cg_size: u32 = 2;
    pub const cg_rect: u32 = 3;
    pub const cf_range: u32 = 4;
    pub const ax_error: u32 = 5;
};

/// AXCopyMultipleAttributeOptions
pub const copy_multiple_stop_on_error: u32 = 0x1;

pub const ObserverCallback = *const fn (observer: ObserverRef, element: ElementRef, notification: cf.StringRef, refcon: ?*anyopaque) callconv(.c) void;

pub extern fn AXIsProcessTrusted() cf.Boolean;
pub extern fn AXIsProcessTrustedWithOptions(options: ?cf.DictionaryRef) cf.Boolean;
pub extern const kAXTrustedCheckOptionPrompt: cf.StringRef;

pub extern fn AXUIElementGetTypeID() cf.TypeID;
pub extern fn AXUIElementCreateSystemWide() ?ElementRef;
pub extern fn AXUIElementCreateApplication(pid: i32) ?ElementRef;
pub extern fn AXUIElementCopyAttributeValue(element: ElementRef, attribute: cf.StringRef, value: *?cf.TypeRef) Error;
pub extern fn AXUIElementCopyMultipleAttributeValues(element: ElementRef, attributes: cf.ArrayRef, options: u32, values: *?cf.ArrayRef) Error;
pub extern fn AXUIElementIsAttributeSettable(element: ElementRef, attribute: cf.StringRef, settable: *cf.Boolean) Error;
pub extern fn AXUIElementSetAttributeValue(element: ElementRef, attribute: cf.StringRef, value: cf.TypeRef) Error;
pub extern fn AXUIElementCopyElementAtPosition(application: ElementRef, x: f32, y: f32, element: *?ElementRef) Error;
pub extern fn AXUIElementGetPid(element: ElementRef, pid: *i32) Error;
pub extern fn AXUIElementSetMessagingTimeout(element: ElementRef, timeout_seconds: f32) Error;

pub extern fn AXValueGetTypeID() cf.TypeID;
pub extern fn AXValueCreate(the_type: u32, value_ptr: *const anyopaque) ?ValueRef;
pub extern fn AXValueGetType(value: ValueRef) u32;
pub extern fn AXValueGetValue(value: ValueRef, the_type: u32, value_ptr: *anyopaque) cf.Boolean;

pub extern fn AXObserverCreate(application: i32, callback: ObserverCallback, out_observer: *?ObserverRef) Error;
pub extern fn AXObserverAddNotification(observer: ObserverRef, element: ElementRef, notification: cf.StringRef, refcon: ?*anyopaque) Error;
pub extern fn AXObserverRemoveNotification(observer: ObserverRef, element: ElementRef, notification: cf.StringRef) Error;
pub extern fn AXObserverGetRunLoopSource(observer: ObserverRef) cf.RunLoopSourceRef;

// ---- CFSTR constants (created once, cached for the process lifetime) -----

pub const Strings = struct {
    // attributes
    role: cf.StringRef,
    subrole: cf.StringRef,
    title: cf.StringRef,
    position: cf.StringRef,
    size: cf.StringRef,
    window: cf.StringRef,
    parent: cf.StringRef,
    windows: cf.StringRef,
    focused_window: cf.StringRef,
    main_window: cf.StringRef,
    /// Undocumented string attribute (not in the SDK headers).
    full_screen: cf.StringRef,
    /// Undocumented application attribute set by assistive apps; when true, many apps
    /// animate AX frame changes, so it is cleared around setFrame.
    enhanced_ui: cf.StringRef,
    // roles / subroles (kAXWindowRole has the same value as kAXWindowAttribute)
    standard_window_subrole: cf.StringRef,
    // notifications
    window_moved: cf.StringRef,
    window_resized: cf.StringRef,
    // attribute lists for AXUIElementCopyMultipleAttributeValues
    list_frame: cf.ArrayRef, // [AXPosition, AXSize]
    list_hit: cf.ArrayRef, // [AXRole, AXWindow, AXParent]
    list_info: cf.ArrayRef, // [AXRole, AXSubrole, AXFullScreen]
};

pub var str: Strings = undefined;
var str_loaded = false;

/// Creates the cached CFString/CFArray constants. Idempotent; false only on OOM.
pub fn loadStrings() bool {
    if (str_loaded) return true;
    const role = cf.makeString("AXRole") orelse return false;
    const subrole = cf.makeString("AXSubrole") orelse return false;
    const position = cf.makeString("AXPosition") orelse return false;
    const size = cf.makeString("AXSize") orelse return false;
    const window = cf.makeString("AXWindow") orelse return false;
    const parent = cf.makeString("AXParent") orelse return false;
    const full_screen = cf.makeString("AXFullScreen") orelse return false;
    str = .{
        .role = role,
        .subrole = subrole,
        .title = cf.makeString("AXTitle") orelse return false,
        .position = position,
        .size = size,
        .window = window,
        .parent = parent,
        .windows = cf.makeString("AXWindows") orelse return false,
        .focused_window = cf.makeString("AXFocusedWindow") orelse return false,
        .main_window = cf.makeString("AXMainWindow") orelse return false,
        .full_screen = full_screen,
        .enhanced_ui = cf.makeString("AXEnhancedUserInterface") orelse return false,
        .standard_window_subrole = cf.makeString("AXStandardWindow") orelse return false,
        .window_moved = cf.makeString("AXWindowMoved") orelse return false,
        .window_resized = cf.makeString("AXWindowResized") orelse return false,
        .list_frame = cf.makeStringArray(&.{ position, size }) orelse return false,
        .list_hit = cf.makeStringArray(&.{ role, window, parent }) orelse return false,
        .list_info = cf.makeStringArray(&.{ role, subrole, full_screen }) orelse return false,
    };
    str_loaded = true;
    return true;
}

// ---- helpers ------------------------------------------------------------

pub fn isTrusted() bool {
    return AXIsProcessTrusted() != 0;
}

pub fn isElement(v: cf.TypeRef) bool {
    return cf.isType(v, AXUIElementGetTypeID());
}

pub fn asElement(v: cf.TypeRef) ElementRef {
    return @ptrCast(@constCast(v));
}

/// +1 attribute value or null (any AX error, including kAXErrorNoValue).
pub fn copyAttr(el: ElementRef, attr: cf.StringRef) ?cf.TypeRef {
    var v: ?cf.TypeRef = null;
    if (AXUIElementCopyAttributeValue(el, attr, &v) != err.success) {
        if (v) |x| cf.CFRelease(x);
        return null;
    }
    return v;
}

/// +1 attribute value, or null with the AX error in `out_err` (success on a non-element).
pub fn copyAttrErr(el: ElementRef, attr: cf.StringRef, out_err: *Error) ?cf.TypeRef {
    var v: ?cf.TypeRef = null;
    out_err.* = AXUIElementCopyAttributeValue(el, attr, &v);
    if (out_err.* != err.success) {
        if (v) |x| cf.CFRelease(x);
        return null;
    }
    return v;
}

/// +1 AXUIElement attribute (e.g. AXFocusedWindow) or null.
pub fn copyElementAttr(el: ElementRef, attr: cf.StringRef) ?ElementRef {
    const v = copyAttr(el, attr) orelse return null;
    if (!isElement(v)) {
        cf.CFRelease(v);
        return null;
    }
    return asElement(v);
}

pub fn boolAttr(el: ElementRef, attr: cf.StringRef) ?bool {
    const v = copyAttr(el, attr) orelse return null;
    defer cf.CFRelease(v);
    return cf.boolValue(v);
}

pub fn setBoolAttr(el: ElementRef, attr: cf.StringRef, value: bool) Error {
    const b = if (value) cf.kCFBooleanTrue else cf.kCFBooleanFalse;
    return AXUIElementSetAttributeValue(el, attr, b);
}

pub fn isSettable(el: ElementRef, attr: cf.StringRef) ?bool {
    var s: cf.Boolean = 0;
    if (AXUIElementIsAttributeSettable(el, attr, &s) != err.success) return null;
    return s != 0;
}

/// Equality with a cached CFString constant (CFEqual; works for any CF type).
pub fn stringEquals(v: ?cf.TypeRef, s: cf.StringRef) bool {
    const x = v orelse return false;
    if (!cf.isType(x, cf.CFStringGetTypeID())) return false;
    return cf.CFEqual(x, s) != 0;
}

/// Extracts a CGPoint from an AXValue (borrowed).
pub fn pointValue(v: ?cf.TypeRef) ?cg.Point {
    const x = v orelse return null;
    if (!cf.isType(x, AXValueGetTypeID())) return null;
    const av: ValueRef = @ptrCast(x);
    var p: cg.Point = .{ .x = 0, .y = 0 };
    if (AXValueGetType(av) != value_type.cg_point) return null;
    if (AXValueGetValue(av, value_type.cg_point, &p) == 0) return null;
    return p;
}

/// Extracts a CGSize from an AXValue (borrowed).
pub fn sizeValue(v: ?cf.TypeRef) ?cg.Size {
    const x = v orelse return null;
    if (!cf.isType(x, AXValueGetTypeID())) return null;
    const av: ValueRef = @ptrCast(x);
    var s: cg.Size = .{ .width = 0, .height = 0 };
    if (AXValueGetType(av) != value_type.cg_size) return null;
    if (AXValueGetValue(av, value_type.cg_size, &s) == 0) return null;
    return s;
}

pub fn setPoint(el: ElementRef, attr: cf.StringRef, p: cg.Point) Error {
    const v = AXValueCreate(value_type.cg_point, &p) orelse return err.failure;
    defer cf.release(v);
    return AXUIElementSetAttributeValue(el, attr, v);
}

pub fn setSize(el: ElementRef, attr: cf.StringRef, s: cg.Size) Error {
    const v = AXValueCreate(value_type.cg_size, &s) orelse return err.failure;
    defer cf.release(v);
    return AXUIElementSetAttributeValue(el, attr, v);
}

/// One round trip for several attributes. Returns a +1 CFArray whose entries are the
/// values, CFNull, or AXValue(kAXValueAXErrorType) for failed attributes.
pub fn copyMany(el: ElementRef, attrs: cf.ArrayRef) ?cf.ArrayRef {
    var out: ?cf.ArrayRef = null;
    if (AXUIElementCopyMultipleAttributeValues(el, attrs, 0, &out) != err.success) {
        if (out) |o| cf.release(o);
        return null;
    }
    return out;
}

pub fn pid(el: ElementRef) i32 {
    var p: i32 = 0;
    if (AXUIElementGetPid(el, &p) != err.success) return 0;
    return p;
}

/// Copies the AXTitle of `el` into `buf` (UTF-8). null if missing.
pub fn title(el: ElementRef, buf: []u8) ?[]const u8 {
    const v = copyAttr(el, str.title) orelse return null;
    defer cf.CFRelease(v);
    if (!cf.isType(v, cf.CFStringGetTypeID())) return null;
    return cf.stringUtf8(@ptrCast(v), buf);
}

/// AXIsProcessTrustedWithOptions({kAXTrustedCheckOptionPrompt: true}).
pub fn isTrustedPrompt() bool {
    const keys = [_]?*const anyopaque{kAXTrustedCheckOptionPrompt};
    const vals = [_]?*const anyopaque{cf.kCFBooleanTrue};
    const dict = cf.CFDictionaryCreate(null, &keys, &vals, 1, &cf.kCFTypeDictionaryKeyCallBacks, &cf.kCFTypeDictionaryValueCallBacks) orelse
        return isTrusted();
    defer cf.release(dict);
    return AXIsProcessTrustedWithOptions(dict) != 0;
}
