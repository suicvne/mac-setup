import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

struct ShellResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum Shell {
    static func run(_ command: [String]) async throws -> ShellResult {
        let resolvedCommand = try resolveCommand(command)

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: resolvedCommand[0])
            process.arguments = Array(resolvedCommand.dropFirst())

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: ShellResult(exitCode: proc.terminationStatus, stdout: stdout, stderr: stderr))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    static func resolveCommand(_ command: [String]) throws -> [String] {
        guard let executable = command.first else { return command }
        guard !executable.isEmpty else { return command }

        if executable.hasPrefix("/") {
            return command
        }

        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let searchPaths = environmentPath
            .split(separator: ":")
            .map(String.init)
            + ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"]

        let fileManager = FileManager.default
        for directory in searchPaths {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(executable).path
            if fileManager.isExecutableFile(atPath: candidate) {
                return [candidate] + command.dropFirst()
            }
        }

        throw CocoaError(.fileNoSuchFile, userInfo: [
            NSFilePathErrorKey: executable,
            NSLocalizedDescriptionKey: "Executable '\(executable)' could not be found in PATH."
        ])
    }

    static func openCommandInTerminal(_ shellCommand: String) throws {
        let fileManager = FileManager.default
        let scriptDirectory = fileManager.temporaryDirectory.appendingPathComponent("MacSetup", isDirectory: true)
        try fileManager.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)

        let scriptURL = scriptDirectory.appendingPathComponent("install-homebrew.command")
        let scriptContents = """
        #!/bin/bash
        set -e
        \(shellCommand)
        status=$?
        echo
        if [ $status -eq 0 ]; then
            echo "Homebrew installation finished."
        else
            echo "Homebrew installation failed with status $status."
        fi
        echo "You can close this window and return to MacSetup."
        """

        try scriptContents.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        NSWorkspace.shared.open(scriptURL)
    }

    static func tokenize(_ command: String) throws -> [String] {
        enum TokenizerError: Error {
            case unterminatedQuote
            case danglingEscape
        }

        var tokens: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaping = false

        for character in command {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }

            if character == "\\" && !inSingleQuote {
                escaping = true
                continue
            }

            if character == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                continue
            }

            if character == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                continue
            }

            if character.isWhitespace && !inSingleQuote && !inDoubleQuote {
                if !current.isEmpty {
                    tokens.append(current)
                    current.removeAll(keepingCapacity: true)
                }
                continue
            }

            current.append(character)
        }

        if escaping {
            throw TokenizerError.danglingEscape
        }

        if inSingleQuote || inDoubleQuote {
            throw TokenizerError.unterminatedQuote
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }
}

@MainActor
final class SetupViewModel: ObservableObject {
    private enum ConfigPersistence {
        static let LastConfigPathKey = "MacSetupImportedConfigurationBookmark"
    }

    @Published var options = RunOptions()
    @Published var isRunning = false
    @Published var logLines: [String] = []
    @Published var appRecords: [TaskRecord] = []
    @Published var settingRecords: [TaskRecord] = []
    @Published var manualSteps: [ManualStep] = []
    @Published var configurationSourceDescription = "Bundled configuration"
    @Published var isUsingBundledConfiguration = true

    private var configuration = Catalog.shared
    private var importedConfigurationURL: URL?
    private let fileManager = FileManager.default

    init() {
        restoreImportedConfigurationIfPresent()
        refreshRecords()
    }

    func refreshRecords() {
        appRecords = configuration.apps.map {
            TaskRecord(id: $0.id, area: $0.category, name: $0.name, status: .pending, detail: $0.notes)
        }
        settingRecords = configuration.settings.map {
            TaskRecord(id: $0.id, area: "Settings", name: $0.name, status: .pending, detail: $0.notes)
        }
        manualSteps = configuration.manualSteps.compactMap { $0.resolve(for: macOSMajorVersion()) }
    }

    func runSetup() {
        guard !isRunning else { return }
        refreshRecords()
        logLines.removeAll()
        isRunning = true

        Task {
            await appendLog("MacSetup run started.")
            if options.installApps {
                await installApps()
            }
            if options.applySettings {
                await applySettings()
            }
            await restartUIServicesIfNeeded()
            await appendLog("MacSetup run complete.")
            isRunning = false
        }
    }

    func openManualStep(_ step: ManualStep) {
        guard let link = step.link, let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    func openAppLink(_ app: AppDefinition) {
        guard let urlString = app.url, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    func exportConfiguration() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "macsetup-catalog.json"
        panel.title = "Export MacSetup Configuration"
        panel.message = "Save the active MacSetup configuration as JSON."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Catalog.encodedData(for: configuration)
            try data.write(to: url, options: .atomic)
            appendLogSync("Exported configuration to \(url.path)")
        } catch {
            appendLogSync("Failed to export configuration: \(error.localizedDescription)")
        }
    }

    func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Import MacSetup Configuration"
        panel.message = "Choose a JSON configuration to replace the bundled catalog."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadExternalConfiguration(from: url, persistSelection: true)
    }

    func restoreBundledConfiguration() {
        importedConfigurationURL = nil
        configuration = Catalog.shared
        UserDefaults.standard.removeObject(forKey: ConfigPersistence.LastConfigPathKey)
        updateConfigurationSourceDescription()
        refreshRecords()
        appendLogSync("Restored bundled configuration.")
    }

    private func installApps() async {
        let commandLineToolsReady = await ensureCommandLineTools()
        if !commandLineToolsReady {
            await appendLog("Skipping Homebrew app installs until Command Line Tools are available.")
        }

        let homebrewReady = commandLineToolsReady ? await ensureHomebrew() : false

        for app in configuration.apps {
            await updateAppStatus(id: app.id, status: .running, detail: "Working...")
            switch app.installType {
            case .brewFormula, .brewCask:
                if homebrewReady {
                    await installHomebrewApp(app)
                } else {
                    await updateAppStatus(id: app.id, status: .warning, detail: "Skipped because Homebrew prerequisites are not ready yet.")
                }
            case .manual, .appStore:
                await handleManualApp(app)
            case .internetPkg, .internetDmg, .internetZip:
                await skipUnsupportedDirectDownload(app)
            }
        }
    }

    private func applySettings() async {
        for setting in configuration.settings {
            await updateSettingStatus(id: setting.id, status: .running, detail: "Applying...")
            if options.dryRun {
                await updateSettingStatus(id: setting.id, status: .skipped, detail: "Would apply.")
                await appendLog("[dry-run] \(setting.name)")
                for commandString in setting.commands {
                    do {
                        let command = try Shell.tokenize(commandString)
                        await appendLog("  raw: \(commandString)")
                        await appendLog("  parsed: \(command)")
                    } catch {
                        await appendLog("  raw: \(commandString)")
                        await appendLog("  parse error: \(error.localizedDescription)")
                    }
                }
                continue
            }

            var failedCommand: [String]?
            for commandString in setting.commands {
                do {
                    let command = try Shell.tokenize(commandString)
                    guard !command.isEmpty else { continue }
                    let result = try await Shell.run(command)
                    if result.exitCode != 0 {
                        failedCommand = command
                        await appendLog("Failed: \(command.joined(separator: " "))")
                        if !result.stderr.isEmpty {
                            await appendLog(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                        break
                    }
                } catch {
                    failedCommand = [commandString]
                    await appendLog("Error running \(commandString): \(error.localizedDescription)")
                    break
                }
            }

            if let failedCommand {
                await updateSettingStatus(id: setting.id, status: .warning, detail: "Could not apply automatically: \(failedCommand.joined(separator: " "))")
            } else {
                await updateSettingStatus(id: setting.id, status: .ok, detail: "Applied.")
            }
        }
    }

    private func ensureCommandLineTools() async -> Bool {
        if await hasCommandLineTools() {
            await appendLog("Command Line Tools: already installed.")
            return true
        }

        if options.dryRun {
            await appendLog("[dry-run] Would trigger the Command Line Tools installer UI.")
            return false
        }

        do {
            let result = try await Shell.run(["/usr/bin/xcode-select", "--install"])
            let combinedOutput = [result.stdout, result.stderr]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if result.exitCode == 0 {
                await appendLog("Command Line Tools: installation requested. Complete the macOS installer prompt, then rerun MacSetup.")
                return false
            }

            if combinedOutput.localizedCaseInsensitiveContains("already installed") {
                await appendLog("Command Line Tools: already installed.")
                return true
            }

            let detail = combinedOutput.isEmpty ? "Unable to trigger installation automatically." : combinedOutput
            await appendLog("Command Line Tools: \(detail)")
            return false
        } catch {
            await appendLog("Command Line Tools: \(error.localizedDescription)")
            return false
        }
    }

    private func ensureHomebrew() async -> Bool {
        if await commandExists("brew") {
            await appendLog("Homebrew: already installed.")
            return true
        }

        if options.dryRun {
            await appendLog("[dry-run] Would install Homebrew.")
            return false
        }

        do {
            let installerCommand = #"/bin/bash -lc '/bin/bash -c "$(/usr/bin/curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'"#
            try Shell.openCommandInTerminal(installerCommand)
            await appendLog("Homebrew: opened the installer in Terminal so macOS can show the password prompt.")
            await appendLog("Homebrew: finish the install in Terminal, then run MacSetup again.")
            return false
        } catch {
            await appendLog("Homebrew: \(error.localizedDescription)")
            return false
        }
    }

    private func installHomebrewApp(_ app: AppDefinition) async {
        guard let packageID = app.packageID else {
            await updateAppStatus(id: app.id, status: .warning, detail: "Missing Homebrew package ID.")
            return
        }

        let installed = await isHomebrewPackageInstalled(app)
        if installed {
            await updateAppStatus(id: app.id, status: .ok, detail: "Already installed via Homebrew (\(packageID)).")
            return
        }

        if options.dryRun {
            await updateAppStatus(id: app.id, status: .skipped, detail: "Would install via Homebrew (\(packageID)).")
            await appendLog("[dry-run] brew install \(app.installType == .brewCask ? "--cask " : "")\(packageID)")
            return
        }

        guard let brewPath = await brewExecutablePath() else {
            await updateAppStatus(id: app.id, status: .failed, detail: "Homebrew is not available.")
            return
        }

        let command: [String]
        if app.installType == .brewCask {
            command = [brewPath, "install", "--cask", packageID]
        } else {
            command = [brewPath, "install", packageID]
        }

        do {
            let result = try await Shell.run(command)
            if result.exitCode == 0 {
                await updateAppStatus(id: app.id, status: .ok, detail: "Installed via Homebrew (\(packageID)).")
                let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !stdout.isEmpty {
                    await appendLog(stdout)
                }
            } else {
                let errorText = result.stderr.isEmpty ? "Homebrew install failed." : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                await updateAppStatus(id: app.id, status: .failed, detail: errorText)
                await appendLog(errorText)
            }
        } catch {
            await updateAppStatus(id: app.id, status: .failed, detail: error.localizedDescription)
            await appendLog("Error installing \(app.name): \(error.localizedDescription)")
        }
    }

    private func handleManualApp(_ app: AppDefinition) async {
        if let appPath = app.appPath, await pathExists(appPath) {
            await updateAppStatus(id: app.id, status: .ok, detail: "Already present at \(appPath).")
            return
        }

        await updateAppStatus(id: app.id, status: .skipped, detail: app.notes)
        if let step = manualStep(for: app) {
            manualSteps.append(step)
        }
    }

    private func skipUnsupportedDirectDownload(_ app: AppDefinition) async {
        if options.dryRun {
            await updateAppStatus(id: app.id, status: .skipped, detail: "Would install from direct download.")
        } else {
            await updateAppStatus(id: app.id, status: .warning, detail: "Direct downloads are not wired into the SwiftUI app yet.")
        }
    }

    private func manualStep(for app: AppDefinition) -> ManualStep? {
        guard let urlString = app.url else { return nil }
        return ManualStep(id: "app-\(app.id)", area: app.category, title: app.name, detail: app.notes, link: urlString)
    }

    private func restoreImportedConfigurationIfPresent() {
        guard
            let bookmarkData = UserDefaults.standard.data(forKey: ConfigPersistence.LastConfigPathKey)
        else {
            updateConfigurationSourceDescription()
            return
        }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                try persistBookmark(for: url)
            }

            loadExternalConfiguration(from: url, persistSelection: false)
        } catch {
            UserDefaults.standard.removeObject(forKey: ConfigPersistence.LastConfigPathKey)
            configuration = Catalog.shared
            updateConfigurationSourceDescription()
            appendLogSync("Could not restore imported configuration: \(error.localizedDescription)")
        }
    }

    private func loadExternalConfiguration(from url: URL, persistSelection: Bool) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            configuration = try Catalog.loadConfiguration(from: url)
            importedConfigurationURL = url
            if persistSelection {
                try persistBookmark(for: url)
            }
            updateConfigurationSourceDescription()
            refreshRecords()
            appendLogSync("Loaded configuration from \(url.path)")
        } catch {
            appendLogSync("Failed to load configuration from \(url.path): \(error.localizedDescription)")
        }
    }

    private func persistBookmark(for url: URL) throws {
        let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmarkData, forKey: ConfigPersistence.LastConfigPathKey)
    }

    private func updateConfigurationSourceDescription() {
        if let importedConfigurationURL {
            configurationSourceDescription = importedConfigurationURL.path
            isUsingBundledConfiguration = false
        } else if let bundledURL = Catalog.bundledConfigurationURL {
            configurationSourceDescription = bundledURL.path
            isUsingBundledConfiguration = true
        } else {
            configurationSourceDescription = "Bundled configuration"
            isUsingBundledConfiguration = true
        }
    }

    func openActiveConfigurationDirectory() {
        let url: URL?
        if let importedConfigurationURL {
            url = importedConfigurationURL.deletingLastPathComponent()
        } else {
            url = Catalog.bundledConfigurationURL?.deletingLastPathComponent()
        }

        guard let url else {
            appendLogSync("Could not locate an active configuration directory.")
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func isHomebrewPackageInstalled(_ app: AppDefinition) async -> Bool {
        guard let packageID = app.packageID, let brewPath = await brewExecutablePath() else { return false }
        let command: [String]
        if app.installType == .brewCask {
            command = [brewPath, "list", "--cask", packageID]
        } else {
            command = [brewPath, "list", packageID]
        }

        do {
            let result = try await Shell.run(command)
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    private func restartUIServicesIfNeeded() async {
        guard !options.dryRun, options.applySettings else { return }
        for service in ["Dock", "Finder", "SystemUIServer"] {
            _ = try? await Shell.run(["/usr/bin/killall", service])
        }
    }

    private func brewExecutablePath() async -> String? {
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        for candidate in candidates where await pathExists(candidate) {
            return candidate
        }
        return nil
    }

    private func hasCommandLineTools() async -> Bool {
        if await pathExists("/Library/Developer/CommandLineTools") {
            return true
        }

        do {
            let result = try await Shell.run(["/usr/bin/xcode-select", "-p"])
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    private func commandExists(_ name: String) async -> Bool {
        if name == "brew" {
            return await brewExecutablePath() != nil
        }
        return ["/usr/bin/\(name)", "/bin/\(name)", "/usr/sbin/\(name)", "/sbin/\(name)"].contains { fileManager.isExecutableFile(atPath: $0) }
    }

    private func pathExists(_ path: String) async -> Bool {
        fileManager.fileExists(atPath: path)
    }

    private func macOSMajorVersion() -> Int {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.majorVersion
    }

    private func updateAppStatus(id: String, status: TaskStatus, detail: String) async {
        guard let index = appRecords.firstIndex(where: { $0.id == id }) else { return }
        appRecords[index].status = status
        appRecords[index].detail = detail
    }

    private func updateSettingStatus(id: String, status: TaskStatus, detail: String) async {
        guard let index = settingRecords.firstIndex(where: { $0.id == id }) else { return }
        settingRecords[index].status = status
        settingRecords[index].detail = detail
    }

    private func appendLog(_ line: String) async {
        logLines.append(line)
    }

    private func appendLogSync(_ line: String) {
        logLines.append(line)
    }
}
