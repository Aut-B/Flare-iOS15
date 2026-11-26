import FlareAppleUI
import SwiftUI
import UIKit

/// 通用诊断导出页：一次抓透微信读书 / 小红书 / Instagram / 微博转发 / 画中画并存状态。
/// 用户复现问题后进来点「抓当前状态快照」和「导出诊断 zip」，
/// 把整个 zip 分享给开发者即可，不用 Mac、不用抓系统日志、不用每个 bug 出一个专项包。
struct DiagnosticsScreen: View {
    @State private var reportText: String = ""
    @State private var showShare = false
    @State private var shareURL: URL?
    @State private var copied = false
    /// 非 nil 时表示后台正在采集 / 导出，按钮禁用并显示进度，避免重复点导致排队。
    @State private var busyText: String?

    var body: some View {
        List {
            Section {
                Text("先在 App 里复现一次（微读翻一章 / 小红书点开笔记看评论 / Instagram 刷新并点赞 / 微博连续转发两次 / 开画中画同时播视频），再回来导出。zip 含五个模块的状态、请求状态码、错误原文与设备/PiP 环境；cookie、token 已脱敏，成功响应体和笔记正文不会落盘。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                if let busyText {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(busyText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    Task { await captureOnly() }
                } label: {
                    Label("抓当前状态快照", systemImage: "camera.viewfinder")
                }
                .disabled(busyText != nil)
                Button {
                    Task { await captureAndExportZip() }
                } label: {
                    Label("导出诊断 zip（推荐）", systemImage: "square.and.arrow.up")
                }
                .disabled(busyText != nil)
                Button {
                    Task { await exportTextOnly() }
                } label: {
                    Label("只导出文本（txt）", systemImage: "doc.text")
                }
                .disabled(busyText != nil)
                Button {
                    Task { await copyReport() }
                } label: {
                    Label(
                        copied ? "已复制" : "复制报告全文",
                        systemImage: copied ? "checkmark.circle" : "doc.on.doc"
                    )
                }
                .disabled(busyText != nil)
                Button(role: .destructive) {
                    Task { await clearRecords() }
                } label: {
                    Label("清空本轮记录", systemImage: "trash")
                }
                .disabled(busyText != nil)
            } header: {
                Text("导出")
            } footer: {
                Text("zip 内含 README / report / device / weread / xhs / instagram / weibo / pip-system 八个文本文件。")
                    .font(.caption2)
            }

            Section {
                ScrollView {
                    Text(reportText.isEmpty ? (busyText == nil ? "本轮暂无记录" : "正在采集…") : reportText)
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
        .task { await captureOnly() }
        .sheet(isPresented: $showShare) {
            if let shareURL {
                IGShareSheet(items: [shareURL])
            }
        }
    }

    private func captureOnly() async {
        guard busyText == nil else { return }
        busyText = "正在采集快照…"
        defer { busyText = nil }
        reportText = await FlareDiagnostics.shared.captureSnapshot()
    }

    private func captureAndExportZip() async {
        guard busyText == nil else { return }
        busyText = "正在采集并生成诊断包…"
        defer { busyText = nil }
        reportText = await FlareDiagnostics.shared.captureSnapshot()
        if let zip = await FlareDiagnostics.shared.exportZip() {
            shareURL = zip
        } else {
            shareURL = await FlareDiagnostics.shared.exportFileURL()
        }
        showShare = true
    }

    private func exportTextOnly() async {
        guard busyText == nil else { return }
        busyText = "正在生成文本…"
        defer { busyText = nil }
        shareURL = await FlareDiagnostics.shared.exportFileURL()
        showShare = true
    }

    private func copyReport() async {
        guard busyText == nil else { return }
        busyText = "正在整理报告…"
        defer { busyText = nil }
        // 剪贴板可能跨 App / 跨设备同步，只复制落盘安全版（无响应体、无笔记正文）。
        UIPasteboard.general.string = await FlareDiagnostics.shared.exportText()
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private func clearRecords() async {
        guard busyText == nil else { return }
        busyText = "正在清空…"
        defer { busyText = nil }
        FlareDiagnostics.shared.clear()
        reportText = await FlareDiagnostics.shared.currentReport()
    }
}
