import SwiftUI

/// 小红书标签页。
///
/// 默认就是**原生瀑布流**：数据由隐藏网页把 `homefeed` 的响应搬回来，
/// 版式、滚动、图片缓存全是原生的，比套壳网页快得多，也不卡。
///
/// 万一抓不到（网页要求验证、账号异常），右上角菜单里还能切到网页版。
struct XhsTabView: View {
    @State private var useWeb = false

    var body: some View {
        Group {
            if useWeb {
                WebPlatformView(
                    url: "https://www.xiaohongshu.com/explore",
                    title: "小红书",
                    mobileUserAgent: WebPlatformUserAgent.mobile,
                    desktopUserAgent: WebPlatformUserAgent.desktop,
                    initialCookie: XhsStore.shared.cookie,
                    cookieDomainSuffix: "xiaohongshu.com",
                    // 时间线标签里已经有一整条应用自己的工具栏，浏览器那排
                    // 收进右上角菜单，别把左上角的账号入口挤掉。
                    showsBrowserBar: false,
                    // 手机版网页满屏都是「打开 App」，桌面版才是能用的那个。
                    startDesktop: true,
                    extraMenuTitle: "切回原生瀑布流",
                    extraMenuAction: { useWeb = false }
                )
            } else {
                XhsFeedView()
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                useWeb = true
                            } label: {
                                Image(systemName: "safari")
                            }
                            .accessibilityLabel("切到网页版")
                        }
                    }
            }
        }
    }
}