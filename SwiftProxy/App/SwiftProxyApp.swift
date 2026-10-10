import SwiftUI

@main
struct SwiftProxyApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(.dark)
                .task { appState.onLaunch() }
        }
    }
}

struct RootView: View {
    @State private var selection: AppTab = .dashboard

    enum AppTab: Hashable {
        case dashboard, connections, diagnostics, settings
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("대시보드", systemImage: "gauge.with.dots.needle.33percent", value: AppTab.dashboard) {
                DashboardView()
            }
            Tab("연결", systemImage: "point.3.connected.trianglepath.dotted", value: AppTab.connections) {
                ConnectionsView()
            }
            Tab("진단", systemImage: "stethoscope", value: AppTab.diagnostics) {
                DiagnosticsView()
            }
            Tab("설정", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
        }
        .onOpenURL { url in
            guard url.scheme == "swiftproxy" else { return }
            switch url.host() {
            case "connections": selection = .connections
            case "diagnostics": selection = .diagnostics
            case "settings": selection = .settings
            default: selection = .dashboard
            }
        }
    }
}
