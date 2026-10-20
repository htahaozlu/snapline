# dmgbuild settings for the Snapline installer window (see tools/dmg/make-dmg.sh).
#
#   dmgbuild -s tools/dmg/settings.py -D app=<Snapline.app> -D background=<dir>/background.png "Snapline" out.dmg
#
# background.png comes from tools/dmg/render-background.swift; dmgbuild finds the background@2x.png
# beside it and merges both into one HiDPI TIFF itself (tiffutil -cathidpicheck).
# Icon positions are Finder coordinates (top-left origin) and must match the art in that script.
import os

app = defines.get("app")  # noqa: F821  (`defines` is injected by dmgbuild from -D)
background = defines.get("background")  # noqa: F821
if not app or not os.path.isdir(app):
    raise SystemExit("settings.py: pass -D app=<path to Snapline.app>")
if not background or not os.path.isfile(background):
    raise SystemExit("settings.py: pass -D background=<path to background.png>")
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")
if not os.path.isfile(icon):
    raise SystemExit("settings.py: no AppIcon.icns in " + app)

# UDZO + zlib-9 + HFS+: opens on every macOS the app supports (ULFO/ULMO need 10.11/10.15+ and the
# win is a few hundred KB on a ~1 MB app). Deterministic enough; the DMG is signed afterwards.
format = "UDZO"
compression_level = 9
filesystem = "HFS+"

volume_name = "Snapline"
badge_icon = None
icon = icon  # volume icon: the app's own

files = [app]
symlinks = {"Applications": "/Applications"}

background = background
window_rect = ((200, 120), (660, 400))  # (origin), (size) in points
default_view = "icon-view"
show_toolbar = False
show_status_bar = False
show_pathbar = False
show_sidebar = False
show_tab_view = False
show_icon_preview = False
show_item_info = False
include_icon_view_settings = "auto"
arrange_by = None
label_pos = "bottom"

icon_size = 128
text_size = 13
icon_locations = {
    "Snapline.app": (180, 210),
    "Applications": (480, 210),
}
