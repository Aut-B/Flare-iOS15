import FlareAppleCore
import FlareAppleUI
import KotlinSharedUI
import SwiftUI
import NavigationBackport
import UniformTypeIdentifiers

struct RssScreen: View {
    @State private var presenter = KotlinPresenter(presenter: RssListWithTabsPresenter())
    @State private var showAddSheet = false
    @State private var selectedEditItem: UiRssSource? = nil
    @State private var importOpmlUrl: URL? = nil
    @State private var exportedOPMLContent: String? = nil

    var body: some View {
        List {
            ForEach(presenter.state.sources, id: \.id) { item in
                NBNavigationLink(value: Route.timeline(
                    presenter.state.timelineTabItem(item: item)
                )) {
                    HStack {
                        UiRssView(data: item)
                        Spacer()
                        Button {
                            selectedEditItem = item
                        } label: {
                            Image(fontAwesome: .pen)
                        }
                        .accessibilityLabel(Text("edit_rss_title"))
                        .buttonStyle(.plain)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        presenter.state.delete(id: Int32(item.id))
                    } label: {
                        Label {
                            Text("delete")
                        } icon: {
                            Image(fontAwesome: .trash)
                        }
                    }
                }
            }
        }
        .navigationTitle("rss_title")
        .toolbar {
            ToolbarItem {
                // iOS 15 的 ToolbarContentBuilder 没有 buildIf，条件搬进 ToolbarItem 内部
                if !presenter.state.sources.isEmpty {
                    Button {
                        Task {
                            exportedOPMLContent = try? await ExportOPMLPresenter().export()
                        }
                    } label: {
                        Image(fontAwesome: .fileExport)
                    }
                    .accessibilityLabel(Text("export_opml"))
                    .fileExporter(
                        isPresented: Binding(
                            get: { exportedOPMLContent != nil },
                            set: { newValue in
                                if !newValue {
                                    exportedOPMLContent = nil
                                }
                            }
                        ),
                        document: OPMLFile(initialText: exportedOPMLContent ?? ""),
                        // iOS 15 回退：显式指定 contentType，走 iOS 14 起就有的重载，
                        // 避免编译器选中 iOS 17 的 contentTypes 版本。
                        contentType: .opml,
                        defaultFilename: "flare_export.opml"
                    ) { _ in
                        exportedOPMLContent = nil
                    }
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(fontAwesome: .plus)
                }
                .accessibilityLabel(Text("add_rss_title"))
            }
        }
        .sheet(isPresented: $showAddSheet) {
            NBNavigationStack {
                EditRssSheet(id: nil, onImportOPML: { url in
                    showAddSheet = false
                    importOpmlUrl = url
                })
            }
        }
        .sheet(item: $selectedEditItem) { item in
            NBNavigationStack {
                EditRssSheet(
                    id: Int(item.id),
                    initialUrl: item.url,
                    initialDisplayMode: item.displayMode,
                    onImportOPML: { url in
                        importOpmlUrl = url
                    }
                )
            }
        }
        .sheet(item: $importOpmlUrl) { url in
            NBNavigationStack {
                ImportOPMLScreen(url: url)
            }
        }
    }
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}
