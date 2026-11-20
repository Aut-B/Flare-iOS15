# iOS 15 第四轮修复清单（flare-r4）

本文件由 dot 任务 `flare-r4` 的 D1 批次生成，汇总 build 107 之后第四轮
（r4）的改动、逐条状态、真机验证步骤、15PM lite 构建方法，以及当前分支
相对远端 `ios15-build` 的差异文件清单。

## 分支与基线

- 分支：`fix/startup-crash`
- 当前 HEAD：`520c8c395`（V1，r4 最后一批）
- 对比基线：`origin/ios15-build` = `3aed20e14`
- 全量差异：73 个提交、101 个文件、+7190 / -1227（生成本文件前）
- r4 差异：`d01115049..520c8c395`，16 个提交、40 个文件、+3549 / -1025
- 远端基线停在 r4 之前，因此全量清单同时包含 r3 及更早的改动；
  本文件逐条状态只展开 r4 的 16 个批次。本文件提交后全量文件数变为 102。

## 自检结论与限额

- 39 个 r4 改动的 Swift/Kotlin 文件全部通过括号、字符串、注释配平扫描，
  结果为 39/39 `balanced`，退出码 0。
- `git diff --check` 退出码 0，无输出。
- 本机是 Windows，没有 Xcode、`swift` / `swiftc` / `xcodebuild` 和 iOS SDK，
  **未做本地编译，也未运行 iOSTests / LogicTests**；能否编译、能否启动以 CI
  与真机为准。本文所有“已改”只表示代码可证，不表示已验证修好。
- 本批没有执行 `git add` / `git commit` / `git push`；文档与 handoff 留在
  工作区，由监督器统一提交。

## 逐条状态

状态口径：

- **已改**：能在当前 HEAD 找到对应代码，且改法针对已定位的根因。
- **需 6S**：必须由用户在 6S（iOS 15）真机确认行为，当前没有设备证据。
- **存疑/受阻**：代码层已知的边界、服务端限制或本批未覆盖项。

| 批次 | 问题 | 已改（代码可证） | 需 6S 真机验证 | 仍存疑/受阻 |
|---|---|---|---|---|
| X1 | 详情多图第二张灰、不能左滑、只显示 2 张 | `imageList` 兼容 `image_list`/`imageList`/`images` 与字符串元素；详情/卡片图并集；`TabView(.page)` 分页；图片超时、四级回退与重试 | 首页/用户主页/搜索各进一条多图笔记，逐张左滑；第二张非灰、>2 张完整、分页点可见 | 详情只回 1 图时仍只能看到卡片已有图；未按来源择优；TabView-in-ScrollView 横滑需真机确认 |
| X2 | 首页仍模糊/碎图 | `imageToken`、`originalImageURL`、`strippedImageURL`、清晰度打分；按原图→`ci` 1440→去后缀→展示图回退，单请求 12s，缓存 resolved URL | 首页、用户主页、搜索各看多条，确认块状碎图变清晰；观察首屏耗时 | `sns-img-bd`/`ci` 映射未联网逐条验证；DOM 源头仍优先 `urlDefault`（范围外）；串行回退可能增加延迟 |
| X3 | 评论打不开、两小时后重登 | `xsec_source` 非空即独立发送；空 token 也可用新来源重试；401/`-100` 用当前 cookie 重灌并等 2s 重试一次；`300013` reset 带 cookie | 首页/用户主页/搜索进详情看评论；冷启动、放置 2 小时、切后台回前台不重登 | 服务端 `-1`/`461` 风控客户端无法绕过；“空 token + 来源”是否被服务端接受未真机验证 |
| I1 | 点赞不生效、看不了评论、无自动翻译 | `setLiked` 走网页版 like/unlike；2xx 空 body 按成功；`mediaID` 统一去后缀；详情与评论并发；评论重试；`IGCaptionView` 自动翻译 | 点赞/取消后杀进程重进确认服务端状态；两处进详情看评论；翻译开启/关闭；图片速度 | `feedback_required` 属服务端风控；翻译依赖已配置 AI provider；IG 无低清占位；互操作类型需 CI |
| I2 | IG 无主 tab、视频不能全屏/无声 | 两个 Root 按登录态追加 IG 主 tab；`IGVideoAudioController` 按播放态 begin/end；全屏 `AVPlayerViewController` | 登录后杀进程重进出现 tab、退出后消失；后台音乐与静音拨片；全屏进出 | `beginPlayback` 不 `setActive`，依赖启动会话；autoPlay 会与后台音乐混音；全屏 present 仍是启发式；iPad 常规宽度不显示 tab |
| W1 | 书架书取不到本章正文 | `content` 先走信标，再走 legacy 直连，必要时重抓阅读器页面；保留旧版固定 `pc` | epub/txt 各一本，首章出正文；连续翻 2–3 章（含预取）不反复报错 | `sc=1`/`prevChapter=false` 是否被签名集接受未知；失败路径最坏 3 次正文 + 2 次抓页，较慢；错误文案可能与真实原因不符 |
| P1 | 15PM lite 去掉小红书/微信读书 | `Info.plist` 注入 `FlarePhoneLite`；`FlareBuildVariant.isPhoneLite` 只认 `YES`/`true`；设置入口、账号 tab、iPad 侧栏、路由占位均过滤 | 出 lite 包确认只留 IG；同一构建开关不传时 6S 普通包行为不变 | 未实际 archive；账号管理仍可能看到 XHS/WeRead 账号；占位文案是英文；CI 目前没有 lite job |
| N1 | 点用户名进个人主页 | IG 作者目标 sheet、主页 grid 归一化与分页；XHS 卡片/详情作者点击，无 id 时先拉详情再开主页，失败有提示 | IG feed/详情作者→主页→滑到底翻页；XHS 详情无 id、仅头像卡片 | XHS 最坏约 20s（6 候选×8s）；服务端始终不回 `user_id` 时只能提示失败；`.sheet` 层级未改 |
| M1 | 微博自加 IP/可见范围与写链路 | 删除时间线/详情自加 IP 展示；删除“改可见范围”菜单；VVO 写/转发回官方 1.8.0；字段保留但不展示 | 转发不再提示“转发频繁”；平台图标开/关都不显示 IP；发帖只有 Public/Friends/SelfOnly；置顶/编辑/删除正常 | 官方 1.8.0 的 `authorSubtitleInternal = regionName ?: source` 仍可能在作者行显示地区；按“回退官方”未删 |
| S1 | 左上角按钮进不了设置 | 左上角改为 `Button`，只让视觉内容不参与命中测试；`Router.pendingRoute` + sheet `onDismiss` 后 `flushPendingRoute` | 点左上角头像/齿轮弹菜单；点“设置”能进；返回正常；无标签空态也能弹 | iOS 15 的 `onDismiss` 时序未真机；CI 若报 `@MainActor` 闭包隔离需复查 `Router.swift` |
| LG1 | IG/小红书重进要求重登 | IG 冷启动从 HTTP/WK 恢复会话并校验；`loggedOut` 保持主动退出；XHS 恢复后 `selfProfile()` 校验再 adopt；每请求注入 cookie | IG、XHS 分别杀进程冷启动 2 次；XHS 后台约 2 小时重进；`--seed-corrupt-instagram` 二次启动 | IG 只拼 `instagram.com` 域，`graph.facebook.com` 可能漏捡；XHS 每进程只恢复一次；旧的游客 `xhs.cookie` 可能先报 `-100` |
| L1 | 6S 卡顿与加载慢 | 评论/详情来源并发、详情 5 分钟 LRU + 预热；图片后台降采样；`merge` 只补卡片不追加陌生笔记；滚动可见性 150ms 节流 | 冷启动首刷 vs 二次刷新；进帖子 <5s、5 秒内重进秒开；评论首屏；连滑 30s；作者主页返回不追加 | 落败请求仍可能 reload 共享 WK 打断赢家；缓存内点赞/评论数 5 分钟内可能过期；TaskGroup/MainActor 需 CI |
| L2 | 图片查看器退不出 | IG/XHS viewer 增加 `onClose`、左上 44pt 关闭、未缩放下滑关闭与缩放门控；MediaViewer chrome 隐藏时任意点按恢复 | IG 帖子/Feed、XHS 单图/多图、原生 MediaViewer 单图/多图/长图；左上、下滑、横滑、捏合、存图 | iOS 15 上 `simultaneousGesture` 与 TabView 横滑优先级未真机；120/180pt 阈值需体感；长图未到顶下滑不关闭 |
| V1 | 6S 视频只播小半段、需低清、无声 | `VideoPlaybackQuality` 对 ≤2GB 设备设 1.2Mbps/960×960 上限；等待缓冲起播，去掉 `playImmediately`；暂停/detach 恢复 `.ambient`；IG 工厂同策略 | IG feed/详情视频完整播放/循环/暂停/拖动；静音拨片开/关；后台音乐恢复；记录 HLS/渐进与档位 | 码率上限主要约束 HLS，渐进 MP4 仍靠 r3 模型选流；未覆盖 XHS `XhsNoteView` 裸 `AVPlayer`；detach 500ms 交接可能短暂冻结 |
| R1 | 微信读书选文段做笔记/写想法 | WK 文本选择 `.character` + `isTextInteractionEnabled`；`#wr-content *` 全树放开选择并清内联锁；工具条不再 `preventDefault`；隐藏时机改为无选区且无暂存 range | 普通段落长按可拖选；选区上方“划线/想法”可点；高亮/想法能保存；已有高亮仍可操作；不能一拖整章 | 根因基于章节样式推断；iframe/shadow DOM 承载正文的章节覆盖不到 |
| LG2 | 微信读书重进要求重登 | 续期结果分型（renewed/unchanged/rejected/transient）；generation 原子提交/注销；续期合并与恢复串行化；HTTP/WK 全候选恢复；换会话失效旧 `psvts` | 杀进程冷启动；静置 >2 小时；断网只提示“暂时无法确认”且不清 cookie；主动退出后保持未登录；并发翻章/prefetch 不误注销 | 无编译器验证；`LaunchGuard.clearWereadLocalState()` 未清 `weread.loggedOut`（范围外）可能捡回一次旧会话；`succ=1` 但需跳页续期会判 unchanged |

## 关键改动与代码证据

### 小红书

- X1：`XhsJSON.imageList` 合并三套键名并兼容字符串；`XhsNoteView` 用
  `TabView(selection:)` + `.tabViewStyle(.page)`，详情图与卡片图取并集；
  `XhsFeedView` 对图片请求加 15s/30s 超时、四级回退和最多 2 次重试。
- X2：`XhsModels` 新增 `imageToken` / `originalImageURL` /
  `strippedImageURL`，并按 `urlRaw`、`url`、`url_default`、`url_pre`
  的清晰度打分；`XhsFeedView` 按“原图→1440 大图→去后缀→展示图”加载，
  成功后同时缓存原始 key 与实际 URL。
- X3：`XhsService.note()` 将非空 `xsec_source` 独立发送；`XhsStore.comments()`
  在 token 或来源变化时重试（包括 token 被清空）；401/`-100` 先用当前
  cookie `XhsSigner.reset(cookie:)` 并等 2 秒重试一次。

### Instagram

- I1：`InstagramService.setLiked` 发网页版 like/unlike，2xx 空 body 返回成功；
  媒体/点赞/评论共用 `mediaID`；`InstagramPostView` 详情与评论并发；
  `IGCaptionView` 复用 `TranslatePresenter`，支持预翻译与手动翻译。
- I2：`FlareRoot` 与 `BackportFlareRoot` 在登录后追加 IG 主 tab；
  `IGVideoAudioController` 订阅 `timeControlStatus`，播放时
  `beginPlayback()`，暂停/离场/全屏交接时 `endPlayback()`；全屏使用
  `AVPlayerViewController`。
- N1：`IGProfileTarget` 驱动作者主页 sheet；`InstagramService` 归一化
  profile grid 并支持分页；XHS 无作者 id 时先解析详情再打开主页。
- LG1：IG 从 HTTP/WK 共享仓库恢复会话，`loggedOut` 阻止自动复活；
  XHS 冷启动恢复后用 `selfProfile()` 校验，每个请求注入 cookie。

### 微信读书

- W1：`WereadService.content` 先带信标请求，再走 legacy 直连，必要时重抓
  阅读器页面并使用页面里的 `ps/pc`；保留旧版固定 `pc`。
- R1：`WereadChapterWebView` 配置 `.character` 文本选择；正文 CSS 改为
  `#wr-content *` 可选中，加载后移除内联 `user-select` 锁；工具条不再
  拦截 `touchend` 合成 click。
- LG2：`WereadRenewalOutcome` 区分续期成功/未变/拒绝/临时失败；
  `WereadStore` 用 `sessionLock` 与 `sessionGeneration` 原子提交和注销，
  并发续期合并，HTTP/WK 会话逐份尝试，只有全部明确拒绝才清 cookie。

### 视频、图片查看器与导航

- V1：`SharedVideoPlayer` 新增 `VideoPlaybackQuality`；≤2GB 设备设置
  `preferredPeakBitRate = 1.2Mbps`、`preferredMaximumResolution = 960×960`；
  `automaticallyWaitsToMinimizeStalling = true`，起播改用 `play()`。
- L2：IG/XHS viewer 均增加 `onClose`、左上 44pt 关闭、下滑关闭与
  `zoomedPages` 门控；`MediaViewerScreen` 在 chrome 隐藏时任意点按恢复。
- S1：`HomeTimelineScreen` 的左上角用 `Button`，命中区不再被
  `.allowsHitTesting(false)` 整体关闭；`Router` 用 `pendingRoute` 等
  sheet `onDismiss` 后再入栈。

### 15PM lite 与微博回退

- P1：`Info.plist` 新增 `FlarePhoneLite = $(FLARE_PHONE_LITE)`；
  `FlareBuildVariant.isPhoneLite` 只认 `YES`/`true`；设置入口、首页账号
  tab、iPad 侧栏与 `.weread`/`.xiaohongshu` 路由均按开关过滤。
- M1：删除自加的 IP 属地视图与“改可见范围”入口；VVO 写/转发路径恢复
  官方 1.8.0，保留 `ipLocation` 字段但不在 UI 展示。

## 真机验证步骤

以下全部需要 **6S（iOS 15）**；15PM 只用于 lite 包入口与布局检查。

1. **小红书多图与清晰度（X1/X2）**
   - 首页、用户主页、搜索各进一条 2 图、3 图以上笔记；逐张左滑，
     第二张及以后必须是真实图片而不是灰块，分页点可见。
   - 返回首页看同一批卡片：块状碎图应变为清晰图；记录首屏加载耗时。
   - 若仍灰：抓图床 HTTP 状态码与 UA/Cookie 组合；若仍不能滑，记录详情
     接口实际返回的图片数。

2. **小红书评论与登录（X3/LG1）**
   - 首页、用户主页、搜索三处各进详情看评论，并试发一条。
   - 登录后按 Home 让 App 进后台，再强杀重开；连续 2 次冷启动。
   - 后台放置约 2 小时再进小红书，确认不重登；若失败记录 `-100`/`-1`/`461`
     与 cookie 是否存在。

3. **Instagram 互动、入口与视频（I1/I2/N1）**
   - 登录后杀进程重进，确认底部出现 Instagram tab；退出登录后消失。
   - 首页与详情分别点赞/取消，杀进程重进确认服务端状态；两处看评论并试发。
   - 打开自动翻译，确认译文出现；关闭后应看到“翻译”按钮。
   - 点作者进主页，滑到底触发下一页；XHS 卡片/详情无 id 的作者也要能进主页。
   - 后台放音乐，进 IG 视频：只有真正播放时音乐被切走，暂停/退出后恢复；
     静音拨片打开时视频应有声音；信息流与详情各测一次全屏进出。

4. **微信读书正文、选文与登录（W1/R1/LG2）**
   - 打开自己书架中的 epub 与 txt 各一本，确认首章出正文，连续翻 2–3 章。
   - 普通段落长按拖选，确认“划线/想法”可点并能保存；已有高亮仍可操作。
   - 杀进程冷启动、静置 >2 小时、断网各测一次：不应重登，断网不应清 cookie；
     主动退出后重进保持未登录。

5. **视频、图片查看器与卡顿（V1/L2/L1）**
   - IG feed/详情视频完整播到结尾或循环，暂停继续、拖动进度；记录实际
     URL 是 HLS 还是渐进 MP4，以及是否选中低档。
   - IG 帖子/Feed、XHS 单图/多图、原生 MediaViewer 的单图/多图/长图：
     左上关闭、下滑关闭、横滑翻页、捏合放大后下滑只平移、存图正常。
   - 首页冷启动首刷与二次刷新对比；进帖子正文/多图应 5 秒内出现，5 秒内
     重进应秒开；首页连滑 30 秒观察掉帧与重复下载。

6. **微博与左上角入口（M1/S1）**
   - 转发别人的微博不再提示“转发频繁”；时间线与详情都不显示 IP 属地。
   - “更多”菜单没有“改可见范围”；发帖只有 Public/Friends/SelfOnly；
     置顶/取消置顶/编辑/删除正常。
   - 点左上角头像/齿轮弹菜单，点“设置”能进入并正常返回；无标签空态也测一次。

7. **15PM lite 包（P1）**
   - 用下方命令出 lite 包，确认首页没有小红书/微信读书 tab，设置里没有
     两个入口，iPad/侧栏也不显示；Instagram 入口与视频可用。
   - 同一份代码出不带开关的普通包，在 6S 上确认小红书/微信读书仍出现。

## 15PM lite 构建方法

前置：macOS + Xcode，仓库根目录执行。CI 的
`.github/workflows/build-ios15.yml` 目前只产出标准 `Flare-iOS15.ipa`，
没有 lite job，因此 lite 包需要 flare 侧手工 archive。

```bash
cd appleApp
xcodegen generate

# 15PM lite：多传 FLARE_PHONE_LITE=YES
xcodebuild -project Flare.xcodeproj -scheme iOS -configuration Release \
  -sdk iphoneos -derivedDataPath DerivedData \
  -archivePath "$TEMP/Flare-Lite.xcarchive" archive \
  CURRENT_PROJECT_VERSION=<build号> \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY="" \
  FLARE_PHONE_LITE=YES \
  -skipPackagePluginValidation -skipMacroValidation

rm -rf Payload && mkdir -p Payload
cp -r "$TEMP/Flare-Lite.xcarchive/Products/Applications/Flare.app" Payload/
zip -qry Flare-iOS15-Lite.ipa Payload
```

普通包使用同一命令，去掉 `FLARE_PHONE_LITE=YES`，产物名为
`Flare-iOS15.ipa`。

出包后必须检查 `Info.plist` 的注入结果：

```bash
/usr/libexec/PlistBuddy -c "Print :FlarePhoneLite" Payload/Flare.app/Info.plist
```

- lite 包必须是 `YES`。
- 普通包必须是空串。
- 两者都不能残留字面量 `$(FLARE_PHONE_LITE)`。

## 出包与回滚

1. 监督器复核本文件与工作区 diff，确认只有文档新增；r4 的 16 个批次已各自
   独立提交。
2. 推送出包：`git push origin fix/startup-crash:ios15-build`。
3. push 触发 `.github/workflows/build-ios15.yml`：`smoke`（模拟器安装并
   启动 30s）通过后才运行 `logic-tests` / `ipa`；IPA 固定发布到 release
   `ios15-latest`，文件名 `Flare-iOS15.ipa`。
4. 下载产物 `Flare-iOS15-ipa-build<run_number>`；lite 包按上一节手工生成。
5. 记录本次 `run_number`、`github.sha`、smoke 结果，与真机反馈一起归档。

r4 的提交（按批次顺序）：

| 批次 | 提交 | 主题 |
|---|---|---|
| X1 | `3315d6938` | 小红书详情多图 |
| X2 | `758dafb5f` | 小红书图片清晰度 |
| X3 | `1ad1a5b51` | 小红书评论与登录 |
| I1 | `6b924a362` | Instagram 点赞/评论/翻译 |
| I2 | `264d89724` | Instagram 入口/全屏/声音 |
| W1 | `d8313e641` | 微信读书取正文 |
| P1 | `81e657493` | 15PM lite |
| N1 | `d69d79e80` | 用户名进个人主页 |
| M1 | `004b810a7` | 微博回退官方 1.8.0 |
| S1 | `71ddcc959` | 左上角进设置 |
| LG1 | `b565aefc8` | IG/XHS 登录持久化 |
| L1 | `3dd469a0a` | 6S 卡顿与加载 |
| L2 | `23d4602ae` | 图片查看器手势 |
| R1 | `453bbab50` | 微信读书选文笔记 |
| LG2 | `0b788dcda` | 微信读书登录持久化 |
| V1 | `520c8c395` | 6S 视频与声音 |

需要单独回退时用 `git revert <sha>`，优先只回退出问题的批次。不要回退
LG1/LG2 的会话恢复、S1 的 `pendingRoute`、L2 的关闭手势或 V1 的音频
引用计数，否则对应问题会复发。

## 附录 A · 相对 origin/ios15-build 的差异文件

以下为生成本文件前 `git diff --name-status origin/ios15-build...HEAD`
的结果，共 101 个文件；本文件提交后会再多 1 个。`A` 为新增，`M` 为修改。

```text
M	.github/workflows/build-ios15.yml
M	.gitignore
M	appleApp/Shared/FlareAppleCore/Sources/FlareAppleCore/ProxySessionConfigurator.swift
M	appleApp/Shared/FlareAppleCore/Sources/FlareAppleCore/WebViewDirectProxy.swift
M	appleApp/Shared/FlareAppleCore/Sources/FlareAppleCore/WebViewProxy.swift
M	appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/AudioSessionManager.swift
M	appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/ComposeActionBarContent.swift
M	appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/DiscoverContentScreen.swift
M	appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/EditRssSheet.swift
M	appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/FlareTextColors.swift
A	appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/FormStyleCompat.swift
M	appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/IOS15LayoutCompat.swift
M	appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/LocalHistoryContentScreen.swift
M	appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/NetworkImage.swift
M	appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/NetworkImageView.swift
M	appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/PluginManagementView.swift
M	appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/ProxyMarkdownImageLoader.swift
M	appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/ProxySettingsView.swift
M	appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/SearchScreen.swift
M	appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/ShareImageLoading.swift
M	appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/SharedVideoPlayer.swift
M	appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/StatusActionAnimationState.swift
A	appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/TextBackgroundCompat.swift
M	appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/TimelineItem/StatusActionView.swift
M	appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/TimelineItem/StatusMediaView.swift
M	appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/TimelineItem/StatusView.swift
M	appleApp/ios/Debug/MediaViewerTestFixture.swift
M	appleApp/ios/Debug/TimelineTestData.swift
M	appleApp/ios/FlareApp.swift
M	appleApp/ios/Info.plist
M	appleApp/ios/UI/Component/AdaptiveTimelineCardUIView.swift
M	appleApp/ios/UI/Component/CollectionViewTimeline.swift
M	appleApp/ios/UI/Component/DMConversationMessagesView.swift
M	appleApp/ios/UI/Component/GalleryTimelinePagingView.swift
M	appleApp/ios/UI/Component/Status/RichTextUIView.swift
M	appleApp/ios/UI/Component/Status/StatusUIKitActions.swift
M	appleApp/ios/UI/Component/Status/StatusUIKitLeaves.swift
M	appleApp/ios/UI/Component/Status/StatusUIKitMedia.swift
M	appleApp/ios/UI/Component/Status/StatusUIKitPoll.swift
M	appleApp/ios/UI/Component/Status/StatusUIKitReactions.swift
M	appleApp/ios/UI/Component/Status/StatusUIKitView.swift
M	appleApp/ios/UI/Component/TimelineAutoplay.swift
M	appleApp/ios/UI/Feature/WebSocial/Instagram/InstagramExtras.swift
M	appleApp/ios/UI/Feature/WebSocial/Instagram/InstagramFeedView.swift
M	appleApp/ios/UI/Feature/WebSocial/Instagram/InstagramModels.swift
M	appleApp/ios/UI/Feature/WebSocial/Instagram/InstagramPostView.swift
M	appleApp/ios/UI/Feature/WebSocial/Instagram/InstagramService.swift
M	appleApp/ios/UI/Feature/WebSocial/Instagram/InstagramStateIsolator.swift
M	appleApp/ios/UI/Feature/WebSocial/Instagram/InstagramStore.swift
A	appleApp/ios/UI/Feature/WebSocial/LaunchCrashTrace.swift
M	appleApp/ios/UI/Feature/WebSocial/LaunchGuard.swift
M	appleApp/ios/UI/Feature/WebSocial/WebPageHarvester.swift
M	appleApp/ios/UI/Feature/WebSocial/Xiaohongshu/XhsFeedView.swift
M	appleApp/ios/UI/Feature/WebSocial/Xiaohongshu/XhsModels.swift
M	appleApp/ios/UI/Feature/WebSocial/Xiaohongshu/XhsNoteView.swift
A	appleApp/ios/UI/Feature/WebSocial/Xiaohongshu/XhsQuery.swift
M	appleApp/ios/UI/Feature/WebSocial/Xiaohongshu/XhsService.swift
M	appleApp/ios/UI/Feature/WebSocial/Xiaohongshu/XhsSigner.swift
M	appleApp/ios/UI/Feature/WebSocial/Xiaohongshu/XhsStore.swift
M	appleApp/ios/UI/Feature/WebSocial/Xiaohongshu/XhsUserView.swift
M	appleApp/ios/UI/Feature/Weread/WereadCrypto.swift
M	appleApp/ios/UI/Feature/Weread/WereadModels.swift
M	appleApp/ios/UI/Feature/Weread/WereadNativeReaderView.swift
A	appleApp/ios/UI/Feature/Weread/WereadReaderSession.swift
M	appleApp/ios/UI/Feature/Weread/WereadReaderView.swift
M	appleApp/ios/UI/Feature/Weread/WereadService.swift
M	appleApp/ios/UI/Feature/Weread/WereadStore.swift
M	appleApp/ios/UI/FlareRoot.swift
M	appleApp/ios/UI/Route/Route.swift
M	appleApp/ios/UI/Route/Router.swift
M	appleApp/ios/UI/Route/RouterNavigationState.swift
M	appleApp/ios/UI/Screen/BackportWebLoginScreen.swift
M	appleApp/ios/UI/Screen/HomeTimelineScreen.swift
M	appleApp/ios/UI/Screen/MediaViewerScreen.swift
M	appleApp/ios/UI/Screen/ProfileScreen.swift
M	appleApp/ios/UI/Screen/SecondaryTabsScreen.swift
M	appleApp/iosControllerTests/StatusShareTests.swift
M	appleApp/iosControllerTests/TimelineMediaPreviewTests.swift
M	appleApp/iosControllerTests/TimelineRefreshAnimationTests.swift
M	appleApp/iosTests/VideoPlaybackSessionTests.swift
A	appleApp/iosTestsLogic/InstagramMediaParsingTests.swift
M	appleApp/iosTestsLogic/InstagramStateIsolatorTests.swift
M	appleApp/iosTestsLogic/XhsModelParsingTests.swift
A	appleApp/iosTestsLogic/XhsQueryEncodingTests.swift
M	appleApp/project.yml
A	docs/ios15-build101-followup.md
A	docs/ios15-crash-trace.md
A	docs/ios15-round2-followup.md
A	docs/ios15-round3-followup.md
A	docs/ios15-startup-crash-notes.md
M	shared/src/commonMain/kotlin/dev/dimension/flare/ui/model/UiTimelineV2.kt
M	social/vvo/src/commonMain/kotlin/dev/dimension/flare/data/datasource/vvo/VVODataSource.kt
M	social/vvo/src/commonMain/kotlin/dev/dimension/flare/data/datasource/vvo/VVOLoader.kt
M	social/vvo/src/commonMain/kotlin/dev/dimension/flare/data/network/vvo/VVOService.kt
M	social/vvo/src/commonMain/kotlin/dev/dimension/flare/data/network/vvo/api/StatusApi.kt
M	social/vvo/src/commonMain/kotlin/dev/dimension/flare/ui/model/mapper/VVO.kt
A	social/vvo/src/commonTest/kotlin/dev/dimension/flare/data/datasource/vvo/VVOWriteResponseTest.kt
M	social/vvo/src/commonTest/kotlin/dev/dimension/flare/data/network/vvo/VVOCookieRefreshTest.kt
M	social/vvo/src/commonTest/kotlin/dev/dimension/flare/data/network/vvo/VVOWriteRequestTest.kt
M	social/vvo/src/commonTest/kotlin/dev/dimension/flare/ui/model/mapper/VVORenderTest.kt
M	social/weread/src/commonMain/kotlin/dev/dimension/flare/data/network/weread/WeReadAccountBridge.kt
```

## 附录 B · r4 自身差异（d01115049..520c8c395）

以下为 `git diff --name-status d01115049..HEAD` 的结果，共 40 个文件。

```text
M	appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/AudioSessionManager.swift
M	appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/SharedVideoPlayer.swift
M	appleApp/Shared/FlareAppleCore/Sources/FlareAppleUI/TimelineItem/StatusView.swift
M	appleApp/ios/Info.plist
M	appleApp/ios/UI/Component/Status/StatusUIKitLeaves.swift
M	appleApp/ios/UI/Component/Status/StatusUIKitView.swift
M	appleApp/ios/UI/Component/TimelineAutoplay.swift
M	appleApp/ios/UI/Feature/WebSocial/Instagram/InstagramExtras.swift
M	appleApp/ios/UI/Feature/WebSocial/Instagram/InstagramFeedView.swift
M	appleApp/ios/UI/Feature/WebSocial/Instagram/InstagramModels.swift
M	appleApp/ios/UI/Feature/WebSocial/Instagram/InstagramPostView.swift
M	appleApp/ios/UI/Feature/WebSocial/Instagram/InstagramService.swift
M	appleApp/ios/UI/Feature/WebSocial/Instagram/InstagramStateIsolator.swift
M	appleApp/ios/UI/Feature/WebSocial/Instagram/InstagramStore.swift
M	appleApp/ios/UI/Feature/WebSocial/Xiaohongshu/XhsFeedView.swift
M	appleApp/ios/UI/Feature/WebSocial/Xiaohongshu/XhsModels.swift
M	appleApp/ios/UI/Feature/WebSocial/Xiaohongshu/XhsNoteView.swift
M	appleApp/ios/UI/Feature/WebSocial/Xiaohongshu/XhsService.swift
M	appleApp/ios/UI/Feature/WebSocial/Xiaohongshu/XhsSigner.swift
M	appleApp/ios/UI/Feature/WebSocial/Xiaohongshu/XhsStore.swift
M	appleApp/ios/UI/Feature/WebSocial/Xiaohongshu/XhsUserView.swift
M	appleApp/ios/UI/Feature/Weread/WereadNativeReaderView.swift
M	appleApp/ios/UI/Feature/Weread/WereadReaderSession.swift
M	appleApp/ios/UI/Feature/Weread/WereadService.swift
M	appleApp/ios/UI/Feature/Weread/WereadStore.swift
M	appleApp/ios/UI/FlareRoot.swift
M	appleApp/ios/UI/Route/Route.swift
M	appleApp/ios/UI/Route/Router.swift
M	appleApp/ios/UI/Route/RouterNavigationState.swift
M	appleApp/ios/UI/Screen/HomeTimelineScreen.swift
M	appleApp/ios/UI/Screen/MediaViewerScreen.swift
M	appleApp/ios/UI/Screen/SecondaryTabsScreen.swift
M	appleApp/iosTests/VideoPlaybackSessionTests.swift
M	social/vvo/src/commonMain/kotlin/dev/dimension/flare/data/datasource/vvo/VVODataSource.kt
M	social/vvo/src/commonMain/kotlin/dev/dimension/flare/data/datasource/vvo/VVOLoader.kt
M	social/vvo/src/commonMain/kotlin/dev/dimension/flare/data/network/vvo/VVOService.kt
M	social/vvo/src/commonMain/kotlin/dev/dimension/flare/data/network/vvo/api/StatusApi.kt
M	social/vvo/src/commonTest/kotlin/dev/dimension/flare/data/network/vvo/VVOComposeVisibilityTest.kt
M	social/vvo/src/commonTest/kotlin/dev/dimension/flare/data/network/vvo/VVOCookieRefreshTest.kt
M	social/vvo/src/commonTest/kotlin/dev/dimension/flare/data/network/vvo/VVOWriteRequestTest.kt
```
