import SwiftUI
import WebKit

struct SettingsView: View {
    @EnvironmentObject var tabManager: TabManager
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AdBlocker.enabledKey) private var adBlockEnabled = true
    @State private var searchEngine = SearchEngine.current
    @State private var showClearConfirm = false
    @State private var didClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Browsing") {
                    Toggle("Block ads", isOn: $adBlockEnabled)
                        .onChange(of: adBlockEnabled) { enabled in
                            tabManager.setAdBlockEverywhere(enabled)
                        }
                    Picker("Search engine", selection: $searchEngine) {
                        ForEach(SearchEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .onChange(of: searchEngine) { engine in
                        SearchEngine.setCurrent(engine)
                    }
                }
                .listRowBackground(Theme.card)

                Section("Privacy") {
                    Button(didClear ? "Browsing data cleared ✓" : "Clear browsing data", role: .destructive) {
                        showClearConfirm = true
                    }
                    .disabled(didClear)
                }
                .listRowBackground(Theme.card)

                Section("Downloads") {
                    LabeledContent("Location", value: "Files app → On My iPhone → Downloader 2 → Downloads")
                        .font(.footnote)
                }
                .listRowBackground(Theme.card)

                Section("About") {
                    LabeledContent("App", value: "Downloader 2")
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    Text("Downloads continue in the background. Only download content you have the right to save — respect copyright and each site's terms of service.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                .listRowBackground(Theme.card)
            }
            .darkListBackground()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Clear cookies, cache and history for all sites?",
                                isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("Clear browsing data", role: .destructive) {
                    let types = WKWebsiteDataStore.allWebsiteDataTypes()
                    WKWebsiteDataStore.default().removeData(ofTypes: types,
                                                            modifiedSince: .distantPast) {
                        didClear = true
                    }
                }
            }
        }
    }
}
