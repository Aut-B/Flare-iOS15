import SwiftUI

/// 微信读书标签页。
///
/// 默认是**原生书架**：书单走 `shelf/sync`，点书直接全屏进网页阅读器
/// （网页阅读器支持长按选文、划线、写想法，这些自己重写不划算）。
/// 网页阅读器要的 hash 由 `WereadStore` 从网页书架抄下来缓存，所以点书是秒开，
/// 不用再「先进线上书架、再点一次」。
///
/// 想看网页版书架可以在右上角切过去。
struct WereadTabView: View {
    @State private var useWeb = false

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
                            .accessibilityLabel("切到网页版书架")
                        }
                    }
            }
        }
    }
}