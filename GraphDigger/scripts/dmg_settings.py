# 安装包(dmg)的窗口布局 —— 给 dmgbuild 读的配置文件。
#
# 用 dmgbuild 而不是"hdiutil create 一下就完事",是因为**窗口布局存在 .DS_Store 里**:
# 图标位置、窗口大小、背景图、图标尺寸,全都要写进那个二进制文件,Finder 打开时
# 才照做。dmgbuild 会自己写它(不需要 Finder 脚本、不需要登录会话),而 hdiutil
# 只会把文件塞进去 —— 于是用户拿到的是一个空荡荡、图标 64pt、窗口按源文件夹撑开
# 的镜像(那正是用户的抱怨)。
#
# 坐标是**Finder 的说法**:原点在窗口内容区左上,y 向下。窗口 640×400 点,两个图标
# 放在 (170, 190) 与 (470, 190) —— 与 `make_dmg_background.swift` 里画箭头的
# y=190 是同一个数,改一处必须改另一处,否则箭头会指歪。

import os

app = defines.get("app")
appname = defines.get("appname", "GraphDigger")
background_path = defines.get("background")
volume_name = defines.get("volume_name", appname)

if not app or not os.path.exists(app):
    raise SystemExit("dmg_settings: 找不到要打包的 .app(用 -D app=... 传入)")
if not background_path or not os.path.exists(background_path):
    raise SystemExit("dmg_settings: 找不到背景图(用 -D background=... 传入)")

# 窗口里放两样东西:应用本体,以及指向 /Applications 的软链。
# 软链就是"拖动安装"能成立的全部原因 —— 把图标拖到它上面,等于拖进应用程序文件夹。
files = [app]
symlinks = {"Applications": "/Applications"}

icon_locations = {
    appname + ".app": (170, 190),
    "Applications": (470, 190),
}

background = background_path
window_rect = ((160, 160), (640, 400))   # (左上角屏幕位置, 内容区尺寸)
default_view = "icon-view"
icon_size = 128          # 默认 64 太小 —— 用户说"软件显示又小",这里是那个数
text_size = 12
label_pos = "bottom"

# 一个干净的安装窗口:不要侧栏、路径栏、工具栏、状态栏。
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
arrange_by = None
grid_spacing = 100

# 挂载后卷图标用应用自己的图标,而不是白磁盘。
badge_icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")

format = "UDZO"
compression_level = 9
