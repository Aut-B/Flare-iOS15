# XHS 取证报告：homefeed 461 与四项能力现状

- 批次：X01（只读取证，不改产品代码）
- 基线：`f1084b6d4`（已含微博 W02）
- 取证日期：2026-11-27
- 取证材料：`evidence.md` 的 build131 真机诊断原文 + 本仓库 Swift 源码
- 限制：本机 `web_search` 不可用，也未做真机抓包；凡是源码和诊断不能证明的，本文一律标「待真机确认」，不猜字段、不补 token。

## 1. build131 诊断能确认的事实

| 事实 | 原文/字段 | 说明 |
| --- | --- | --- |
| 首页接口被拒 | `POST /api/sns/web/v1/homefeed → 461` | HTTP 状态是 461，不是超时、不是断网 |
| 响应体却像成功 | `{"code":0,"success":true,"msg":"成功","data":{}}` | 业务 code=0、data 为空；461 只体现在 HTTP 状态 |
| 失败那次凭据很薄 | `cookie=<redacted len=18>, a1=无, webId=无` | 这是诊断对 cookie 的摘要，不是完整值 |
| 稍后状态变了 | 登录=是、笔记 0、loading=否、hasMore=是、加载更多失败=否；cookie=50 字符、UA=117 字符、错误=无 | 两次请求之间 cookie 长度从 18 变 50，说明不是同一份会话 |

可以据此排除的：

- 不是「没登录」按现有判定标准：`isLoggedIn` 只看 `web_session` 非空（`XhsStore.swift:83`、`XhsStore.swift:106`），诊断也显示登录=是。
- 不是简单的网络失败：461 是服务端明确给出的状态。
- 不能据此断言账号被封：18 字符的 cookie 与随后 50 字符的 cookie 不一致，更像本地会话注入/恢复时序问题。

不能据此确认的：

- 不能确认 461 的具体触发条件（缺 a1/webId、请求体差异、设备指纹、出口 IP、账号策略，都可能）。
- 不能确认 `a1=无`、`webId=无` 是「网页里也没有」还是「只没写进保存的 cookie 串」。`sessionSummary()` 只检查保存的 header（`XhsService.swift:423`），不检查 WK 仓库。
- 诊断里的 `xsec=未携带` 对 homefeed 是正常现象：`homeFeed` 的 payload 本身不带 xsec（`XhsService.swift:24`），不能拿这一条当失败原因。

## 2. homefeed 完整请求链（源码核对）

1. 入口：`XhsTabView` → `XhsFeedView` → `XhsStore.refreshIfNeeded()`（`XhsStore.swift:309`）。
2. 判定：`refreshIfNeeded()` 若 `isLoggedIn` 为真就直接 `refresh()`；只有本地没有可用 `web_session` 时才走 `recoverFromSharedStorage()` 做服务端校验（`XhsStore.swift:309`）。
3. 注入：`refresh()` 先 `pushCredentials()`，把 UserDefaults 的 `xhs.cookie` 写进 `XhsService.shared.cookie`（`XhsStore.swift:303`），再 `XhsSigner.shared.applyCookies(cookie)`、`warmUp()`（`XhsStore.swift:335`）。
4. 组包：`loadFeedPage` → `XhsService.homeFeed`，payload 固定为 `cursor_score / num=20 / refresh_type / note_index / category=homefeed.follow|homefeed_recommend / need_num=20 / image_formats / need_filter_image`（`XhsService.swift:24`）。
5. 发送：`send()` 每次请求前再 `applyCookies` 一次（`XhsService.swift:292`），随后调用 `XhsSigner.shared.pageRequest`，并记录 `RES/ERR` 与 `STATE` 诊断（cookie 摘要 + xsec 有无）。
6. 签名：`pageRequest` 用隐藏 WKWebView（1280x1600、桌面 UA、`https://www.xiaohongshu.com/explore`、`WKWebsiteDataStore.default()`）执行页面内 `_webmsxyw(signPath, data)`，拿到 `X-S` / `X-T`，再补 `X-S-Common`，最后用页面内 `fetch(..., credentials:'include')` 发请求（`XhsSigner.swift:209`、`XhsSigner.swift:318`、`XhsSigner.swift:502`）。
7. `X-S-Common`：base64(JSON)，其中 `s5 = cookie 里的 a1`、`s14 = cookie 里的 webId`；两者为空时对应字段就是空串（`XhsService.swift:489`）。
8. 失败处理：`check()` 对 code 0 直接返回（`XhsService.swift:454`）；461 的 HTTP 状态由后续 `guard 2xx` 转成 `restrictionMessage(status:461)`（`XhsService.swift:393`）。但 `loadFeedPage` 只对 `needLogin` 错误单独处理，其余错误一律 `return false`（`XhsStore.swift:452`），于是 `refresh()` 启动抓取页兜底并把 `errorMessage` 清空（`XhsStore.swift:388`）。
9. 兜底：抓取页打开 `/explore`，hook 页面自己的 homefeed 响应（`XhsStore.swift:517`）。若响应也是 `code:0` + 空 `data`，`ingest` 在 `guard !batch.isEmpty else { return }` 处静默返回（`XhsStore.swift:568`），既不记错误也不改状态。

### 2.1 关键推论

- **461 的提示会被吞掉。** 接口路径已经能生成「服务端风控/登录态不完整」的文案，但 `loadFeedPage` 把它当成普通失败，转去抓取页；抓取页看到 code=0 空 body 又静默返回。最终用户看到的是 8 秒后的通用文案「页面打开了但没抓到首页数据」（`XhsStore.swift:501`），诊断里的「错误=无」也就解释得通。这是本地可改的诊断/提示问题，不是 461 的根因。
- **18 字符 cookie 进入请求，是本地链路能解释的。** 冷启动只要保存的字符串里 `web_session` 非空就认为已登录，不做服务端校验（`XhsStore.swift:83`、`XhsStore.swift:106`、`XhsStore.swift:309`）。一份残缺/过期的 header 会被直接灌进签名页并发 homefeed，正好符合诊断里第一次请求的形态。
- **a1/webId 至少没进保存的 cookie。** 登录页只要求 `web_session`（`XhsFeedView.swift:86`），`adopt(cookies:)` 会把 `xiaohongshu.com` 域下所有 cookie 拼成 header（`XhsStore.swift:235`、`XhsStore.swift:124`），理论上能收到 a1；但诊断明确记录 `a1=无, webId=无`，说明这次保存/恢复的结果里确实没有。是登录页当时没种 a1、还是被清 cookie 的时序冲掉，源码不能判定，需真机看 WK 仓库。

## 3. 461 归因分栏

### 3.1 可本地改

| 项 | 现状与依据 | 可改点 | 注意 |
| --- | --- | --- | --- |
| 冷启动信任残缺 cookie | `isLoggedIn = hasSession(...)`，只判非空（`XhsStore.swift:83`、`XhsStore.swift:106`）；`refreshIfNeeded` 命中后直接 refresh，不走 `validateSession`（`XhsStore.swift:309`） | 本地先判保存的 header 是否含 `a1/webId`；不完整就交给现有 `recoverFromSharedStorage()`（它本来就带校验），不新增接口调用 | 不在 homefeed 前额外加请求；X01 不改 |
| a1/webId 不参与签名头 | `commonHeader()` 只从保存的 header 取 a1/webId（`XhsService.swift:489`）；诊断该次两者皆无 | 可把 WK 仓库里的同名 cookie 作为回填来源（现有 `CookieJar` / `webKitCookies()` 已有能力），或登录后补采 | 回填后是否解除 461 必须真机验证，不能预设 |
| 461 语义丢失 | 接口 461 被 `loadFeedPage` 归为普通失败（`XhsStore.swift:452`），抓取页 code=0 空 body 静默返回（`XhsStore.swift:568`） | 至少在 `loadFeedPage` 保留 `restrictionMessage` 文案，不要被兜底覆盖 | 纯诊断改动，不增加请求，也绕不过风控 |
| 签名页 cookie 注入时序 | `applyCookies` 在页面 `isLoading` 时只写 cookie 不 reload（`XhsSigner.swift:145`）；`pageRequest` 只等 `_webmsxyw` 就绪，不校验 a1/webId 是否已进页面 | 可在就绪判定里加「a1/webId 是否可见」的本地检查（读 cookie 仓库，不发请求） | 属于本地时序修正，不是伪造；效果仍需真机 |
| 18/50 字符两份 cookie 的来源 | `adopt` 两个入口都只要求 `web_session` 非空（`XhsStore.swift:235`、`XhsStore.swift:255`）；Bridge 同步也一样 | 可在 adopt 时记录并拒绝明显不完整的 header（缺 a1/webId），或明确标记「待校验」 | 不能凭空生成 a1；只能拒绝/重取 |

### 3.2 需真机验证

| 项 | 为什么要真机 | 需要拿到什么 |
| --- | --- | --- |
| 461 是否由缺 a1/webId 触发 | 源码只能证明「本地请求里没有」，不能证明「服务端因此拒绝」 | 同一账号、同一出口 IP 下，网页版自身发出的 homefeed 请求头（Cookie、X-S、X-S-Common）与本机请求逐项对照 |
| 50 字符 cookie 到底含什么 | 诊断只给长度，没有字段清单；且 `sessionSummary` 只读 header，不读 WK 仓库 | 真机上打印脱敏字段名（不打印值），以及 WK 仓库同域 cookie 的字段名 |
| 461 是统一风控还是请求差异 | 同一 461 可能来自签名页，也可能来自抓取页；诊断没有区分 | 两条路径各自的 `pageRequest` / harvester 日志，带同一个请求 id 关联 |
| 请求体是否与网页一致 | 当前 payload 是硬编码（`XhsService.swift:24`），无法从源码判断服务端是否接受 | 网页版 homefeed 的实际 POST body（字段名与顺序） |
| 签名页会话是否真的登录 | `WKWebsiteDataStore.default()` 是共享仓库，但页面可能仍是匿名态（`XhsSigner.swift:513`） | 页面内 `document.cookie` 的字段名、`_webmsxyw` 返回值是否非空 |
| 换 a1/webId 后 461 是否消失 | 这是因果验证，不是源码能推出来的 | 一次受控真机对照（不重试、不多请求，只换会话来源） |

### 3.3 服务端风控无法绕

| 项 | 依据 | 结论 |
| --- | --- | --- |
| 461 / 403 / 人机验证 | 代码注释与文案已明确（`XhsService.swift:406`、`XhsStore.swift:586`） | 客户端不能硬绕；只能引导用户去网页版完成验证 |
| 账号或出口 IP 被限 | 与 461 同一类服务端策略，诊断无法区分 | 换设备/换网络可能有效，但不是本地代码能修 |
| 服务端返回「成功但空 data」 | build131 的 body 就是 `code:0, data:{}` | 这是服务端语义，客户端不能把它变成有内容；也不能靠多请求刷出来 |
| 关注流权限 / 登录态策略 | `category=homefeed.follow` 由服务端判定 | 本地只能如实显示「当前拿不到」，不能伪造 |

**合规边界（本批遵守）**：不伪造签名、不伪造 cookie、不伪造 xsec token；不新增请求、不加重试退避来刷 461；不把 CI/dot 通过当成真机修好。

## 4. 四项能力现状

### 4.1 看全部图片

**现在到哪一步**

- 解析：`XhsModels.note()` 合并 `image_list / imageList / images` 三种键，取不到时才退回 `cover / image`（`XhsModels.swift:333`）。
- 选图：`imageURL()` 按 `urlRaw/url > url_default > url_pre` 打分，`info_list` 里 `WB_DFT` 高于未知、`WB_PRV` 最低；剔除 avif，http 归一成 https（`XhsModels.swift:238`）。
- 详情：进笔记后 `loadDetail()` 拉详情并 `mergedDetail()` 做并集，详情图在前、卡片图补后（`XhsNoteView.swift:604`、`XhsNoteView.swift:658`）。
- 展示：单图点击全屏；多图 `TabView(.page)` + `x/y` 页码徽标（`XhsNoteView.swift:164`）；全屏 `XhsImageViewer` 支持左右翻、双击/捏合缩放、拖动、保存当前、保存全部、分享（`XhsNoteView.swift:747`）。

**卡点**

- 首页卡片常常只给封面，必须等详情接口回来才有多图；详情被 461/-1/xsec 拒时，页面只剩封面 + 「网页版」按钮（`XhsNoteView.swift:604`）。
- 图片 CDN 的防盗链/过期签名是否影响 `XhsImageView` 下载，源码看不出，需真机看加载失败率。

**判定**：展示与交互已完整，属「本地基本完成」；「能不能拿到全部图」取决于详情接口，属「需真机验证」；详情被风控拒属「服务端无法绕」。

### 4.2 看视频

**现在到哪一步**

- 选流：`videoURL()` 按 h264 → h265 → av1 顺序，优先渐进式 mp4，短边 ≤720 取最大一档，没有渐进式才退回 m3u8/mpd（`XhsModels.swift:305`）。
- 播放：`AVPlayer` + `AVURLAssetHTTPHeaderFieldsKey` 带 Referer、桌面 UA、Cookie（`XhsNoteView.swift:284`）。
- 换源：详情回来后 `videoURL` 变化会销毁并重建播放器（`XhsNoteView.swift:204`）。
- 失败：监听 `AVPlayerItemFailedToPlayToEndTime`，显示「视频加载失败，可点『在网页版播放』」（`XhsNoteView.swift:212`）。

**卡点**

- 直链有时效和防盗链，卡片上的兜底地址可能在详情回来前就失效；重建逻辑已覆盖，但真实失效率需真机。
- m3u8 分片的子请求是否继承 `AVURLAssetHTTPHeaderFieldsKey` 的 Cookie/Referer，源码不能保证；这决定 HLS 源能否播。
- 部分视频笔记的 `video.media.stream` 可能只给 av1 或分片，6S 的解码/带宽是否够，需真机。

**判定**：播放器与失败兜底已具备，属「本地基本完成」；直链时效、HLS 头传递、6S 解码属「需真机验证」；若服务端对视频 CDN 也做风控，属「无法绕」。

### 4.3 看评论

**现在到哪一步**

- UI：骨架屏、错误 + 「重新加载评论」、「查看更多评论」分页、空态（`XhsNoteView.swift:436`、`XhsNoteView.swift:705`）。
- 取数：`XhsStore.comments()` 先按笔记自带来源 + `pc_note/pc_feed/pc_user/pc_search` 并发尝试（最多 2 个，现有实现）；失败后用 `raceFreshDetail` 换新 `xsec_token/xsec_source`，变化了再试一次，并把新 token 写回列表（`XhsStore.swift:886`）。
- 接口：GET `/api/sns/web/v2/comment/page`，timeout 10、attempts 2（`XhsService.swift:143`）。
- 详情回来后若评论报错，会自动再 `loadComments(reset: true)` 一次（`XhsNoteView.swift:650`）。

**卡点**

- `xsec_token` 过期、来源不匹配、461/-1 都会让评论区空；现有逻辑只在 token/来源确实变化时才重试，拿不到新 token 就停在错误态。
- 评论分页深度、二级评论展开是否被服务端限制，源码看不出。
- 并发尝试 2 个来源是既有实现，不是本批新增；后续不要在此基础上继续加请求数。

**判定**：分页、换 token、错误重试的骨架已在，属「本地基本完成」；真实评论能否稳定拿到、能翻多深，属「需真机验证」；461/风控属「无法绕」。

### 4.4 点用户名进主页

**现在到哪一步**

- 作者：有 id 直接弹 `XhsUserView`；没 id 时先 `resolvedDetail(requireUserID: true)` 补一次详情，拿到 `user.id` 再弹（`XhsNoteView.swift:340`、`XhsStore.swift:1098`）。
- 主页：`XhsUserView` 资料头 + 笔记网格 + 分页 + 重试；空 id 走 `selfProfile()`（`XhsUserView.swift:254`、`XhsUserView.swift:276`）。
- 评论者/回复者：`XhsCommentRow.nameLink / subNameLink / avatar` 只在 `user.id` 非空时可点；空 id 只显示文本/头像，没有作者那套补详情兜底（`XhsNoteView.swift:1057`、`XhsNoteView.swift:1077`）。

**卡点**

- 评论者 id 为空时完全不可点。这是明确的本地缺口；但补兜底不能直接弹空 id，否则 `XhsUserView` 会走 `selfProfile()` 显示成「我自己」，需要先补 id 或明确禁用。
- 主页笔记接口 `user_posted` 可能 461/-1，资料接口也可能空；需真机确认失败率。
- 从评论点进主页时没有 `xsec_token` 上下文，主页数据能否出，取决于服务端对公开资料的策略。

**判定**：作者入口属「本地基本完成」；评论者无 id 补详情属「可本地改」；主页接口风控属「需真机验证 / 无法绕」。

### 4.5 四项能力汇总

| 能力 | 已实现到哪 | 主要卡点 | 分类 |
| --- | --- | --- | --- |
| 全部图片 | 多图解析、详情并集、全屏翻页/缩放/保存/分享 | 详情被拒时只剩封面 | 本地基本完成；取全图需真机；风控无法绕 |
| 视频 | 选流、AVPlayer、换源重建、失败提示 + 网页版 | 直链时效、m3u8 头传递、6S 解码 | 本地基本完成；播放稳定性需真机 |
| 评论 | 骨架/错误/分页、换 token 重试、来源并发 | token 过期、461、分页深度 | 本地基本完成；稳定性需真机；风控无法绕 |
| 用户名进主页 | 作者有/无 id 两条路；主页资料 + 笔记网格 | 评论者无 id 不可点；主页接口风控 | 作者本地完成；评论者缺兜底可本地改；风控需真机 |

## 5. 给下一批的取证结论

1. 461 不能只归因于「风控」。本地至少有两个可验证的差异：残缺 cookie 被直接信任、a1/webId 没进 `X-S-Common`。但两者是否就是 461 的触发条件，必须真机对照，不能写成结论。
2. 最值得先做的是**诊断保真**：让 461 的 HTTP 状态和 `restrictionMessage` 不被抓取页兜底覆盖。这不增加请求，也不碰风控，能让下一次真机日志直接回答「接口 461 还是抓取页 461」。
3. 四项能力里，唯一明确的本地功能缺口是「评论者无 id 时不可点、也没有补详情兜底」；作者侧已有可复用的 `resolvedDetail(requireUserID: true)` 模式。
4. 真机验证的最小集合：同一账号网页版 homefeed 请求头/请求体对照、WK 仓库里 a1/webId 是否存在、签名页与抓取页各自是否 461、视频直链/HLS 是否带得上 Cookie。

## 6. 本批没有做的事

- 没有改任何产品代码、没有改校验命令、没有新增请求或重试。
- 没有伪造/生成 cookie、a1、webId、xsec_token 或签名。
- 没有执行 `git add` / `git commit` / 任何写 `.git` 的命令。
- 没有把 CI/dot 通过当成真机修好；所有真机项均标「待真机确认」。
