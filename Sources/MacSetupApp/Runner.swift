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

    static func runStreaming(
        _ command: [String],
        onStdoutLine: (@Sendable (String) async -> Void)? = nil,
        onStderrLine: (@Sendable (String) async -> Void)? = nil
    ) async throws -> ShellResult {
        let resolvedCommand = try resolveCommand(command)

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: resolvedCommand[0])
            process.arguments = Array(resolvedCommand.dropFirst())

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let lock = NSLock()
            var stdoutData = Data()
            var stderrData = Data()
            var stdoutBuffer = ""
            var stderrBuffer = ""

            func emitAvailableLines(
                from handle: FileHandle,
                accumulatedData: inout Data,
                buffer: inout String,
                callback: (@Sendable (String) async -> Void)?
            ) {
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }

                accumulatedData.append(chunk)
                let text = String(decoding: chunk, as: UTF8.self)
                buffer.append(text)

                let parts = buffer.split(separator: "\n", omittingEmptySubsequences: false)
                let endsWithNewline = buffer.hasSuffix("\n")
                let completeLines = endsWithNewline ? Array(parts) : Array(parts.dropLast())
                buffer = endsWithNewline ? "" : String(parts.last ?? "")

                for rawLine in completeLines {
                    let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty else { continue }
                    if let callback {
                        Task {
                            await callback(line)
                        }
                    }
                }
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                lock.lock()
                emitAvailableLines(
                    from: handle,
                    accumulatedData: &stdoutData,
                    buffer: &stdoutBuffer,
                    callback: onStdoutLine
                )
                lock.unlock()
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                lock.lock()
                emitAvailableLines(
                    from: handle,
                    accumulatedData: &stderrData,
                    buffer: &stderrBuffer,
                    callback: onStderrLine
                )
                lock.unlock()
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                lock.lock()

                let finalStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                if !finalStdout.isEmpty {
                    stdoutData.append(finalStdout)
                    stdoutBuffer.append(String(decoding: finalStdout, as: UTF8.self))
                }

                let finalStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                if !finalStderr.isEmpty {
                    stderrData.append(finalStderr)
                    stderrBuffer.append(String(decoding: finalStderr, as: UTF8.self))
                }

                let trailingStdout = stdoutBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trailingStdout.isEmpty, let onStdoutLine {
                    Task {
                        await onStdoutLine(trailingStdout)
                    }
                }

                let trailingStderr = stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trailingStderr.isEmpty, let onStderrLine {
                    Task {
                        await onStderrLine(trailingStderr)
                    }
                }

                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                lock.unlock()

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

    static func openCommandInTerminal(
        _ shellCommand: String,
        scriptName: String,
        taskName: String
    ) throws {
        let fileManager = FileManager.default
        let scriptDirectory = fileManager.temporaryDirectory.appendingPathComponent("MacSetup", isDirectory: true)
        try fileManager.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)

        let scriptURL = scriptDirectory.appendingPathComponent(scriptName)
        let scriptContents = """
        #!/bin/bash
        set +e
        \(shellCommand)
        status=$?
        echo
        if [ $status -eq 0 ]; then
            echo "\(taskName) finished."
        else
            echo "\(taskName) failed with status $status."
        fi
        echo "You can close this window and return to MacSetup."
        exit $status
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
    private enum SpecialSettingCommand: String {
        case installRosetta2 = "macsetup:install-rosetta2"
    }

    private enum ConfigPersistence {
        static let LastConfigPathKey = "MacSetupImportedConfigurationBookmark"
    }

    @Published var options = RunOptions()
    @Published var isRunning = false
    @Published var logLines: [String] = []
    @Published var appRecords: [TaskRecord] = []
    @Published var settingRecords: [TaskRecord] = []
    @Published var manualSteps: [ManualStep] = []
    @Published var completedManualStepIDs: Set<String> = []
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
        let resolvedManualSteps = configuration.manualSteps.compactMap { $0.resolve(for: macOSMajorVersion()) }
        completedManualStepIDs.formIntersection(Set(resolvedManualSteps.map(\.id)))
        manualSteps = resolvedManualSteps
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

    func isManualStepCompleted(_ step: ManualStep) -> Bool {
        completedManualStepIDs.contains(step.id)
    }

    func toggleManualStep(_ step: ManualStep) {
        if completedManualStepIDs.contains(step.id) {
            completedManualStepIDs.remove(step.id)
        } else {
            completedManualStepIDs.insert(step.id)
        }
    }

    func resetManualChecklist() {
        completedManualStepIDs.removeAll()
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
        resetManualChecklist()
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
                await installDirectDownloadApp(app)
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
                    await appendLog("  raw: \(commandString)")
                    if let specialCommand = specialSettingCommand(from: commandString) {
                        await appendLog("  special: \(specialCommand.rawValue)")
                    } else {
                        do {
                            let command = try Shell.tokenize(commandString)
                            await appendLog("  parsed: \(command)")
                        } catch {
                            await appendLog("  parse error: \(error.localizedDescription)")
                        }
                    }
                }
                continue
            }

            var failedCommand: [String]?
            for commandString in setting.commands {
                do {
                    if let specialCommand = specialSettingCommand(from: commandString) {
                        let applied = try await runSpecialSettingCommand(specialCommand)
                        if !applied {
                            failedCommand = [commandString]
                            break
                        }
                        continue
                    }

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
                if let specialCommand = failedCommand.first.flatMap(specialSettingCommand(from:)) {
                    switch specialCommand {
                    case .installRosetta2:
                        await updateSettingStatus(
                            id: setting.id,
                            status: .warning,
                            detail: "Rosetta 2 needs a Terminal step or could not be opened automatically."
                        )
                    }
                } else {
                    await updateSettingStatus(id: setting.id, status: .warning, detail: "Could not apply automatically: \(failedCommand.joined(separator: " "))")
                }
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
            try Shell.openCommandInTerminal(
                installerCommand,
                scriptName: "install-homebrew.command",
                taskName: "Homebrew installation"
            )
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
            await updateAppStatus(id: app.id, status: .running, detail: "Installing via Homebrew...")
            await appendLog("Installing \(app.name) with Homebrew...")

            let result = try await Shell.runStreaming(
                command,
                onStdoutLine: { [weak self] line in
                    guard let self else { return }
                    await self.appendLog(line)
                    await self.updateAppStatus(
                        id: app.id,
                        status: .running,
                        detail: self.progressDetail(for: line, fallback: "Installing via Homebrew...")
                    )
                },
                onStderrLine: { [weak self] line in
                    guard let self else { return }
                    await self.appendLog(line)
                    await self.updateAppStatus(
                        id: app.id,
                        status: .running,
                        detail: self.progressDetail(for: line, fallback: "Installing via Homebrew...")
                    )
                }
            )
            if result.exitCode == 0 {
                await updateAppStatus(id: app.id, status: .ok, detail: "Installed via Homebrew (\(packageID)).")
            } else {
                let errorText = result.stderr.isEmpty ? "Homebrew install failed." : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                await updateAppStatus(id: app.id, status: .failed, detail: errorText)
                if result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await appendLog(errorText)
                }
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

    private func installDirectDownloadApp(_ app: AppDefinition) async {
        if let appPath = app.appPath, await pathExists(appPath) {
            await updateAppStatus(id: app.id, status: .ok, detail: "Already present at \(appPath).")
            return
        }

        guard let urlString = app.url, let downloadURL = URL(string: urlString) else {
            await updateAppStatus(id: app.id, status: .warning, detail: "Missing direct download URL.")
            return
        }

        if options.dryRun {
            await updateAppStatus(id: app.id, status: .skipped, detail: "Would install from \(downloadURL.absoluteString).")
            await appendLog("[dry-run] Direct download install for \(app.name): \(downloadURL.absoluteString)")
            return
        }

        do {
            await updateAppStatus(id: app.id, status: .running, detail: "Downloading installer...")
            let downloadLocation = try await downloadInstaller(for: app, from: downloadURL)

            switch app.installType {
            case .internetDmg:
                try await installFromDownloadedDMG(app: app, dmgURL: downloadLocation)
            case .internetPkg:
                try await installFromDownloadedPKG(app: app, pkgURL: downloadLocation)
            case .internetZip:
                try await installFromDownloadedZIP(app: app, zipURL: downloadLocation)
            case .brewFormula, .brewCask, .manual, .appStore:
                break
            }

            if let appPath = app.appPath, await pathExists(appPath) == false, app.installType != .internetPkg {
                await updateAppStatus(id: app.id, status: .warning, detail: "Installer finished, but \(appPath) was not found afterward.")
                return
            }

            await updateAppStatus(id: app.id, status: .ok, detail: "Installed from direct download.")
        } catch {
            await updateAppStatus(id: app.id, status: .failed, detail: error.localizedDescription)
            await appendLog("Error installing \(app.name) from direct download: \(error.localizedDescription)")
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
            resetManualChecklist()
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

    private func specialSettingCommand(from commandString: String) -> SpecialSettingCommand? {
        SpecialSettingCommand(rawValue: commandString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func runSpecialSettingCommand(_ command: SpecialSettingCommand) async throws -> Bool {
        switch command {
        case .installRosetta2:
            return try await installRosetta2IfNeeded()
        }
    }

    private func pathExists(_ path: String) async -> Bool {
        fileManager.fileExists(atPath: path)
    }

    private func isAppleSiliconMac() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return result == 0 && value == 1
    }

    private func hasRosetta2() async -> Bool {
        do {
            let result = try await Shell.run(["/usr/sbin/pkgutil", "--pkg-info", "com.apple.pkg.RosettaUpdateAuto"])
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    private func installRosetta2IfNeeded() async throws -> Bool {
        guard isAppleSiliconMac() else {
            await appendLog("Rosetta 2: skipped because this Mac is not Apple silicon.")
            return true
        }

        if await hasRosetta2() {
            await appendLog("Rosetta 2: already installed.")
            return true
        }

        let installerCommand = "/usr/sbin/softwareupdate --install-rosetta --agree-to-license"
        try Shell.openCommandInTerminal(
            installerCommand,
            scriptName: "install-rosetta-2.command",
            taskName: "Rosetta 2 installation"
        )
        await appendLog("Rosetta 2: opened the installer in Terminal so macOS can show the password prompt.")
        await appendLog("Rosetta 2: finish the install in Terminal, then run MacSetup again.")
        return false
    }

    private func macOSMajorVersion() -> Int {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.majorVersion
    }

    private func progressDetail(for line: String, fallback: String) -> String {
        let compact = line.replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return fallback }

        if compact.count <= 90 {
            return compact
        }

        let endIndex = compact.index(compact.startIndex, offsetBy: 87)
        return "\(compact[..<endIndex])..."
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

    private func downloadInstaller(for app: AppDefinition, from url: URL) async throws -> URL {
        await appendLog("Downloading \(app.name) from \(url.absoluteString)")

        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 600)
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw NSError(
                domain: "MacSetup.Download",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Download failed with HTTP \(httpResponse.statusCode)."]
            )
        }

        let downloadsDirectory = fileManager.temporaryDirectory.appendingPathComponent("MacSetupDownloads", isDirectory: true)
        try fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)

        let filename = sanitizedFilename(for: app, response: response, fallbackURL: url)
        let destinationURL = downloadsDirectory.appendingPathComponent(filename)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }

    private func installFromDownloadedDMG(app: AppDefinition, dmgURL: URL) async throws {
        guard let appPath = app.appPath else {
            throw NSError(domain: "MacSetup.Install", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing appPath for DMG install."])
        }

        let mountPoint = fileManager.temporaryDirectory
            .appendingPathComponent("MacSetupMounts", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        await appendLog("Mounting \(dmgURL.lastPathComponent)")
        let attachResult = try await Shell.run([
            "/usr/bin/hdiutil", "attach", dmgURL.path,
            "-nobrowse",
            "-mountpoint", mountPoint.path
        ])
        guard attachResult.exitCode == 0 else {
            let errorText = attachResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "MacSetup.Install", code: Int(attachResult.exitCode), userInfo: [NSLocalizedDescriptionKey: errorText.isEmpty ? "Could not mount DMG." : errorText])
        }

        do {
            guard let sourceApp = try locateBundle(named: URL(fileURLWithPath: appPath).lastPathComponent, under: mountPoint, withExtension: "app") else {
                throw NSError(domain: "MacSetup.Install", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not find \(URL(fileURLWithPath: appPath).lastPathComponent) in mounted DMG."])
            }

            if fileManager.fileExists(atPath: appPath) {
                try fileManager.removeItem(atPath: appPath)
            }

            await appendLog("Copying \(sourceApp.lastPathComponent) to \(appPath)")
            let copyResult = try await Shell.run(["/usr/bin/ditto", sourceApp.path, appPath])
            guard copyResult.exitCode == 0 else {
                let errorText = copyResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw NSError(domain: "MacSetup.Install", code: Int(copyResult.exitCode), userInfo: [NSLocalizedDescriptionKey: errorText.isEmpty ? "Could not copy app from DMG." : errorText])
            }
        } catch {
            _ = try? await Shell.run(["/usr/bin/hdiutil", "detach", mountPoint.path])
            try? fileManager.removeItem(at: mountPoint)
            throw error
        }

        _ = try? await Shell.run(["/usr/bin/hdiutil", "detach", mountPoint.path])
        try? fileManager.removeItem(at: mountPoint)
    }

    private func installFromDownloadedPKG(app: AppDefinition, pkgURL: URL) async throws {
        await appendLog("Running installer for \(pkgURL.lastPathComponent)")
        let result = try await Shell.run(["/usr/sbin/installer", "-pkg", pkgURL.path, "-target", "/"])
        guard result.exitCode == 0 else {
            let errorText = [result.stdout, result.stderr]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "MacSetup.Install", code: Int(result.exitCode), userInfo: [NSLocalizedDescriptionKey: errorText.isEmpty ? "PKG installer failed." : errorText])
        }
    }

    private func installFromDownloadedZIP(app: AppDefinition, zipURL: URL) async throws {
        guard let appPath = app.appPath else {
            throw NSError(domain: "MacSetup.Install", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing appPath for ZIP install."])
        }

        let extractionDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("MacSetupExtracted", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: extractionDirectory)
        }

        await appendLog("Extracting \(zipURL.lastPathComponent)")
        let unzipResult = try await Shell.run([
            "/usr/bin/ditto", "-x", "-k", zipURL.path, extractionDirectory.path
        ])
        guard unzipResult.exitCode == 0 else {
            let errorText = unzipResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "MacSetup.Install", code: Int(unzipResult.exitCode), userInfo: [NSLocalizedDescriptionKey: errorText.isEmpty ? "Could not extract ZIP archive." : errorText])
        }

        guard let sourceApp = try locateBundle(named: URL(fileURLWithPath: appPath).lastPathComponent, under: extractionDirectory, withExtension: "app") else {
            throw NSError(domain: "MacSetup.Install", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not find \(URL(fileURLWithPath: appPath).lastPathComponent) in extracted ZIP archive."])
        }

        if fileManager.fileExists(atPath: appPath) {
            try fileManager.removeItem(atPath: appPath)
        }

        await appendLog("Copying \(sourceApp.lastPathComponent) to \(appPath)")
        let copyResult = try await Shell.run(["/usr/bin/ditto", sourceApp.path, appPath])
        guard copyResult.exitCode == 0 else {
            let errorText = copyResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "MacSetup.Install", code: Int(copyResult.exitCode), userInfo: [NSLocalizedDescriptionKey: errorText.isEmpty ? "Could not copy app from ZIP archive." : errorText])
        }
    }

    private func locateBundle(named bundleName: String, under directory: URL, withExtension requiredExtension: String) throws -> URL? {
        if fileManager.fileExists(atPath: directory.appendingPathComponent(bundleName).path) {
            return directory.appendingPathComponent(bundleName)
        }

        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return nil
        }

        for case let url as URL in enumerator {
            guard url.pathExtension.caseInsensitiveCompare(requiredExtension) == .orderedSame else { continue }
            if url.lastPathComponent == bundleName {
                return url
            }
        }

        return nil
    }

    private func sanitizedFilename(for app: AppDefinition, response: URLResponse, fallbackURL: URL) -> String {
        let preferredName: String
        if let suggestedName = response.suggestedFilename, !suggestedName.isEmpty {
            preferredName = suggestedName
        } else {
            preferredName = fallbackURL.lastPathComponent.isEmpty ? app.id : fallbackURL.lastPathComponent
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let cleaned = preferredName.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let filename = String(cleaned)
        return filename.isEmpty ? app.id : filename
    }
}
