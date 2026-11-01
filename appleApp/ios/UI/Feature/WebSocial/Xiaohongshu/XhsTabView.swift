import SwiftUI

/// 小红书标签页。
///
/// 原生瀑布流走的是 `edith.xiaohongshu.com` 的私有接口：签名能算出来，
/// 服务端风控一收紧还是只回 `code -1`。所以默认用**网页版**。
///
/// 默认是**桌面版**网页：手机版网页现在几乎每个入口都在喊「打开 App」，
/// 视频根本看不了；桌面版没有这套引导，登录、视频、评论都是完整的。
/// 觉得字小可以在右上角菜单里切回手机版，选择会记住。
struct XhsTabView: View {
    @State private var useWeb = true

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
                            .accessibilityLabel("切回网页版")
                        }
                    }
            }
        }
    }
}
