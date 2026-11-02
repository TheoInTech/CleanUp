import AppKit
import CleanUpCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// Placeholder flag; wired to the login item later.
    @AppStorage("openAtLogin") private var openAtLogin = true

    static let sponsorsURL = URL(string: "https://github.com/sponsors")!

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Open at login", isOn: $openAtLogin)
                Toggle("Use Apple Intelligence", isOn: $model.useAI)
            }

            Section("Always kept") {
                if model.keepList.entries.isEmpty {
                    Text("Nothing yet. Tap Keep on an item to add it.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.keepList.entries, id: \.id) { entry in
                        HStack {
                            Text(entry.name)
                            Spacer()
                            Button {
                                model.unkeep(entry.id)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove")
                            .accessibilityLabel("Remove \(entry.name)")
                        }
                    }
                }
            }

            Section {
                Link(destination: Self.sponsorsURL) {
                    Label("Support CleanUp on GitHub Sponsors", systemImage: "heart")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .frame(minHeight: 320)
        .onAppear { NSApp.activate() }
    }
}
