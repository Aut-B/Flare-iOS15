# iOS 15 第三轮修复清单（flare-r3）

本文件由 dot 任务 `flare-r3` 的 L4 批次生成，汇总 build 101 之后第三轮的代码改动、
尚未验证的项目、真机验证步骤，以及当前分支相对远端 `ios15-build` 的差异文件。

## 分支与基线

- 分支：`fix/startup-crash`
- 当前 HEAD：`cdd8138ef`（L9）
- 对比基线：`origin/ios15-build` = `3aed20e14`
- 差异规模：54 个提交、86 个文件、+3706 / -584
- 远端基线停在 B1 之前，因此本清单同时包含 B1–B6、R1–R6 和本轮 L1–L9 的改动；
  本文件的“按批改动”只展开第三轮 L1–L9。

## 自检结论

- 78 个改动的 Swift/Kotlin 文件全部通过括号、字符串、注释配平扫描（78/78 `balanced`）。
- `git diff --check` 退出码 0，无输出。
- 本机没有 Xcode、`swiftc` 和可用的 Kotlin 编译环境，**未做本地编译**；
  是否能编译、能否启动由 CI smoke 与真机安装验证。
- 本轮没有执行 `git add` / `git commit` / `git push`，改动留在工作区由监督器统一提交。

## 改动一览

| 批次 | 主题 | 主要文件 | 结论 |
|---|---|---|---|
| L1 | Instagram 点赞/取消点赞 | `InstagramService.swift`、`InstagramStore.swift`、`InstagramExtras.swift`、`InstagramPostView.swift`、`InstagramFeedView.swift` | 代码完成，待真机 |
| L2 | 微博 IP 属地、可见范围、写链路复核 | `VVO.kt`、`VVOService.kt`、`VVODataSource.kt`、`StatusView.swift`、`StatusUIKitLeaves.swift`、`UiTimelineV2.kt` | 代码完成，待真机 |
| L3 | 15PM 启动崩溃证据链 | `LaunchCrashTrace.swift`、`docs/ios15-crash-trace.md` | 代码完成，待 `.ips` |
| L4 | 集成自检与出包准备 | `docs/ios15-round3-followup.md`（本文件） | 完成 |
| L5 | 时间线滚动/高度校正 | `CollectionViewTimeline.swift` | 代码完成，待 Instruments |
| L6 | 图片查看器退不出 | `MediaViewerScreen.swift` | 代码完成，待真机 |
| L7 | 视频低码流与完整播放 | `VVO.kt`、`XhsModels.swift`、`InstagramModels.swift` | 代码完成，待真机 |
| L8 | WebSocial 登录态持久化 | `XhsStore.swift`、`LaunchGuard.swift` | 代码完成，待真机 |
| L9 | 隐藏 WebView 内存与存活 | `WebPageHarvester.swift`、`XhsSigner.swift`、`XhsStore.swift`、`WereadStore.swift` | 代码完成，待 6S |

## L1 · Instagram 点赞实现

- `InstagramService.like(mediaId:)` / `unlike(mediaId:)` 发 `POST
  https://www.instagram.com/api/v1/web/likes/{pk}/like/` 与 `.../unlike/`，
  表单体 `media_id=<pk>`；复用现有 Cookie、`X-CSRFToken`、桌面 UA、
  `X-IG-App-ID`、`X-ASBD-ID`、`X-Instagram-AJAX`、`Referer/Origin`。
- `InstagramStore` 新增 `IGLikeState`、`likeOverrides`、`likeState(for:)`、
  `likePost`/`unlikePost`：先乐观更新，失败回滚并写日志；同一帖子 in-flight 去重；
  刷新和退出登录时清空覆盖状态。
- `InstagramExtras.IGLikeButton` 改为观察 Store，失败弹 toast；
  `InstagramPostView` 的点赞数改读 Store，时间线与详情共用同一状态。
- `media.id` 是 `<pk>_<user pk>` 复合串，请求与状态键统一取 `_` 前的数字 `pk`。

## L2 · 微博 IP 属地、可见范围、写链路复核

- `UiTimelineV2.Post` 新增 `ipLocation`，并纳入 `renderHash` / `renderSummaryHash`，
  内容变化能触发列表刷新。
- 帖子取 `region_name`，评论取 `source`，去掉“发布于 / 来自 / IP属地：”等前缀，
  只显示地名；评论里的“客户端 / 微博 / 网页”不当地名展示。
- SwiftUI 的 `StatusView` 在右上角平台图标下方显示属地；UIKit 新增
  `PlatformIpColumnView`，平台图标可关闭时属地仍单独显示。
- 可见范围补齐第四项 `Followers`（微博 `10`）；原 `1` 为仅自己、`6` 为好友。
- 写链路复核结论：`ensureWriteLogin()` → `refreshCredentialForWrite()`（2 分钟内复用）
  → `requireOk()` 已存在，转发失败不会再当成功；本批只把续签重定向链改成
  单 `HttpClient` 复用并在结束后关闭，避免每次续签泄漏客户端。
- Swift 侧 `DefaultArgumentInterop` 关闭，构造器没有默认参数；已手工补齐
  `ipLocation: nil` 的 5 处调用与测试 fixture。

## L3 · 启动崩溃证据链

- `LaunchCrashTrace.install()` 重排为：先读上次现场、建目录、打开
  `crash.log` / `stage.log`、写首行 `image-base`、预热信号路径常量，
  最后才装 `NSSetUncaughtExceptionHandler` 与 `sigaction`。
- 信号处理改为对 6 个 fatal signal 的固定 `switch`，直接调用预烘表
  `write(0...5)`，不在信号上下文遍历 Swift 数组。
- 预热列表补充 `SIG_DFL`、`STDERR_FILENO`、`F_GETFL`、`O_APPEND`、`SEEK_END`。
- `FlareApp` 的启动阶段打点、主界面 `crashes>=1` 横幅、进后台收横幅已存在，
  本批核对后未重复改；`Documents/flare-launch` 与 `isExcludedFromBackup`
  也由现有实现覆盖。
- 取日志、读 `stage=`、用 `atos -l <image-base>` 还原信号栈的完整说明见
  `docs/ios15-crash-trace.md`。

## L5 · 时间线滚动与高度校正

- `flushPendingHeightCorrections()` 入口恢复
  `isHeightCorrectionFlushScheduled = false`。缺这一行时标志首次刷新后永真，
  后续高度校正不再调度。
- 滚动期间仍通过 `isDragging` / `isDecelerating` 推迟整表重排；
  图片降采样已是按实际像素尺寸，未回退到旧的固定 800pt 写法。
- 下游刷新、并发时间线、批量稀疏缓存等上游优化确认已存在，本批未重复实现。

## L6 · 图片查看器

- `topOverlayButton` 的 44pt 命中区从 Button 外层移进 Button label，
  点左上角图标外、44pt 区域内也能关闭。
- 保留 build31 的 `.allowsHitTesting(false)` 手势宿主；
  未恢复 build30 的 `isUserInteractionEnabled=false` / `hitTest(nil)` hack。
- 当前同时识别只放开 chrome tap + tap；下滑关闭回归未能离线定位，真机步骤见下。

## L7 · 视频码流

- 微博 `page_info`：`mp4_ld_mp4 ?: mp4_720p_mp4 ?: mp4_hd_mp4 ?: stream_url ?: stream_url_hd`，
  标清优先，缺档逐级回退，MP4 全缺才走流式。
- 小红书：保持 `h264 -> h265 -> av1` 编码顺序；同一编码内优先短边 ≤720 的最大档，
  全大于 720 才取最小档；渐进式 MP4 优先于 `.m3u8/.mpd`。
- Instagram：`video_versions` 从“取最宽”改为短边 ≤720 的最大档，
  全更大才取最小档；渐进式优先于 HLS。
- 小红书首页 DOM 抓取路径 `XhsStore.videoOf` 仍取首条，未在本批 scope 内。

## L8 · WebSocial 登录态持久化

- 小红书冷启动根因：`XhsStore.init` 只给 `XhsService` 灌 cookie，没给
  `XhsSigner`；签名页匿名请求 `homefeed` 得到 `-100` 后触发 `logout()` 删除登录态。
  现在 `refresh()` 在 `warmUp()` 前调用 `XhsSigner.shared.applyCookies(cookie)`，
  该 API 自带“cookie 未变不重载”的幂等保护。
- 微信读书根因：`LaunchGuard.begin()` 在连续两次未完成启动时无条件
  `clearWereadLocalState()`。恢复模式不再自动清 WeRead；
  `FlareApp` 恢复界面的「清掉微信读书登录」手动入口保留。
- Instagram 隔离仍只按 `instagram.com` / `cdninstagram.com` / `facebook.com`
  过滤网站数据与 cookie，不会误删微信读书和小红书；单次脏启动只进安全模式。

## L9 · 隐藏 WebView 内存与存活

- 新增 `HiddenWebViewSlot` / `HiddenWebViewOwner`：所有隐藏页创建前 `take`，
  旧的同步 `teardownNow()`，任一时刻最多一个 WebContent 进程。
- `WebPageHarvester`：新建前同步拆旧页；60 秒空闲回收；内存警告立即 `stop()`；
  旧页面回调加 `self.webView === view` 守卫，避免拆掉的页面回写状态。
- `XhsSigner`：接入互斥槽；新增 `stop(reason:)`（只拆页面、保留 `cookieHeader`，
  下次重建重灌）；60 秒空闲、无请求时内存警告回收；`activeRequests`
  防止请求中被空闲回收。
- `XhsStore.refresh()`：先停旧抓取页；不再并行 `warmUp()` + `startHarvester()`，
  改为先走 `homefeed` 接口，失败且无数据才启动 DOM 抓取兜底。
- `WereadStore`：书架页 `onFail` 调 `finishHarvest`，打不开时不再继续养 WebView。

## 仍未验证的项目

| 项目 | 当前状态 | 需要的证据 |
|---|---|---|
| CI 编译 | 未本地编译 | push 后 smoke / logic test / IPA 全绿 |
| 15PM 冷启动崩溃 | 只有代码层加固与自写现场 | 复现后的 `JetsamEvent-*.ips` 或 `Flare-*.ips`，以及 `crash.log` / `stage.log` |
| Instagram 点赞 | 未真机、未带真实 cookie | 真机点赞/取消、杀掉重开、失败回滚、不踢登录 |
| 微博转发/可见范围 | 未真机；写失败处理来自 B4，L2 只复核并修续签泄漏 | 转发成功与 `ok=0` 失败路径、四项可见范围、IP 属地位置 |
| 三平台登录保持 | 未真机 | 6S 连续 3 次冷启动免登 |
| 视频完整性 | 未真机 | 微博 `page_info`、小红书详情、IG 均能完整播放 |
| 图片查看器关闭 | 未真机 | 44pt 任意位置可关、下滑关闭未退化 |
| 时间线流畅度 | 未真机 | Instruments 帧率与掉帧对比 |
| 6S 内存峰值 | 未真机 | Instruments 中隐藏 WebContent 进程数 ≤1，静置 60 秒释放 |

`.ips` 仍然不可替代：自写日志覆盖未捕获 `NSException` 和信号崩溃，
覆盖不到 watchdog、jetsam、dyld 以及 `main` 之前的崩溃。

## 真机验证步骤

1. **15PM 启动崩溃**
   - 从 CI 产物安装同一构建，保留 Console。
   - 冷启动、强杀、再冷启动，至少重复 5 次；每次记录是否进恢复页、横幅是否出现。
   - 若崩溃：设置 → 隐私与安全性 → 分析与改进 → 分析数据，取同一时间的
     `Flare-*.ips`；同时从“文件”App → 我的 iPhone → Flare → `flare-launch/`
     取 `crash.log`、`stage.log`。
   - 用 `crash.log` 首行 `image-base` 做 `atos -o Flare.app/Flare -l <base> <地址>`；
     把 `.ips` 的 `faultingThread`、`stage=` 和栈顶几帧一起回传。

2. **Instagram 点赞**
   - 登录 IG，首页与详情分别点爱心：图标立即变红、数字 ±1。
   - 再点一次取消，数字恢复；强杀重开、下拉刷新后由服务端状态确认。
   - 用受限网络或连续快速点击触发风控：应 toast 并回滚，不应踢回登录页。
   - 若返回 `feedback_required`，记录为 IG 风控，不是路径错误。

3. **微博 IP 属地与可见范围**
   - 首页、详情、评论分别检查属地：位置在右上角平台图标下方，只显示地名。
   - 发原创与转发各选公开、好友、仅自己、粉丝可见四种范围，
     确认发布后回显与设置一致。
   - 普通转发、转发自己的帖子、转发别人的转发、带图转发各一次；
     人为制造失败时界面必须显示服务端 `msg`，不能假成功。

4. **三平台登录保持**
   - 微信读书、小红书、Instagram 分别登录成功且无登录弹层。
   - 按 Home 让 App 进后台（触发 `markStable()`），再上滑强杀；不要删 App。
   - 重开应直接出书架、小红书首页、IG 时间线；连续 3 次冷启动。
   - 若仍掉登录：记录是否进恢复页，Console 查 WeRead `-2012`、XHS `-100`、
     IG `notLoggedIn`，并保留三把 UserDefaults cookie key。

5. **6S 视频**
   - 微博 `page_info` 视频、小红书详情视频、IG 视频各测一条。
   - 冷启动或清缓存后记录首帧时间、是否卡住、是否只播开头、能否播完。
   - 记录实际选中的 URL 档位；若小红书首页 DOM 路径仍取首条，注明是首页还是详情。

6. **6S 图片查看器**
   - 时间线点开图片进全屏；点左上角 44pt 区域的左侧、下侧（避开 X 图标）应退出。
   - 点图片中部切换顶/底栏，再横滑翻页、捏合缩放、点按隐藏。
   - 未缩放时从 0.65 下滑到 0.08 应退出；高图、放大后图片、单图/多图分别重复。

7. **6S 滚动**
   - 首页、帖子详情、评论区长列表快速滚动，观察是否整表跳动或掉帧。
   - 用 Instruments 的 Core Animation / Time Profiler 对比滚动帧率与主线程占用。

8. **6S 内存**
   - Instruments → Allocations / VM Tracker，过滤 `com.apple.WebKit.WebContent`。
   - 路径：冷启动进小红书首页 → 开笔记/评论返回 → 连续下拉刷新 10 次 →
     切「关注」→ 进微信读书同步线上书架 → 回小红书；每步记录进程数与 RSS。
   - 静置 >60 秒确认 WebContent 退出；再用 Simulate Memory Warning 或真机内存压力
     确认页面立即释放。
   - 后台/前台反复切换、长时间浏览后取新的 `JetsamEvent-*.ips`，对比 free 与 footprint。

## 出包步骤

1. 监督器复核本文件与工作区 diff，确认只有文档新增；按批次独立提交已在历史中。
2. 提交本文件后，把 `fix/startup-crash` 推到 `ios15-build`：
   `git push origin fix/startup-crash:ios15-build`。
3. push 会自动触发 `.github/workflows/build-ios15.yml`：
   `smoke`（模拟器安装启动）通过后才跑 `ipa`。
4. 下载产物 `Flare-iOS15-ipa-build<run_number>`；固定地址为
   `https://github.com/<repo>/releases/download/ios15-latest/Flare-iOS15.ipa`。
5. smoke 失败时先看 Action 里的 `smoke-build<run_number>` 与自动开的 issue；
   IPA job 只有 smoke 成功才会执行。
6. 记录本次 `run_number`、`github.sha` 和 smoke 结果，和真机反馈一起归档。

## 回滚

- 每个批次是独立提交：L1 `c089f4128`、L2 `171bf380f`、L3 `3baf82563`、
  L5 `cad656129`、L6 `180e6b3e0`、L7 `7dc61aeb1`、L8 `86ba9651a`、
  L9 `cdd8138ef`。
- 需要单独回退时用 `git revert <sha>`；不要回退 L5 的高度校正复位、
  L8 的 XHS cookie 注入和 L9 的隐藏页互斥，否则对应问题会复发。

## 附录 A · 相对 origin/ios15-build 的差异文件

以下为生成本文件前 `git diff --name-status origin/ios15-build...HEAD` 的结果，
共 86 个文件；本文件自身提交后会再多 1 个。`A` 为新增，`M` 为修改。

```text
M .github/workflows/build-ios15.yml
M .gitignore
M appleApp/Shared/FlareAppleCore/Sources/FlareAppleCore/ProxySessionConfigurator.swift
M appleApp/Shared/FlareAppleCore/Sources/FlareAppleCore/WebViewDirectProxy.swift
M appleApp/Shared/FlareAppleCore/Sources/FlareAppleCore/WebViewProxy.swift
M appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/ComposeActionBarContent.swift
M appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/DiscoverContentScreen.swift
M appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/EditRssSheet.swift
M appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/FlareTextColors.swift
A appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/FormStyleCompat.swift
M appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/IOS15LayoutCompat.swift
M appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/LocalHistoryContentScreen.swift
M appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/NetworkImage.swift
M appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/NetworkImageView.swift
M appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/PluginManagementView.swift
M appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/ProxyMarkdownImageLoader.swift
M appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/ProxySettingsView.swift
M appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/SearchScreen.swift
M appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/ShareImageLoading.swift
M appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/StatusActionAnimationState.swift
A appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/TextBackgroundCompat.swift
M appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/TimelineItem/StatusActionView.swift
M appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/TimelineItem/StatusMediaView.swift
M appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/TimelineItem/StatusView.swift
M appleApp/ios/Debug/MediaViewerTestFixture.swift
M appleApp/ios/Debug/TimelineTestData.swift
M appleApp/ios/FlareApp.swift
M appleApp/ios/Info.plist
M appleApp/ios/UI/Component/AdaptiveTimelineCardUIView.swift
M appleApp/ios/UI/Component/CollectionViewTimeline.swift
M appleApp/ios/UI/Component/DMConversationMessagesView.swift
M appleApp/ios/UI/Component/GalleryTimelinePagingView.swift
M appleApp/ios/UI/Component/Status/RichTextUIView.swift
M appleApp/ios/UI/Component/Status/StatusUIKitActions.swift
M appleApp/ios/UI/Component/Status/StatusUIKitLeaves.swift
M appleApp/ios/UI/Component/Status/StatusUIKitMedia.swift
M appleApp/ios/UI/Component/Status/StatusUIKitPoll.swift
M appleApp/ios/UI/Component/Status/StatusUIKitReactions.swift
M appleApp/ios/UI/Component/Status/StatusUIKitView.swift
M appleApp/ios/UI/Feature/WebSocial/Instagram/InstagramExtras.swift
M appleApp/ios/UI/Feature/WebSocial/Instagram/InstagramFeedView.swift
M appleApp/ios/UI/Feature/WebSocial/Instagram/InstagramModels.swift
M appleApp/ios/UI/Feature/WebSocial/Instagram/InstagramPostView.swift
M appleApp/ios/UI/Feature/WebSocial/Instagram/InstagramService.swift
M appleApp/ios/UI/Feature/WebSocial/Instagram/InstagramStateIsolator.swift
M appleApp/ios/UI/Feature/WebSocial/Instagram/InstagramStore.swift
A appleApp/ios/UI/Feature/WebSocial/LaunchCrashTrace.swift
M appleApp/ios/UI/Feature/WebSocial/LaunchGuard.swift
M appleApp/ios/UI/Feature/WebSocial/WebPageHarvester.swift
M appleApp/ios/UI/Feature/WebSocial/Xiaohongshu/XhsModels.swift
M appleApp/ios/UI/Feature/WebSocial/Xiaohongshu/XhsNoteView.swift
A appleApp/ios/UI/Feature/WebSocial/Xiaohongshu/XhsQuery.swift
M appleApp/ios/UI/Feature/WebSocial/Xiaohongshu/XhsService.swift
M appleApp/ios/UI/Feature/WebSocial/Xiaohongshu/XhsSigner.swift
M appleApp/ios/UI/Feature/WebSocial/Xiaohongshu/XhsStore.swift
M appleApp/ios/UI/Feature/Weread/WereadCrypto.swift
M appleApp/ios/UI/Feature/Weread/WereadModels.swift
M appleApp/ios/UI/Feature/Weread/WereadNativeReaderView.swift
A appleApp/ios/UI/Feature/Weread/WereadReaderSession.swift
M appleApp/ios/UI/Feature/Weread/WereadReaderView.swift
M appleApp/ios/UI/Feature/Weread/WereadService.swift
M appleApp/ios/UI/Feature/Weread/WereadStore.swift
M appleApp/ios/UI/Screen/BackportWebLoginScreen.swift
M appleApp/ios/UI/Screen/HomeTimelineScreen.swift
M appleApp/ios/UI/Screen/MediaViewerScreen.swift
M appleApp/ios/UI/Screen/ProfileScreen.swift
M appleApp/iosControllerTests/StatusShareTests.swift
M appleApp/iosControllerTests/TimelineMediaPreviewTests.swift
M appleApp/iosControllerTests/TimelineRefreshAnimationTests.swift
A appleApp/iosTestsLogic/InstagramMediaParsingTests.swift
M appleApp/iosTestsLogic/InstagramStateIsolatorTests.swift
M appleApp/iosTestsLogic/XhsModelParsingTests.swift
A appleApp/iosTestsLogic/XhsQueryEncodingTests.swift
M appleApp/project.yml
A docs/ios15-build101-followup.md
A docs/ios15-crash-trace.md
A docs/ios15-round2-followup.md
A docs/ios15-startup-crash-notes.md
M shared/src/commonMain/kotlin/dev/dimension/flare/ui/model/UiTimelineV2.kt
M social/vvo/src/commonMain/kotlin/dev/dimension/flare/data/datasource/vvo/VVODataSource.kt
M social/vvo/src/commonMain/kotlin/dev/dimension/flare/data/network/vvo/VVOService.kt
M social/vvo/src/commonMain/kotlin/dev/dimension/flare/ui/model/mapper/VVO.kt
A social/vvo/src/commonTest/kotlin/dev/dimension/flare/data/datasource/vvo/VVOWriteResponseTest.kt
M social/vvo/src/commonTest/kotlin/dev/dimension/flare/data/network/vvo/VVOComposeVisibilityTest.kt
M social/vvo/src/commonTest/kotlin/dev/dimension/flare/ui/model/mapper/VVORenderTest.kt
M social/weread/src/commonMain/kotlin/dev/dimension/flare/data/network/weread/WeReadAccountBridge.kt
```
