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
    @ObservedObject private var store = WereadStore.shared

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
                ZStack {
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
                    if store.shouldMaskShelfForEntryRecovery {
                        entryRecoveryMask
                    }
                }
                .task {
                    await store.recoverSessionOnEntry()
                }
            }
        }
    }

    /// 恢复登录态期间遮住书架，避免先闪一帧「登录微信读书」。临时失败
    /// 只显示重试，不把用户当成已退出；服务端明确判失效才露出登录入口。
    private var entryRecoveryMask: some View {
        VStack(spacing: 14) {
            if store.entryRecoveryUnreachable {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                Text("网络暂时不可用，登录信息已保留。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("重试") {
                    Task { await store.recoverSessionOnEntry(force: true) }
                }
                .buttonStyle(.borderedProminent)
            } else {
                ProgressView()
                Text("正在恢复登录状态…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .accessibilityElement(children: .combine)
    }
}
