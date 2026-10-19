/*
 * nokta.h — C ABI between the Zig core (libnokta.a) and the Swift/AppKit shell.
 *
 * Conventions
 *  - All rectangles/points are in CoreGraphics *global* coordinates: origin at the
 *    top-left of the primary display, y grows downward, units are points.
 *    The shell converts to AppKit (bottom-left) coordinates only for its own windows.
 *  - Every function must be called on the main thread (the core is single-threaded and
 *    drives everything from the main run loop: Carbon hotkeys, the event tap, AXObservers).
 *  - The core never allocates memory that the caller must free. Strings passed in are
 *    copied; strings returned are static.
 *  - The core performs no network I/O and no file I/O.
 */
#ifndef NOKTA_H
#define NOKTA_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NK_ABI_VERSION 1u

typedef struct nk_core nk_core;

typedef struct {
    double x, y, w, h;
} nk_rect;

typedef struct {
    double x, y;
} nk_point;

/* Window actions. Values are part of the ABI and are persisted by the shell only through
 * nk_action_id() strings, never as integers. */
typedef enum {
    NK_ACTION_NONE = 0,
    NK_ACTION_LEFT_HALF = 1,
    NK_ACTION_RIGHT_HALF = 2,
    NK_ACTION_TOP_HALF = 3,
    NK_ACTION_BOTTOM_HALF = 4,
    NK_ACTION_TOP_LEFT = 5,
    NK_ACTION_TOP_RIGHT = 6,
    NK_ACTION_BOTTOM_LEFT = 7,
    NK_ACTION_BOTTOM_RIGHT = 8,
    NK_ACTION_FIRST_THIRD = 9,
    NK_ACTION_CENTER_THIRD = 10,
    NK_ACTION_LAST_THIRD = 11,
    NK_ACTION_FIRST_TWO_THIRDS = 12,
    NK_ACTION_CENTER_TWO_THIRDS = 13,
    NK_ACTION_LAST_TWO_THIRDS = 14,
    NK_ACTION_MAXIMIZE = 15,
    NK_ACTION_ALMOST_MAXIMIZE = 16,
    NK_ACTION_CENTER = 17,
    NK_ACTION_RESTORE = 18,
    NK_ACTION_NEXT_DISPLAY = 19,
    NK_ACTION_PREV_DISPLAY = 20,
    NK_ACTION_COUNT = 21
} nk_action;

/* Drag-to-snap zones on each display edge. */
typedef enum {
    NK_ZONE_NONE = 0,
    NK_ZONE_LEFT = 1,
    NK_ZONE_RIGHT = 2,
    NK_ZONE_TOP = 3,
    NK_ZONE_TOP_LEFT = 4,
    NK_ZONE_TOP_RIGHT = 5,
    NK_ZONE_BOTTOM_LEFT = 6,
    NK_ZONE_BOTTOM_RIGHT = 7,
    NK_ZONE_BOTTOM_LEFT_SEG = 8,   /* left third of the bottom edge   */
    NK_ZONE_BOTTOM_CENTER_SEG = 9, /* middle third of the bottom edge */
    NK_ZONE_BOTTOM_RIGHT_SEG = 10, /* right third of the bottom edge  */
    NK_ZONE_COUNT = 11
} nk_zone;

/* Modifier mask (Nokta's own bits; the core converts to Carbon / CGEventFlags). */
enum {
    NK_MOD_SHIFT = 1u << 0,
    NK_MOD_CONTROL = 1u << 1,
    NK_MOD_OPTION = 1u << 2,
    NK_MOD_COMMAND = 1u << 3
};

/* Virtual key code meaning "no shortcut". */
#define NK_KEY_NONE 0xFFFFu

typedef enum {
    NK_OK = 0,
    NK_ERR_NOT_TRUSTED = 1, /* Accessibility permission missing                         */
    NK_ERR_NO_WINDOW = 2,   /* no focused / matching window                              */
    NK_ERR_AX = 3,          /* an AX call failed or timed out                            */
    NK_ERR_EXCLUDED = 4,    /* target app is on the exclusion list                       */
    NK_ERR_INVALID = 5,     /* bad argument                                              */
    NK_ERR_NOT_MOVABLE = 6, /* window refuses position/size changes                      */
    NK_ERR_NO_MEMORY = 7,
    NK_ERR_EVENT_TAP = 8,   /* CGEventTapCreate failed                                   */
    NK_ERR_HOTKEY = 9,      /* RegisterEventHotKey failed (usually taken by another app) */
    NK_ERR_NOT_STARTED = 10
} nk_result;

typedef struct {
    uint32_t abi_version;      /* must be NK_ABI_VERSION                                 */
    double gap_outer;          /* pt between windows and display edges                   */
    double gap_inner;          /* pt between adjacent snapped windows                    */
    double zone_edge;          /* pt: thickness of the edge hit band                     */
    double zone_corner;        /* pt: length of corner hit area along each edge          */
    double almost_maximize;    /* 0.5 ... 1.0 fraction used by NK_ACTION_ALMOST_MAXIMIZE */
    uint32_t thirds_modifier;  /* NK_MOD_* mask held while dragging = alternate zone map (default ⇧) */
    bool drag_snap;            /* enable drag-to-snap (event tap)                        */
    bool snap_back;            /* dragging a snapped window restores its pre-snap size   */
    bool cycle_sizes;          /* repeating a half action cycles 1/2 → 2/3 → 1/3         */
    bool shared_edge_zones;    /* allow zones on edges shared with another display       */
} nk_config;

typedef enum {
    NK_EVENT_PREVIEW_SHOW = 1, /* rect = target frame, zone/action set; may repeat on zone change */
    NK_EVENT_PREVIEW_HIDE = 2,
    NK_EVENT_SNAPPED = 3,      /* rect = actual frame, action, latency_ns, cycle, flags      */
    NK_EVENT_FAILED = 4,       /* action, code = nk_result                                  */
    NK_EVENT_HOTKEY_STATE = 5  /* action, code = NK_OK or NK_ERR_HOTKEY after (re)binding   */
} nk_event_kind;

typedef enum {
    NK_SOURCE_KEYBOARD = 1,
    NK_SOURCE_DRAG = 2,
    NK_SOURCE_MENU = 3 /* nk_core_perform() */
} nk_source;

typedef struct {
    uint32_t kind;       /* nk_event_kind */
    uint32_t action;     /* nk_action     */
    uint32_t zone;       /* nk_zone       */
    uint32_t source;     /* nk_source     */
    int32_t code;        /* nk_result     */
    uint32_t display_id; /* CGDirectDisplayID of the target display (0 if unknown) */
    uint32_t cycle;      /* 0-based size-cycle index that was applied              */
    uint32_t flags;      /* NK_EVENT_FLAG_*                                       */
    nk_rect rect;        /* CG global coordinates                                  */
    uint64_t latency_ns; /* trigger → frame applied (SNAPPED only)                 */
} nk_event;

/* nk_event.flags (SNAPPED): the window came out LARGER than the requested frame (minimum
 * size); it was re-aligned to the edge the tile hugs with one position write and rect holds
 * the actual frame. Small differences (size increments, e.g. Terminal's cell grid) are not
 * flagged; rect then simply holds the actual frame. */
#define NK_EVENT_FLAG_FRAME_DIFFERS 0x1u
/* nk_event.flags (SNAPPED): the window refused the size change (fixed-size window); it was only
 * moved (aligned to the tile's edge) and keeps its size. */
#define NK_EVENT_FLAG_SIZE_REFUSED 0x2u
/* nk_event.flags (PREVIEW_HIDE): the drag ended over a zone and the drop will be applied (a
 * SNAPPED or FAILED event follows). Absent: the preview was cancelled (cursor left every zone,
 * modifier change, tap disabled, core stopped). */
#define NK_EVENT_FLAG_DROP 0x4u

typedef void (*nk_event_fn)(void *userdata, const nk_event *event);

typedef struct {
    uint64_t snaps;            /* successful frame changes since start */
    uint64_t failures;
    uint64_t last_latency_ns;
    uint64_t p50_latency_ns;   /* over the last 128 snaps */
    uint64_t p95_latency_ns;
    uint64_t max_latency_ns;
    uint32_t hotkeys_bound;
    uint32_t hotkeys_failed;
    uint32_t displays;
    int32_t observed_pid;      /* pid currently observed via AXObserver (0 = none) */
    bool event_tap_active;
    bool started;
} nk_stats;

/* ---- lifecycle ---------------------------------------------------------- */

uint32_t nk_abi_version(void);
const char *nk_version_string(void);

/* Fills *out with the defaults. */
void nk_config_default(nk_config *out);

/* Creates a core. Does not touch the system until nk_core_start(). Returns NULL on OOM
 * or abi mismatch. `cb` may be NULL. */
nk_core *nk_core_create(const nk_config *config, nk_event_fn cb, void *userdata);
void nk_core_destroy(nk_core *core);

/* Installs the hotkey handler (and registers bound hotkeys), the listen-only event tap
 * (if drag_snap) and the display reconfiguration callback. Requires Accessibility trust. */
nk_result nk_core_start(nk_core *core);
/* Unregisters hotkeys, removes the tap, observers and callbacks. Idempotent. */
void nk_core_stop(nk_core *core);

nk_result nk_core_set_config(nk_core *core, const nk_config *config);

/* ---- input from the shell ---------------------------------------------- */

/* Binds `action` to a shortcut (Carbon virtual key code + NK_MOD_* mask). key_code ==
 * NK_KEY_NONE unbinds. If the core is started the hotkey is (re)registered immediately
 * and an NK_EVENT_HOTKEY_STATE event reports the outcome. */
nk_result nk_core_bind_hotkey(nk_core *core, nk_action action, uint32_t key_code, uint32_t mods);

/* Maps a drag zone to an action. alternate == true sets the map used while
 * config.thirds_modifier is held. NK_ACTION_NONE disables the zone. */
nk_result nk_core_set_zone_action(nk_core *core, nk_zone zone, bool alternate, nk_action action);

/* Replaces the exclusion list (bundle identifiers, exact, case-insensitive). */
nk_result nk_core_set_excluded(nk_core *core, const char *const *bundle_ids, uint32_t count);

/* Must be called whenever the frontmost application changes (NSWorkspace notification)
 * and once after start. bundle_id may be NULL. */
void nk_core_app_activated(nk_core *core, int32_t pid, const char *bundle_id);

/* Must be called on NSApplicationDidChangeScreenParametersNotification (Dock/menu bar
 * changes do not trigger CG display reconfiguration). */
void nk_core_displays_changed(nk_core *core);

/* Usable frame (CG global) of a display as AppKit enforces it, supplied by the shell from
 * NSScreen.visibleFrame. Preferred over the core's HIToolbox value, which is wrong on
 * displays whose menu bar height differs from the main display's (notched built-ins).
 * usable == NULL removes the override; display_id == 0 with NULL clears all overrides. */
nk_result nk_core_set_display_usable(nk_core *core, uint32_t display_id, const nk_rect *usable);

/* Applies `action` to the focused window of the frontmost app (source = MENU). */
nk_result nk_core_perform(nk_core *core, nk_action action);

/* Applies `action` to the focused (else first) window of `pid`. Used by the benchmark
 * harness against its own test window. Works without nk_core_start(). */
nk_result nk_core_perform_pid(nk_core *core, int32_t pid, nk_action action);

/* ---- queries ------------------------------------------------------------ */

void nk_core_stats(const nk_core *core, nk_stats *out);

/* Accessibility trust. prompt == true shows the system prompt (only call from UI flows). */
bool nk_ax_is_trusted(bool prompt);

/* Stable string id for persistence ("left-half", ...). NULL for invalid values. */
const char *nk_action_id(nk_action action);
nk_action nk_action_from_id(const char *id); /* NK_ACTION_NONE if unknown */
const char *nk_zone_id(nk_zone zone);

/* Default shortcut for an action (key_code NK_KEY_NONE if none). */
void nk_default_hotkey(nk_action action, uint32_t *key_code, uint32_t *mods);
/* Default zone map. */
nk_action nk_default_zone_action(nk_zone zone, bool alternate);

/* Pure layout (no system access): the frame `action` would give a window of frame `window` on a
 * display whose usable rect is `usable`, with the gaps and Almost Maximize size of `config`
 * (cycle 0; thirds become rows when `usable` is portrait). Exactly what a snap writes.
 * Returns false for actions without a target frame (restore, display moves, none). */
bool nk_layout_frame(nk_action action, nk_rect window, nk_rect usable, const nk_config *config, nk_rect *out);

/* Usable frame (menu bar and Dock excluded) of the display containing `p`, CG global.
 * Returns false if no display contains p. */
bool nk_usable_frame_at(nk_core *core, nk_point p, nk_rect *out);

#ifdef __cplusplus
}
#endif

#endif /* NOKTA_H */
