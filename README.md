<div align="center">
  <img width="180" src="assets/images/logo/logo.png">
  <h1>PiliNara</h1>
  <p>第三方哔哩哔哩客户端 · 自用修改版</p>
  <p>基于 <a href="https://github.com/bggRGjQaUbCoE/PiliPlus">PiliPlus</a> / <a href="https://github.com/Starfallan/PiliNara">PiliNara</a></p>
</div>

---

## 我做了什么

本仓库在上游基础上只做了下面这些改动，上游原有功能见 [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)。

### 1. 播放进度自动点赞

设置 → 播放设置：

- `播放到指定进度自动点赞`：总开关，默认关闭
- `自动点赞进度`：滑块 10%~100%，默认 **95%**

触发规则：进度达到阈值时自动点赞；同一视频只触发一次（按 `bvid_cid` 去重，切分P 重新计算）；已点赞的视频直接跳过，不会误变成「取消赞」；未登录不触发。

### 2. 播放信息侧栏

- 位置：全屏播放器底部操作栏，**「缓存」与「分享」之间**，图标为 ⓘ
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

### 3. 渐变背景组件化

- 抽出共享组件 `lib/common/widgets/gradient_background.dart`（`GradientLayer` / `GradientBackground`），参数与主布局渐变一致
- 主布局改为复用同一组件，避免渐变参数在两处漂移
- 仍受「渐变背景」开关（`Pref.enableGradientBg`）控制

### 4. 弹幕显示区改为按行数

- 弹幕设置里的「显示区域 %」滑块改为 **「弹幕行数」**（1~10 行，默认 4 行）
- 内部按 `行数 × 字号 × 行高倍数 ÷ 画布高度` 换算成面积比例，再交给 `canvas_danmaku`
- 画布高度在弹幕视图构建时回填，并在窗口尺寸变化时重新应用，全屏/小窗/竖屏下行数保持一致

### 5. 动态页头像筛选（原版行为）

- 动态页点头像 → **就地筛选**该 UP 的动态（头像高亮），不跳转新页面，平板/宽屏下行为与上游完全一致
- 本分支曾实现过的「UP 动态全屏页」因问题过多已**整体移除**，相关文件与设置项均已删除

### 6. 动态页标签精简

- 设置 → 动态设置 → **「隐藏『番剧』『专栏』标签」**（默认关，需重启生效）
- 开启后动态页顶栏只保留 **全部 / 投稿 / UP**，少两次无谓的列表加载
- 标签列表在 `DynamicsController` 创建时确定一次，保证 `TabController.length` 与 `TabBar` / `TabBarView` 项数始终一致，运行中切换不会出现长度不匹配
- 「动态展示」的默认标签若指向被隐藏的项，会自动回退到「全部」；取消隐藏即恢复

### 7. 安装包体积

- `android/app/build.gradle.kts` 增加 `packaging.jniLibs.excludes`，排除 `x86_64` / `armeabi-v7a`
- `media_kit` 的预编译 jar 会带进三份 `libmpv`（合计约 19MB），而 Flutter 的 `--target-platform` 只过滤自己产出的 `.so`，管不到 jar 里的 native 库
- 过滤后 APK 由 38.3MB 降到 **25.0MB**；代价是产物仅支持 arm64 真机，装不了 x86_64 模拟器与 32 位设备

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
     --build-name=2.1.6 --build-number=$code `
     --dart-define=pili.code=$code --dart-define=pili.name=2.1.6 `
     --dart-define=pili.hash=$hash --dart-define=pili.time=$ts
   ```

   `--build-number` 会写进 APK 的 `versionCode`，`--dart-define` 让 App 内的「关于」页显示真实版本而不是 `SNAPSHOT+1`。

   产物：`build/app/outputs/flutter-apk/app-release.apk`

---

## 声明

- 本项目仅供个人学习和测试使用，请于下载后 24 小时内删除。
- 所用 API 均从官方渠道收集，不提供任何破解内容。
- 本项目基于 [PiliPala](https://github.com/guozhigq/pilipala) → [PiliPalaX](https://github.com/orz12/PiliPalaX) → [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) → [PiliNara](https://github.com/Starfallan/PiliNara) 一路演进而来，遵循 **GPL-3.0**，感谢原作者与上游作者的开源精神。如有侵权请联系删除。

## 致谢

- [bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect)
- [media-kit](https://github.com/media-kit/media-kit)
- [dio](https://github.com/cfug/dio)
