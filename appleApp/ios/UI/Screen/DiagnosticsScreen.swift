import SwiftUI
import FlareAppleUI

/// 通用诊断导出页：一次抓透小红书 / 微信读书 / Instagram / 微博转发。
/// 用户复现问题后进来点「导出报告」→ 存到文件 / 分享给开发者即可，
/// 不用 Mac、不用抓系统日志、不用每个 bug 各出一个专项包。
struct DiagnosticsScreen: View {
    @State private var reportText: String = ""
    @State private var showShare = false
    @State private var shareURL: URL?
    @State private var copied = false
    @State private var probeBookId: String = ""
    @State private var probeRunning = false

    var body: some View {
        List {
            Section {
                Text("先复现问题（进小红书看笔记详情 / 评论，进微信读书点重试，进 Instagram 点点赞评论，微博连续转发两次），再回来导出。报告含每个请求的状态码、返回摘要和错误原因，不含 cookie 原文。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("云端笔记拉取定位：用当前登录态对同一本书打多组笔记接口参数（bookmarklist 3 组 / review/list 4 组，含官方参数与桌面 UA），把每组的状态码、字节数、解析条数写进报告。只读，不改本地笔记、不写服务端。先在微读登录，再点测试。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField("书 ID（留空 = 自动测最近读的 2 本）", text: $probeBookId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    probeRunning = true
                    let cookie = WereadStore.shared.cookie
                    let override = probeBookId
                    Task {
                        await WereadService.shared.diagnoseNoteEndpoints(
                            cookie: cookie,
                            bookIdOverride: override.isEmpty ? nil : override
                        )
                        reportText = FlareDiagnostics.shared.report()
                        probeRunning = false
                    }
                } label: {
                    Label(
                        probeRunning ? "正在打接口…" : "跑笔记接口对照（写进报告）",
                        systemImage: "flask"
                    )
                }
                .disabled(probeRunning)
            } header: {
                Text("笔记接口对照测试（诊断专用）")
            }

            Section {
                Button {
                    shareURL = FlareDiagnostics.shared.exportFileURL()
                    showShare = true
                } label: {
                    Label("导出报告（存到文件 / 分享）", systemImage: "square.and.arrow.up")
                }
                Button {
                    UIPasteboard.general.string = reportText
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "已复制" : "复制报告全文", systemImage: copied ? "checkmark.circle" : "doc.on.doc")
                }
                Button(role: .destructive) {
                    FlareDiagnostics.shared.clear()
                    reportText = FlareDiagnostics.shared.report()
                } label: {
                    Label("清空本轮记录", systemImage: "trash")
                }
            }

            Section {
                ScrollView {
                    Text(reportText.isEmpty ? "本轮暂无记录" : reportText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
            } header: {
                Text("报告预览（可直接截图给开发者）")
            }
        }
        .navigationTitle("诊断报告")
        .onAppear { reportText = FlareDiagnostics.shared.report() }
        .sheet(isPresented: $showShare) {
            if let shareURL {
                IGShareSheet(items: [shareURL])
            }
        }
    }
}
