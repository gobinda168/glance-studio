# dmgbuild settings for the installer DMG: the app on the left, Applications on the right, the arrow between them.
# release.sh runs: dmgbuild -s scripts/dmg-settings.py -D app=<bundle> -D background=<tiff> "<volume name>" <out.dmg>
# Icon positions must match the icon centres drawn by scripts/dmg-background.swift.
import os.path

app = defines["app"]  # noqa: F821 (dmgbuild injects `defines`)
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "Glance.icns")  # the mounted volume's icon

background = defines["background"]  # noqa: F821
window_rect = ((200, 160), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
icon_size = 112
text_size = 13
arrange_by = None
label_pos = "bottom"
icon_locations = {app_name: (170, 190), "Applications": (470, 190)}
