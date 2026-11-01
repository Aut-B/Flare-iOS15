import SwiftUI

/// 小红书标签页。
///
/// 原生瀑布流走的是 `edith.xiaohongshu.com` 的私有接口：签名能算出来，
/// 服务端风控一收紧还是只回 `code -1`。所以默认用**网页版** ——
/// 登录态、视频、点赞、评论、搜索、收藏全都在，点进去就能用。
/// 想试原生列表可以在左上角切回去。
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
                    cookieDomainSuffix: "xiaohongshu.com"
                )
            } else {
                XhsFeedView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    Button {
                        useWeb = true
                    } label: {
                        Label("网页版", systemImage: "safari")
                    }
                    Button {
                        useWeb = false
                    } label: {
                        Label("原生瀑布流", systemImage: "square.grid.2x2")
                    }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
            }
        }
    }
}
