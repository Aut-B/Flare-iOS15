import SwiftUI
import FlareAppleUI
import KotlinSharedUI
import FlareAppleCore
import NavigationBackport

struct SettingsScreen: View {
    var body: some View {
        List {
            NBNavigationLink(value: Route.accountManagement) {
                Label {
                    Text("account_management_title")
                    Text("account_management_description")
                } icon: {
                    Image(fontAwesome: .circleUser)
                }
            }

            Section {
                NBNavigationLink(value: Route.appearanceTheme) {
                    Label {
                        Text("appearance_theme")
                        Text("appearance_theme_group_subtitle")
                    } icon: {
                        Image(fontAwesome: .palette)
                    }
                }
                NBNavigationLink(value: Route.appearanceLayout) {
                    Label {
                        Text("appearance_layout_group_title")
                        Text("appearance_layout_group_subtitle")
                    } icon: {
                        Image(fontAwesome: .tableList)
                    }
                }
                NBNavigationLink(value: Route.appearanceDisplay) {
                    Label {
                        Text("appearance_display_group_title")
                        Text("appearance_display_group_subtitle")
                    } icon: {
                        Image(fontAwesome: .newspaper)
                    }
                }
                NBNavigationLink(value: Route.appearanceMedia) {
                    Label {
                        Text("appearance_media_group_title")
                        Text("appearance_media_group_subtitle")
                    } icon: {
                        Image(fontAwesome: .photoFilm)
                    }
                }
                NBNavigationLink(value: Route.appIconSettings) {
                    Label {
                        Text("App Icon")
                        Text("Choose the icon shown on your Home Screen")
                    } icon: {
                        Image(fontAwesome: .palette)
                    }
                }
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Button {
                        UIApplication.shared.open(url)
                    } label: {
                        Label {
                            Text("system_settings_title")
                            Text("system_settings_description")
                        } icon: {
                            Image(fontAwesome: .gear)
                        }
                    }
                }
                
//                StateView(state: presenter.state.user) { _ in
//                    NBNavigationLink(value: Route.moreMenuCustomize) {
//                        Label {
//                            Text("more_panel_customize")
//                        } icon: {
//                            Image(fontAwesome: .tableList)
//                        }
//                    }
//                }
            }

            Section {
                NBNavigationLink(value: Route.behavior) {
                    Label {
                        Text("settings_behavior_title")
                        Text("settings_behavior_description")
                    } icon: {
                        Image(fontAwesome: .sliders)
                    }
                }
            }

            Section {
                NBNavigationLink(value: Route.localFilter) {
                    Label {
                        Text("local_filter_title")
                        Text("local_filter_description")
                    } icon: {
                        Image(fontAwesome: .filter)
                    }
                }
                NBNavigationLink(value: Route.storage) {
                    Label {
                        Text("storage_title")
                        Text("storage_description")
                    } icon: {
                        Image(fontAwesome: .database)
                    }
                }
            }

            Section {
                NBNavigationLink(value: Route.aiConfig) {
                    Label {
                        Text("AI")
                        Text("ai_config_description")
                    } icon: {
                        Image(fontAwesome: .robot)
                    }

                }
                NBNavigationLink(value: Route.translationConfig) {
                    Label {
                        Text("settings_translation_title")
                        Text("settings_translation_description")
                    } icon: {
                        Image(fontAwesome: .language)
                    }
                }
                NavigationLink { ProxySettingsView() } label: {
                    Label {
                        Text("proxy_title")
                        Text("proxy_settings_subtitle")
                    } icon: {
                        Image(fontAwesome: .globe)
                    }
                }
                NBNavigationLink(value: Route.pluginManagement) {
                    Label {
                        Text("settings_plugins_title")
                        Text("settings_plugins_subtitle")
                    } icon: {
                        Image(fontAwesome: .puzzlePiece)
                    }
                }
            }

            Section {
                NBNavigationLink(value: Route.about) {
                    Label {
                        Text("about_title")
                        Text("about_description")
                    } icon: {
                        Image(fontAwesome: .circleInfo)
                    }
                }
            }
        }
        .navigationTitle("settings_title")
    }
}

struct BehaviorSettingsScreen: View {
    var body: some View {
        List {
            BehaviorSettingsSection {
                NBNavigationLink(value: Route.linkOpenDefaults) {
                    Label {
                        Text("settings_link_open_defaults_title")
                        Text("settings_link_open_defaults_description")
                    } icon: {
                        EmptyView()
                    }
                }
            }
        }
        .navigationTitle("settings_behavior_title")
    }
}

struct LinkOpenDefaultsSettingsScreen: View {
    var body: some View {
        LinkOpenDefaultsSettingsView()
            .navigationTitle("settings_link_open_defaults_title")
    }
}
