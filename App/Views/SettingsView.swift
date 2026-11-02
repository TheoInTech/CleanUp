import AppKit
import CleanUpCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// Mirrors the system's real login item status, re-read whenever the pane appears.
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    static let sponsorsURL = URL(string: "https://github.com/sponsors")!

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Open at login", isOn: loginBinding)
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
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
        .onAppear {
            NSApp.activate()
            syncLoginItem()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            syncLoginItem()
        }
    }

    /// Turning it on or off asks the system; if it refuses, the switch snaps back and says why.
    private var loginBinding: Binding<Bool> {
        Binding(
            get: { openAtLogin },
            set: { on in
                do {
                    try LoginItem.set(on)
                    loginError = LoginItem.needsApproval ? LoginItem.approvalMessage : nil
                } catch {
                    loginError = LoginItem.message(for: error)
                }
                openAtLogin = LoginItem.isEnabled
            }
        )
    }

    /// The user can change it in System Settings too, so the switch follows the system.
    private func syncLoginItem() {
        openAtLogin = LoginItem.isEnabled
        if LoginItem.needsApproval { loginError = LoginItem.approvalMessage }
        else if loginError == LoginItem.approvalMessage { loginError = nil }
    }
}
