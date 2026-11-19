# build 101 后续修复清单（flare-ios15 批次）

本文件由 dot 任务 `flare-ios15` 的 B6 批次生成，记录 build 101 之后按批次做的修复、验证方式与真机检查项。

## 改动一览

| 批次 | 主题 | 主要文件 |
|---|---|---|
| B1 | 微信读书原生阅读器：恢复新选文段并做笔记 | `appleApp/ios/UI/Feature/Weread/WereadNativeReaderView.swift` |
| B2 | 6S 隐藏网页空转与内存暴涨治理 | `appleApp/ios/UI/Feature/WebSocial/WebPageHarvester.swift`、`appleApp/ios/UI/Feature/Weread/WereadStore.swift` |
| B3 | 15PM 冷启动闪退加固 + 崩溃现场导出 | `appleApp/ios/UI/Feature/WebSocial/LaunchGuard.swift`、`appleApp/ios/FlareApp.swift`、`appleApp/ios/Info.plist` |
| B4 | 微博转发失败被吞的修复 | `social/vvo/.../datasource/vvo/VVODataSource.kt`、`social/vvo/.../commonTest/.../VVOWriteResponseTest.kt` |
| B5 | 小红书评论等既有补丁回归核对 | 仅核对，无代码改动 |

## B1 微信读书选文/笔记

- 去掉 `html/body` 全局 `user-select:none` / `-webkit-touch-callout:none`。
- 正文选择器覆盖 `div/section/article/mark/...`。
- 新增触摸时向上 4 层动态放开选择，适配微信读书的嵌套 div 正文。

## B2 隐藏网页资源治理

- `WebPageHarvester` 全局单实例，新页启动前停旧页，增加 `os_log` 生命周期日志。
- `WereadStore.syncWebShelf` 的延时回调做身份校验，页面替换/停止后不再触发。

## B3 启动崩溃加固

- 恢复模式（crashes≥2）会清除微信读书本地登录态（cookie/昵称/书架链接缓存）。
- 恢复页新增「清掉微信读书登录并重试」。
- `Info.plist` 增加 `UIFileSharingEnabled=true`，`Documents/flare-launch` 可从「文件」App 取出。

## B4 微博转发

- 微博业务失败是 HTTP 200 + `ok=0`，原代码忽略返回体，失败被当成功。
- 现在统一 `requireOk()`：`http_code != 200` 或 `ok == 0` 抛异常并带服务端 `msg`。
- 新增 `VVOWriteResponseTest` 覆盖 4 种情况。

## 未验证 / 需 CI 与真机确认

- 本机无 Swift/Kotlin 工具链，所有改动只做了括号配平与 `git diff --check`，**未经编译**。
- 必须由 CI 编译验证（Kotlin 的 `VVOResponse<*>` when 分支类型推断、Swift 的 `Logger`/`os` 引入等）。
- 真机检查项：
  1. **6S 微信读书**：点书进原生阅读器，长按普通正文能拖选；松手出现「划线/想法」；已有高亮仍能点开写笔记。
  2. **6S 资源**：打开书架/小红书后看「设置 → 隐私与安全性 → 分析与改进 → 分析数据」是否还有 Flare 的 wakeups 记录；App 是否还发热卡顿。
  3. **微博转发**：普通转发、转发自己的、转发别人的转发、带图转发、公开/粉丝可见各试一次；失败时应显示具体原因而不是假成功。
  4. **15PM 冷启动**：仍需要 `.ips` 才能定位根因；本次只保证崩到恢复页时可清微信读书登录并把崩溃现场复制出来。

## 回滚

每个批次都是一个独立 commit（B1–B4），可按 commit 单独回退；B5 无代码改动。
