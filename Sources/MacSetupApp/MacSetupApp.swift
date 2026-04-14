import SwiftUI

@main
struct MacSetupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = SetupViewModel()

    var body: some Scene {
        Window("MacSetup", id: "main") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 1120, minHeight: 760)
        }
        .windowResizability(.contentSize)

        Window("Activity Log", id: "activity-log") {
            ActivityLogWindow(viewModel: viewModel)
                .frame(minWidth: 820, minHeight: 560)
        }

        .commands {
            MacSetupCommands(viewModel: viewModel)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        configureWindowTabbing()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        configureWindowTabbing()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func configureWindowTabbing() {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApplication.shared.windows.forEach { $0.tabbingMode = .disallowed }
    }
}

struct MacSetupCommands: Commands {
    @ObservedObject var viewModel: SetupViewModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            importButton
                .keyboardShortcut("i", modifiers: [.command, .shift])

            exportButton
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }

        CommandMenu("Configuration") {
            Button("Open Active Configuration Directory") {
                viewModel.openActiveConfigurationDirectory()
            }

            Divider()

            Button("Use Bundled Configuration") {
                viewModel.restoreBundledConfiguration()
            }
            .disabled(viewModel.isUsingBundledConfiguration)
        }
    }

    @ViewBuilder
    private var exportButton: some View {
        if #available(macOS 26.0, *) {
            Button(action: viewModel.exportConfiguration) {
                Label("Export JSON", systemImage: "square.and.arrow.up")
            }
        } else {
            Button("Export JSON") {
                viewModel.exportConfiguration()
            }
        }
    }

    @ViewBuilder
    private var importButton: some View {
        if #available(macOS 26.0, *) {
            Button(action: viewModel.importConfiguration) {
                Label("Import JSON", systemImage: "square.and.arrow.down")
            }
        } else {
            Button("Import JSON") {
                viewModel.importConfiguration()
            }
        }
    }
}

struct ActivityLogWindow: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var viewModel: SetupViewModel

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            LinearGradient(
                colors: colorScheme == .dark
                    ? [
                        Color(nsColor: .controlAccentColor).opacity(0.16),
                        Color.white.opacity(0.03)
                    ]
                    : [
                        Color(nsColor: .controlAccentColor).opacity(0.10),
                        Color(nsColor: .underPageBackgroundColor).opacity(0.0)
                    ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(viewModel.logLines.indices), id: \.self) { index in
                        Text(viewModel.logLines[index])
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal, 18)
                    }
                }
                .padding(.vertical, 22)
            }
            .foregroundStyle(Color(nsColor: .labelColor))
        }
    }
}
