import Foundation

enum InstallType: String, CaseIterable, Codable {
    case rosetta2
    case brewFormula
    case brewCask
    case appStore
    case manual
    case internetPkg
    case internetDmg
    case internetZip
}

enum TaskStatus: String, CaseIterable, Codable {
    case pending
    case running
    case ok
    case skipped
    case warning
    case failed

    var label: String {
        rawValue.capitalized
    }
}

struct AppDefinition: Identifiable, Hashable, Codable {
    let id: String
    let category: String
    let name: String
    let installType: InstallType
    let packageID: String?
    let url: String?
    let appPath: String?
    let notes: String
}

struct SettingDefinition: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let commands: [String]
    let notes: String
    let isVersionSensitive: Bool
}

struct ManualStep: Identifiable, Hashable {
    let id: String
    let area: String
    let title: String
    let detail: String
    let link: String?
}

struct TaskRecord: Identifiable, Hashable {
    let id: String
    let area: String
    let name: String
    var status: TaskStatus
    var detail: String
}

struct RunOptions {
    var dryRun = true
    var installApps = true
    var applySettings = true
}
