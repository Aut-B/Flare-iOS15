# build 101 第二轮修复清单（flare-r2）

本文件由 dot 任务 `flare-r2` 的 R6 批次生成，记录针对用户实测反馈的第二轮修复。

## 改动一览

| 批次 | 主题 | 主要文件 |
|---|---|---|
| R1 | 小红书首页图片清晰度 | `XhsModels.swift` |
| R2 | 小红书多图第二张与评论 | `XhsNoteView.swift`、`XhsStore.swift` |
| R3 | Instagram 登录持久/图片速度/点赞 | `LaunchGuard.swift`、`InstagramModels.swift` |
| R4 | 左上角按钮进设置 | `HomeTimelineScreen.swift` |
| R5 | 微信读书网页版选文兜底 | `WereadReaderView.swift` |

## 具体改动

- **R1**：`XhsNote.imageURL` 候选顺序改为 `url` 原图优先 → `url_pre` → `url_default` 缩略图，根治「图片好糊」。
- **R2**：详情与评论的 xsec_source 候选增加 `pc_user`/`pc_search`，解决从用户主页/搜索进来的笔记详情与评论整条被拒、只有封面一张图。
- **R3**：
  - `LaunchGuard` 只有连续两次启动失败才隔离 Instagram（单次崩溃不再清登录）。
  - `IGJSON.bestImageInfo` 选宽度 ≤1080 的最大图，降低 6S 首屏解码量。
  - 点赞：确认 Instagram 原生代码没有 like/unlike 实现，是功能缺失，未在本轮实现。
- **R4**：左上角按钮 label 加 `.allowsHitTesting(false)`，头像/异步图片不再吞点击。
- **R5**：微信读书网页版阅读器注入脚本加入触摸时动态放开 `user-select`。

## 未验证 / 需真实设备确认

- 本机无 Xcode/Kotlin 编译环境，全部改动只做了括号配平 + `git diff --check`，**必须靠 CI 编译**。
- 真机验证：
  1. 小红书：首页图片是否清晰；从首页/用户主页/搜索进笔记，能否滑到第二张图、评论区是否出内容。
  2. Instagram：登录后杀掉重开是否还需要重登；首页图片是否更快出来；点赞仍是缺失功能。
  3. 左上角：点头像/齿轮任意位置是否能进设置列表。
  4. 微信读书：原生与网页版阅读器长按正文能否拖选并划线/写想法。
  5. 15PM 冷启动：仍需 `.ips` 才能定位根因。

## 回滚

R1–R5 各自独立 commit，可按 commit 回退。
