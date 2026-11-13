<div align="center">
  <img width="180" src="assets/images/logo/logo.png">
  <h1>PiliNara</h1>
  <p>第三方哔哩哔哩客户端 · 自用修改版</p>
  <p>基于 <a href="https://github.com/bggRGjQaUbCoE/PiliPlus">PiliPlus</a> / <a href="https://github.com/Starfallan/PiliNara">PiliNara</a></p>
</div>

---

## 我做了什么

本仓库在上游基础上只做了下面这些改动，上游原有功能见 [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)。

本 fork 新增的开关统一收在 **设置 → 实验室**（`Icons.science_outlined`），原本散落在「音视频设置」「播放器设置」「动态流设置」里的项已迁入，避免同一开关两处入口。下面提到的具体路径均以「设置 →」开头。

### 1. 全屏播放器布局编辑

- 入口：全屏播放器 → 右上角「更多设置」⋮ → **编辑播放器布局**
- 所有控件按区域分组（顶部标题栏 / 顶部操作按钮行 / 底部控制栏 / 左侧 / 右侧），可**逐项显示或隐藏**，也可**在同一区域内长按拖拽排序**
- 编辑页本身就是实时预览：勾选或拖动后立刻能看到控件在画面上的新位置；点「完成编辑」才保存，退出即丢弃
- 锁定按钮与截图按钮可以拖到左侧或右侧的竖排区，其余控件只能在原区域内换顺序
- 只有**全屏**（横屏全屏与竖屏全屏）使用自定义布局，半屏模式保持上游原样——半屏可编辑空间太局限
- 时钟 / 电量 / 在线人数 / 弹幕数属于信息类，不参与拖拽；直播与小窗播放不走这套布局
- 该功能来自上游分支 `feat/fullscreen-layout-editor`（对应 [PiliNara#430](https://github.com/Starfallan/PiliNara/issues/430)），上游标注为 Alpha，若某控件位置异常可在编辑器里点「恢复默认」
- 配套设置项（如「竖屏扩大展示」）在启用自定义布局后会提示「视频全屏请通过三点菜单编辑播放器布局」

> 本分支在此基础上把自研的「播放信息」按钮注册为布局控件（见下节），使它可以被隐藏和排序。

### 2. 播放信息侧栏

- 位置：全屏播放器底部操作栏，默认在**「缓存」与「分享」之间**，图标为 ⓘ
- 因为已注册为布局控件，可在布局编辑器里隐藏或拖到操作栏的任意位置
- **常驻浮层**：右侧半透明小圆角框，单行「标签: 值」排版，无标题
- 显示五项：**编码 / 分辨率 / 帧率 / 色彩矩阵 / 比特率**
  - 示例：`编码: hevc`、`分辨率: 3840x2160`、`帧率: 30.0`、`色彩矩阵: bt.709`、`比特率: 4.26 Mbps`
- **只有再次点击控件，或直接点击浮层本身才会关闭**；播放过程中常驻，不会随控制栏自动隐藏
- 比特率为实时值，每秒刷新，便于观察码率变化
- 数据来源（mpv 属性，与「更多 → 播放信息」同源）：

  | 显示项 | 来源 |
  |---|---|
  | 编码 / 帧率 | `video-track`（`codec` / `fps`） |
  | 分辨率 / 色彩矩阵 | `video-params`（`w`/`h` / `colormatrix`） |
  | 比特率 | `video-bitrate`（单位 bit/s） |

### 3. 播放进度自动点赞

设置 → 实验室：

- `播放到指定进度自动点赞`：总开关，默认关闭
- `自动点赞进度`：滑块 10%~100%，默认 **95%**
- `自动点赞累计观看`：滑块 10%~100%，默认 **50%**

触发规则是**双条件**：播放位置真的到达进度阈值，**并且**实际观看累计时长达标才点赞——直接把进度条拖到末尾不会误赞。同一视频只触发一次（按 `bvid_cid` 去重，切分P 重新计算）；已点赞的视频直接跳过，不会误变成「取消赞」；未登录不触发。失败时最多重试 5 次，间隔指数退避，且用单调时钟计时，改系统时间绕不过去。

### 4. 从系统分享面板接收 B 站链接

- 在 B 站 / 微信 / 浏览器里点「分享」，分享面板里可以直接选到本应用
- 冷启动与热启动都支持：冷启动时先缓存分享文本，App 起来后主动取一次（用序号去重，不会重复打开）
- 从分享文案里提取 BV 号 / av 号 / `b23.tv` 短链 / `bilibili.com` 链接后复用既有的 URL 路由，短链解析失败会提示而不是静默失败
- 原有的「用链接打开」scheme 能力一行未改

### 5. 渐变背景组件化

- 抽出共享组件 `lib/common/widgets/gradient_background.dart`（`GradientLayer` / `GradientBackground`），参数与主布局渐变一致
- 主布局改为复用同一组件，避免渐变参数在两处漂移
- 仍受「渐变背景」开关（`Pref.enableGradientBg`）控制

### 6. 弹幕显示区改为按行数

- 播放器弹幕设置里的「显示区域 %」滑块改为 **「弹幕行数」**（1~10 行，默认 4 行）
- 内部按 `行数 × 字号 × 行高倍数 ÷ 画布高度` 换算成面积比例，再交给 `canvas_danmaku`
- 画布高度在弹幕视图构建时回填，并在窗口尺寸变化时重新应用，全屏/小窗/竖屏下行数保持一致

### 7. 动态页精简

设置 → 实验室：

- **屏蔽「充电专属」视频**（默认开）：动态与转发里不再显示充电专属卡片——这类内容点开也看不了
- **UP 面板入口显示「分组」**（默认开）：关闭后首个入口改为「直播」，点击直接进入关注的直播间列表
- **隐藏「番剧」「专栏」标签**（默认关，需重启生效）：开启后动态页顶栏只保留 **全部 / 投稿 / UP**，少两次无谓的列表加载
  - 标签列表在 `DynamicsController` 创建时确定一次，保证 `TabController.length` 与 `TabBar` / `TabBarView` 项数始终一致，运行中切换不会出现长度不匹配
  - 「动态展示」的默认标签若指向被隐藏的项，会自动回退到「全部」；取消隐藏即恢复

### 8. 动态页头像筛选（原版行为）

- 动态页点头像 → **就地筛选**该 UP 的动态（头像高亮），不跳转新页面，平板/宽屏下行为与上游完全一致
- 本分支曾实现过的「UP 动态全屏页」因问题过多已**整体移除**，相关文件与设置项均已删除

### 9. 直播页吸顶的边界修复

直播页「我的关注」与分区标签的吸顶本身是上游能力（见下节），本分支在其上补了两处边界处理，改动都在 `lib/pages/live/view.dart`，用 `[FORK]` 注释标出：

- **无分区入口时**把吸顶高度归零，避免列表顶部留一条空白吸顶区
- **关注列表为空时**不渲染空的关注行，直接让分区标签吸顶

### 10. 安装包体积

- `android/app/build.gradle.kts` 增加 `packaging.jniLibs.excludes`，排除 `x86_64` / `armeabi-v7a`
- `media_kit` 的预编译 jar 会带进三份 `libmpv`（合计约 19MB），而 Flutter 的 `--target-platform` 只过滤自己产出的 `.so`，管不到 jar 里的 native 库
- 过滤后 APK 由 38.3MB 降到 **25.0MB**；代价是产物仅支持 arm64 真机，装不了 x86_64 模拟器与 32 位设备

---

## 随上游带入的功能

以下能力**不是本分支新增**，随上游 2.6.2 一并带进来，列在这里只是方便查「这个开关在哪」，细节以上游为准：

- **直播页顶部关注与分区滚动固定**：往下滚时头像行与分区标签吸顶，切换分区后自动回到列表顶部
- **全屏 SuperChat 不透明度与缩放**：设置 → 播放设置 → 全屏 SuperChat 设置，两个滑块 + 右上角「重置」，直播间醒目留言按配置应用 `Opacity` / `Transform.scale`
- **首页推荐来源可选桌面端**：设置 → 推荐设置 → 首页推荐来源，改为带说明的选择框（勾选顺序即混排顺序），新增「桌面端 / PC」档（`plat=1`、`feed_version=V1`），已保存的旧配置自动迁移
- **楼中楼评论树**、**离线缓存附带字幕与章节**、**分P / 分集 / 合集面板重做**、**专栏合集**、**桌面端进度条悬停预览**、**滚动调节音量**、**长按左方向键连续快退**、**缓存可选音质**、**评论屏蔽新增三项** 等

上游完整更新记录见 [CHANGELOG.md](CHANGELOG.md)。

## 本地构建（Windows）

> 这个工程不是 `flutter build apk` 就能直接过的，下面几步缺一不可。

1. **Flutter 版本**：`3.47.9`（Dart 3.13.7）
2. **必须打补丁**：工程把一批 Flutter 框架私有类型改成了公开（如 `StandardBottomSheet`、`TabBarState`），需先执行：

   ```powershell
   $env:FLUTTER_ROOT="<你的 flutter 目录>"
   $env:GITHUB_WORKSPACE="<项目根目录>"
   powershell -ExecutionPolicy Bypass -File .\lib\scripts\patch.ps1 -platform android
   ```

   脚本会给 Flutter SDK 与 pub 缓存里的 `material_ui` / `cupertino_ui` 应用补丁。不打会直接报 `Type 'StandardBottomSheet' not found`。

3. **依赖镜像**（国内网络）：`android/build.gradle.kts` 与 `android/settings.gradle.kts` 已加入阿里云 + 腾讯云镜像，替代不可达的 `maven.google.com` / `jitpack.io`；`gradle-wrapper.properties` 指向腾讯云镜像。
4. **Kotlin 增量编译**：`android/gradle.properties` 中已关闭（`kotlin.incremental=false`）。工程与 `GRADLE_USER_HOME` 不在同一盘符时，增量缓存会因相对路径跨盘而报错。
5. **签名**：在 `android/` 下新建 `key.properties`，并把 `pilinara.jks` 放到 `android/app/`：

   ```properties
   storeFile=pilinara.jks
   storePassword=<你的密码>
   keyAlias=<你的别名>
   keyPassword=<你的密码>
   ```

   两个文件都已被 `.gitignore` 排除，**切勿提交**。keystore 丢失后无法再发布可覆盖安装的更新。

6. **构建并注入版本号**（不修改 `pubspec.yaml`）：

   ```powershell
   $code = [int]([DateTimeOffset]::Now.ToUnixTimeSeconds() / 60)   # 分钟时间戳，单调唯一
   $ts   = [int][DateTimeOffset]::Now.ToUnixTimeSeconds()
   $hash = (git rev-parse --short HEAD)

   flutter build apk --release --target-platform android-arm64 `
     --build-name=2.2.1 --build-number=$code `
     --dart-define=pili.code=$code --dart-define=pili.name=2.2.1 `
     --dart-define=pili.hash=$hash --dart-define=pili.time=$ts
   ```

   `--build-number` 会写进 APK 的 `versionCode`，`--dart-define` 让 App 内的「关于」页显示真实版本而不是 `SNAPSHOT+1`。**这三个版本参数必须显式带上**，否则会沿用 `pubspec.yaml` 里的旧版本，打出来的包版本号与上一次相同。

   产物：`build/app/outputs/flutter-apk/app-release.apk`

7. **依赖下载**（国内网络）：若 `flutter pub get` 卡住，可先设镜像再执行：

   ```powershell
   $env:PUB_HOSTED_URL="https://pub.flutter-io.cn"
   $env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
   $env:NO_PROXY="pub.dev,pub.flutter-io.cn,storage.flutter-io.cn,localhost,127.0.0.1,::1"
   ```

8. **提交钩子**（克隆后执行一次）：

   ```powershell
   git config core.hooksPath .githooks
   ```

   本仓库是 [PiliNara](https://github.com/Starfallan/PiliNara) 的公开 fork，提交信息里写裸编号（如 `#430`）会被 GitHub 自动解析成**上游仓库**的 issue 引用，在上游 issue 的时间线里留下对所有人可见的 `referenced` 记录，且事后 `force-push` 也无法撤销。`.githooks/commit-msg` 会把 `#123` 自动改写成 `issue 123`，纯文本不会再被自动链接。

---

## 声明

- 本项目仅供个人学习和测试使用，请于下载后 24 小时内删除。
- 所用 API 均从官方渠道收集，不提供任何破解内容。
- 本项目基于 [PiliPala](https://github.com/guozhigq/pilipala) → [PiliPalaX](https://github.com/orz12/PiliPalaX) → [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) → [PiliNara](https://github.com/Starfallan/PiliNara) 一路演进而来，遵循 **GPL-3.0**，感谢原作者与上游作者的开源精神。如有侵权请联系删除。

## 致谢

- [bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect)
- [media-kit](https://github.com/media-kit/media-kit)
- [dio](https://github.com/cfug/dio)
