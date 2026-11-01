import SwiftUI

/// 微信读书标签页。
///
/// 原生书架走的是 `shelf/sync`，接口字段一改就少书；原生阅读器还得自己拼
/// 加密过的 bookId，拼错就是 404。所以默认直接用网页版书架：书单、目录、
/// 正文、进度、划线全由网页版处理，和手机 App 里那一份是一致的。
/// 想看原生网格可以在右上角切回去。
struct WereadTabView: View {
    @State private var useWeb = true

    var body: some View {
        Group {
            if useWeb {
                WebPlatformView(
                    url: "https://weread.qq.com/web/shelf",
                    title: "微信读书",
                    mobileUserAgent: WebPlatformUserAgent.mobile,
                    desktopUserAgent: WebPlatformUserAgent.desktop,
                    initialCookie: WereadStore.shared.cookie,
                    cookieDomainSuffix: "weread.qq.com",
                    // 时间线标签里已经有一整条应用自己的工具栏，浏览器那排
                    // 收进右上角菜单，别把左上角的账号入口挤掉。
                    showsBrowserBar: false,
                    // 手机 UA 下微信读书会把网页换成「打开 App」引导页。
                    startDesktop: true,
                    extraMenuTitle: "切回原生书架",
                    extraMenuAction: { useWeb = false }
                )
            } else {
                WereadShelfView()
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                useWeb = true
                            } label: {
                                Image(systemName: "safari")
                            }
                            .accessibilityLabel("切回网页版书架")
                        }
                    }
            }
        }
    }
}
