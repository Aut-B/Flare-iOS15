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

    var body: some View {
        List {
            Section {
                Text("先复现问题（进小红书看笔记详情 / 评论，进微信读书点重试，进 Instagram 点点赞评论，微博连续转发两次），再回来导出。报告含每个请求的状态码、返回摘要和错误原因，不含 cookie 原文。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
