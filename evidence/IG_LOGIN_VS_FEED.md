# IG 取证：登录链路、feed 风控，还是状态/诊断误判

- 批次：I01（只读取证，不改产品代码）
- 基线：`f37261bdb`（X03 小红书收尾之后）
- 取证日期：2026-11-27
- 取证材料：根目录 `evidence.md` 的 build130/131 真机原话与诊断原文 + 本仓库 Swift / KMP 源码
- 限制：本机 `web_search` 不可用，本批也没有真机、没有抓包。源码和诊断不能证明的，一律标「需真机确认」；不猜字段、不补 token、不伪造登录态。

## 0. 一句话结论

build131 的 `登录=是 + feed 0 条 + 0 请求` **既不能证明「登录成功」，也不能证明「被风控」**。源码可证实的是：`REQ` 在这套实现里根本不会被记录，所以 `REQ 0` 没有信息量；`登录=是` 只等价于「本地保存的 cookie 里 `sessionid` 非空」，不代表服务端接受。零请求最符合「自动刷新被安全模式静默挡掉 / 状态机没有再次触发刷新」，其次才是「本地恢复的旧 cookie 其实已失效但还没发过请求」。前者可本地改，后者必须真机点一次刷新才能区分。

## 1. 诊断原文能确认什么

### 1.1 可以确认的事实

| 事实 | 原文 | 源码口径 |
| --- | --- | --- |
| 零请求、零响应、零错误 | `REQ 0 / RES 0 / ERR 0 / STATE 12` | `REQ` 在 IG 实现里从不写入，见 §1.2 |
| 12 条状态恰好是 4 次采样 | `STATE 12` | 每次采样固定写 3 条：时间线 / 会话 / 失败态（`FlareDiagnostics.swift:239`、`:243`、`:246`），4×3=12，没有余量 |
| 诊断认为已登录 | `时间线 · 登录=是 · 用户=有 · feed 0 条` | `isLoggedIn` 来自 `sessionid` 非空（`InstagramModels.swift:47-51`、`InstagramStore.swift:82`） |
| 采样瞬间没有请求在跑 | `加载中=否 · 更多中=否` | `isLoading` / `isLoadingMore` 只在 `refresh()` / `loadMore()` 的派发里翻转（`InstagramStore.swift:373-379`、`:403-404`） |
| 凭据「看起来齐全」 | `cookie=395字符 · csrf=有 · userId=有` | 只是长度/非空，不是有效性（`InstagramService.swift:380-383`） |
| 隔离与收养没在拦 | `需要隔离=否 · 本次抑制收养=否` | 两个诊断值均为「否」，说明当时隔离器没有拦截（`InstagramStateIsolator.swift:113-122`） |
| `epoch=5` 不可当证据 | `epoch=5` | 这是常量 `quarantineEpoch` 的回显，不是设备实际 epoch（`InstagramStateIsolator.swift:6`、`FlareDiagnostics.swift:244`） |
| 没有错误文案 | `失败态 · 无` | `errorMessage` 为空；`refresh()` 一开始就会清空它（`InstagramStore.swift:375`），所以「无错误」同样不能证明没失败过 |

### 1.2 `REQ 0` 为什么没有信息量

全仓库只有两处写 `.instagram` 诊断：

- `InstagramService.request()`：只写 `RES`/`ERR` 和 `STATE`（`appleApp/ios/UI/Feature/WebSocial/Instagram/InstagramService.swift:375-383`）；
- `FlareDiagnostics.captureInstagramState()`：只写 3 条 `STATE`（`FlareDiagnostics.swift:235-247`）。

没有任何一处写 `REQ`。所以 `REQ 0` 是代码结构决定的恒等于 0，**不能拿它当「请求没发」或「请求发了」的证据**。

### 1.3 由 `RES 0 / ERR 0` 能推出来的（有限但有用）

诊断快照会落盘并在下次启动读回（`FlareDiagnostics.swift:21-23`、`:542-575`，上限 600 条、跨模块共用）。在这份快照没有被用户手动清空的前提下：

- 本次进程内**没有一次走到 `URLSession.data(for:)` 的 IG 请求完成**；
- 因此也**没有一次获得服务端结论**，`login_required` / `checkpoint_required` / `feedback_required` 这些判据一个都没被触发过。

进一步：若这次启动里发生过 `adopt`，它会调用 `refreshUserName()`（`InstagramStore.swift:152`），而 `currentUser()` 至少会发一个请求（`InstagramService.swift:217-235`）；只要拿到响应，就会留下 `RES` 或 `ERR`。诊断是 0，所以**可以合理推断本次进程内没有发生过 `adopt`**（除非用户清过诊断快照，或请求在 `URLSession` 层直接抛错、什么都没写）。`登录=是` 更可能来自冷启动从 UserDefaults 恢复的那条 395 字符 cookie（`InstagramStore.swift:56-84`）。

## 2. 登录链路：Flare 内登不上 vs 网页可登

### 2.1 四个入口，共用一个 WK 数据仓库

| 入口 | 代码位置 | 数据仓库 | 关键行为 |
| --- | --- | --- | --- |
| 原生 IG 页登录 sheet | `InstagramFeedView.swift:76-87` → `CookieLoginView` | `WKWebsiteDataStore.default()`（`CookieLoginView.swift:90`） | 固定 `clearCookies: true`（`InstagramFeedView.swift:83`）、桌面 UA、`sessionid` 必需 |
| KMP「添加账号」登录 | `InstagramLoginProvider.kt:96-141` + `BackportWebLoginScreen.swift` | 同一个 default store（`BackportWebLoginScreen.swift:430-447`） | 打开前 `clearAllWebsiteData`（`:140-142`），`resume()` 只要求 cookie 含 `sessionid=`（`InstagramLoginProvider.kt:102`、`:147`） |
| 网页版兜底 | `InstagramFeedView.swift:95-105` → `WebPlatformView` | 同一个 default store（`WebPlatformView.swift:225`） | 只 `CookieJar.writeIfAbsent`，**不回写 Store**（`WebPlatformView.swift:241-245`） |
| 冷启动恢复 | `InstagramStore.init` / `recoverFromWebKitIfNeeded` | 同一份 WK cookie 仓库 | 只在 `!isLoggedIn` 时去 WK 捞（`InstagramStore.swift:85-87`、`:213-244`） |

结论：**不存在「Flare 用了另一个 cookie 仓库」这种解释**。三条登录路径和网页兜底都指向 `WKWebsiteDataStore.default()`，所以「网页可登」本身说明系统仓库里有可用会话；问题只可能出在「谁去读、什么时候读、读到后有没有回写给原生 Store」。

冷启动恢复的时序由 `sessionGeneration` 保护：`adopt` / `logout` / `useStoredSession` 都会让它 +1（`InstagramStore.swift:111-115`、`:137`、`:169`、`:253`），WK 快照读取前先取 token（`:226`），回调里 token 变了就丢弃（`:233`）。它防的是「旧异步快照覆盖新登录」，**不能替代「登录完成后主动读取并 adopt」这一步**；也没有任何地方在 token 变化时补一次刷新，所以登录成功与首屏刷新之间仍然是断开的。

### 2.2 可能卡住的三个位置

**A. WebView 登录没有真正完成，却把会话收下了。**

- `CookieLoginView` 的自动判定会先记一次「游客基线」，值没变就不算登录（`CookieLoginView.swift:245-262`）。
- 但手动「完成」按钮直接 `forceFinish()`，**只要当前任意一个非空 `sessionid` 就收**（`:274-286`），不判断它是不是刚登录出来的。
- `clearCookies` 的清空是异步的；`baseline` 在清空回调里被置空（`:195-203`），而轮询在清空完成前就启动了（`:205-213`）。极端时序下基线可能先取到清除前的旧会话，之后的自动判定就可能把残留/旧会话当成「刚登录」（前提仍是 `sessionid` 非空）。
- 收下后 `adopt` 只做 `sessionid` 非空校验（`InstagramModels.swift:47-51`、`InstagramStore.swift:133`），所以「本地登录成功」不能推出「服务端登录成功」。

**B. 登录成功但没有带回原生 Store。**

- `WebPlatformView` 里登录成功后只更新 WK 仓库，没有任何回调通知 `InstagramStore`（`WebPlatformView.swift:241-245`、整个 Coordinator `:263-320` 都不碰 Store）。同一次进程内，原生 IG 页会继续显示登录提示（`InstagramFeedView.swift:37-40`）。
- 用户接着点原生「登录」，`clearCookies: true` 会把刚才网页里登好的 IG cookie 全删掉（`InstagramFeedView.swift:83`、`CookieLoginView.swift:196`），表现就是「网页能登，Flare 内一登就回到原点」。
- `InstagramSwiftBridge.adopt` 在非主线程时**先返回 true，再异步落库**（`InstagramSwiftBridge.swift:29-35`）；若此刻被隔离器抑制，返回值仍是 true，调用方会误以为成功（`InstagramStore.swift:128`）。
- 更隐蔽的一层：`adopt(cookies:)` 在隔离器抑制时**静默 `return`**（`InstagramStore.swift:118`）。登录 sheet 照常关闭，回调里的 `store.refresh()` 又因 `isLoggedIn == false` 直接返回（`:370`），用户看到的就是「点完登录、页面关掉、还是没登上」且没有任何错误提示。build131 诊断里「本次抑制收养=否」排除了当时这一条，但 build130 没有诊断，不能排除。
- `adopt(cookieHeader:)` 只把 `isLoggedIn` 置真、`loaded` 置假（`:145-151`），**不调用 `refreshAfterRecovery()`**；只有 `recoverFromWebKitIfNeeded` / `useStoredSession` 才会补刷新（`:239`、`:264`）。所以 KMP 登录成功后原生页可能一直停在未刷新状态，直到用户手动刷新。

**C. 已经落盘，但服务端判失效。**

- `hasUsableSession` 只检查 `sessionid` 非空（`InstagramModels.swift:47-51`），没有服务端校验。
- 冷启动把 395 字符 header 直接当登录态（`InstagramStore.swift:55-87`），`pushCredentials()` 把它灌进 Service（`:191-196`）。
- 若 cookie 已过期/被服务端判死，第一次请求才会暴露；诊断里一条请求都没有，所以这一条**只能真机确认**。

### 2.3 本地能证实 / 必须真机

本地可证实：

- 三条入口共用 default store；
- 网页兜底登录不会回流原生 Store；
- 原生登录 sheet 会无条件清掉同仓库的 IG cookie；
- `forceFinish` 接受任意非空 `sessionid`；
- `adopt` 成功后不自动补首屏刷新。

必须真机：

- build130 那次「登不上」具体卡在 A/B/C 哪个（该次没有诊断，只有用户原话）；
- 6S 上 1280 宽 + `initial-scale=0.30` + 桌面 UA 的登录页（`CookieLoginView.swift:125-142`）能否正常输入/扫码；
- 网页兜底里登录后，冷启动恢复是否真的捡到了会话（`recoverFromWebKitIfNeeded` 的 generation 守卫在 `:226-241`）。

## 3. feed 0 条：三条候选必须分开

### 3.1 候选一：请求根本没发出去

刷新入口共四处，但只有 `.task` 是「进页面自动拉」：`.task`（`InstagramFeedView.swift:120-122`）、原生登录完成回调里直接 `store.refresh()`（`:84-86`）、恢复后的补刷 `refreshAfterRecovery()`（`InstagramStore.swift:270-275`）、用户手动刷新（工具栏 `:49-53`、下拉 `:156-158`）。以下任一条件成立，就不会有请求：

- `isLoggedIn` 为假：UI 走 `loginPrompt`，feed 分支根本不渲染（`InstagramFeedView.swift:37-40`）；
- `.task` 只在视图进入时跑；tab 视图若一直存活就只跑一次，被系统取消也不会自动重跑（重新进入该 tab 才会再跑一次，届时仍受 `refreshIfNeeded` 的前两个门禁约束）；
- 进程内 `loaded` 已经是 true（只有成功才置真，`InstagramStore.swift:386`），`refreshIfNeeded` 直接返回（`:361`）；
- `refreshing` 卡在 true（仅异常路径可能；正常 `defer` 会复位，`:377-379`）。

排除项：诊断 `RES 0` 说明**没有一次成功**，所以「成功返回空 items 后 `loaded=true`」这条路不成立（若有，会有 RES）。`加载中=否` 只说明采样瞬间没在跑，不说明从未尝试。

### 3.2 候选二：诊断没 hook 到

- Swift 侧只在「拿到 HTTP 响应之后」写 `RES/ERR`（`InstagramService.swift:375-379`）；`URLSession.data(for:)` 抛错（断网 / 超时 / TLS / 被系统拦）会直接向上抛，**连 ERR 都不写**（`:367`），URL 非法则更早在 `:314-316` 返回，也不写。所以「0 请求 0 响应 0 错误」也可能是「发过但一个响应都没拿到」。
- KMP 的 `InstagramService.kt` 完全不接 `FlareDiagnostics`（`social/instagram` 下无任何引用），它的 `homeTimeline` / `currentUser` 请求**永远不会出现在 `instagram.txt`**。若用户看的是 Kotlin 时间线，这份诊断描述的只是原生页，不是用户眼前的页面。
- 网页兜底页（`WebPlatformView`）里的请求发生在 WKWebView 内，同样不会进 `instagram.txt`。
- 快照上限 600 条且跨模块共用（`FlareDiagnostics.swift:68`），理论上可能被 XHS/微信读书的日志挤掉；但本次 `STATE 12` 完整保留，说明 IG 事件没被淘汰，`RES 0` 仍可信。
- 用户手动「清空」诊断会同时清内存和磁盘（`:114-120`），这一点在真机上无法从 zip 反推。

### 3.3 候选三：状态机没触发刷新

这是 build131 最符合的一条：

- `refreshIfNeeded()` 的第二个门禁是 `guard !LaunchGuard.safeMode else { return }`（`InstagramStore.swift:365`）——**静默返回，不写任何诊断、不改 `isLoading`**。
- `safeMode` 有两个来源：①`begin()` 发现上次没清 activeKey（上次崩溃 / 被杀）就置真（`LaunchGuard.swift:33-38`）；②兜底页点「重新打开」时 `prepareRelaunch()` 主动置真（`:123-131`）。它在主界面出现 45 秒后自动解除（`:77-90`）。
- **解除 safeMode 的那一刻没有任何代码去重新触发 `refreshIfNeeded()`**；`.task` 早已跑完。结果是：登录=是、feed 0、0 请求、无错误，直到用户手动下拉。
- `adopt(cookieHeader:)`（KMP 桥接路径）会把 `loaded` 置假但不补刷新（`InstagramStore.swift:145-151`），也会造成同样的「状态已登录、界面不拉」。

这与诊断完全吻合：`isLoggedIn=true`（冷启动恢复）+ `loaded` 假 + `safeMode` 真 → 0 请求、0 错误、`加载中=否`。`safeMode` 本身不在诊断里（`FlareDiagnostics.swift:235-247` 没有该字段），所以**必须真机确认**；但它是源码里唯一能在「已登录、未加载」时静默挡掉自动刷新的门禁。

### 3.4 风控能不能解释 build131

不能直接解释。风控判据全部在「拿到响应之后」：

- `login_required` / `checkpoint_required` → `needLogin`（`InstagramService.swift:394-395`）；
- `feedback_required` / `spam` → 200 也可能风控，`needLogin=false`（`:399-405`）；
- HTML 风控页 → 文案提示，不踢登录（`:407-423`）。

既然 `RES 0 / ERR 0`，就**没有任何一次拿到响应**，也就没有任何风控判据被触发。可以成立的表述只有：「服务端可能拒绝，但这次根本没问到」。

## 4. 三栏分类

### 4.1 可本地改（源码已证实是本地逻辑/口径问题）

| # | 事项 | 源码依据 | 建议 |
| --- | --- | --- | --- |
| L1 | 诊断补 `REQ`、补「刷新门禁原因」 | `REQ` 从未写入（`InstagramService.swift:375-383`）；`refreshIfNeeded` 的两次 return 无日志（`InstagramStore.swift:361`、`:365`） | 在发请求前记 `REQ`；把 `safeMode/loaded/refreshing/isLoggedIn` 作为一次 STATE 采样；否则下次真机仍是猜 |
| L2 | `epoch=5` 是常量回显 | `FlareDiagnostics.swift:244` 引用 `quarantineEpoch` 常量 | 记真实存储的 epoch，或明确标注「常量」；当前值误导排查 |
| L3 | 诊断缺 `loaded` / `refreshing` / `safeMode` / 本次 adopt 次数 | `FlareDiagnostics.swift:235-247` | 增加这四项，可直接区分「没触发」与「触发被挡」 |
| L4 | safeMode 解除后不补刷新 | `LaunchGuard.swift:85-90`；`InstagramStore.swift:365` | 解除时若 `isLoggedIn && !loaded && feed.isEmpty`，补一次刷新（每进程一次，不做重试） |
| L5 | `adopt` 成功后不补首屏 | `InstagramStore.swift:144-152`，对比 `:264` | 在 adopt 的主队列回调里调用 `refreshAfterRecovery()` |
| L6 | 网页兜底登录不回写 Store | `WebPlatformView.swift:241-245`、`:263-320` | 增加 cookie 观察/「使用网页登录态」入口，把 WK 会话 adopt 回 Store |
| L7 | 原生登录静默清掉网页会话 | `InstagramFeedView.swift:83`、`CookieLoginView.swift:196` | 清空前告知，或仅在用户明确「重新登录」时清 |
| L8 | `forceFinish` 接受游客/旧会话 | `CookieLoginView.swift:274-286` | 收下前要求「与打开前基线不同」或至少二次确认；`forceFinish` 失败要给可见提示（现在静默 return） |
| L9 | 空 feed 文案无法区分「没拉」与「服务端空」 | `InstagramFeedView.swift:146-150`；`loaded` 未暴露 | 按 `loaded` / `errorMessage` 分三种文案：未拉取 / 拉取失败 / 服务端确实为空 |

### 4.2 需真机抓包确认（源码不能定论）

| # | 待确认项 | 为什么本地定不了 | 真机怎么确认 |
| --- | --- | --- | --- |
| V1 | build130「Flare 内登不上」卡在 A/B/C 哪一步 | 该次没有诊断；现只有用户原话 | 复现并导出 `instagram.txt`；先看有没有 `adopt` 产生的 `currentUser` 请求 |
| V2 | 395 字符 cookie 服务端是否接受 | `hasUsableSession` 不校验（`InstagramModels.swift:47-51`） | 真机点一次刷新，看 `RES` 状态码与 body message；不要外泄 cookie 原文 |
| V3 | 本次启动 `safeMode` 是否为真 | 诊断不含该字段 | 读 UserDefaults `flare.launch.safeMode`，或先做 L1/L3 后再复现 |
| V4 | `.task` 到底跑没跑 | 无任何标记 | L1/L3 的标记，或看手动刷新是否立刻产生 `RES` |
| V5 | 网页版登录后同进程内原生页是否 adopt | 代码上不 adopt，但可能有未发现的路径 | 在网页兜底登录 → 直接切原生 IG 页，看是否仍显示登录提示 |
| V6 | 原生登录页在 6S 上是否可正常操作 | 0.30 缩放 + 桌面 UA 的实际可用性只能实测 | 录屏/真机操作；同时对照系统 Safari |
| V7 | KMP 登录自动 resume 的时序 | `resume()` 只校验字符串；自动触发在共享登录 UI 里 | 用登录页自带的「登录诊断日志」导出（`BackportWebLoginScreen.swift:153-190`） |
| V8 | `X-IG-WWW-Claim` 两套实现不一致是否有影响 | Swift 仅在 cookie 含该字段时发送（`InstagramService.swift:332-337`），Kotlin 硬编码 `"0"`（`InstagramService.kt:193`） | 抓一次真实请求头；若出现 403/风控再决定对齐哪一套，不盲改 |
| V9 | 空 feed 是 200+空 `feed_items` 还是非 2xx | 零请求，无响应 | 一次真实请求的 `RES` 状态码 + body 前 200 字符（诊断已有 head 字段） |

### 4.3 服务端风控不可绕

| 判据 | 源码行为 | 边界 |
| --- | --- | --- |
| HTTP 401 / `login_required` / `checkpoint_required` | `needLogin`；原生 Store 只提示、不自动登出（`InstagramService.swift:388-395`、`InstagramStore.swift:277-286`） | 只能让用户重新登录；`checkpoint` 还要求网页内完成挑战，App 不能代过 |
| HTTP 200 + `feedback_required` / `spam` | 明确风控文案，`needLogin=false`（`InstagramService.swift:397-405`） | 等待 / 换网络 / 换账号；本批不增加任何重试退避 |
| HTML 风控页 | 通用风控文案，不踢登录（`:407-423`） | 同上；不要用「多请求刷」试探阈值 |
| 非登录 403 | 可能是 csrf 或风控，交给上层再试一次 GET（`:385-395`、`homeFeed` `:56-60`） | 那次 GET 是既有实现，不属于本批新增；不要再叠加循环 |
| 过期/被吊销的 `sessionid` | 本地无校验，只能等服务端返回（`InstagramModels.swift:47-51`） | 不能伪造 cookie、不能猜字段补值 |

## 5. 本批没有做的事

- 没有改任何产品代码、没有新增请求、没有加任何重试/退避。
- 没有真机、没有抓包、没有读取或输出任何 cookie/token 明文。
- 没有把 CI / `.dot` 通过当成真机问题已修复。
- 没有开始 I02。

## 6. 给下一批的最小路径

1. 先做 L1/L3（诊断补 `REQ` 与门禁原因）——否则任何「登录失败 / 风控 / 状态误判」的结论都是猜。
2. 再做 L4（safeMode 解除补一次刷新）与 L5（adopt 后补刷新）——这两条能直接消掉「登录=是、feed 0、0 请求」这一整类现象，且不增加请求次数。
3. 登录链路先确认用户走的是哪个入口：原生 sheet、KMP 添加账号、还是网页兜底。三者共用 default store，但回写 Store 的路径不同（L6/L7）。
4. 真机复现时只点一次「刷新」以取得首个 `RES/ERR`，用状态码区分「会话失效 / 风控 / 服务端空」，不要连续重试。
