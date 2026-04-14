import Foundation

struct AppConfiguration: Codable {
    let apps: [AppDefinition]
    let settings: [SettingDefinition]
    let manualSteps: [ConfiguredManualStep]
}

struct ConfiguredManualStep: Identifiable, Hashable, Codable {
    let id: String
    let area: String
    let title: String
    let detail: String
    let link: String?
    let minimumMajorVersion: Int?

    func resolve(for macOSMajor: Int) -> ManualStep? {
        if let minimumMajorVersion, macOSMajor < minimumMajorVersion {
            return nil
        }

        return ManualStep(
            id: id,
            area: area,
            title: title,
            detail: detail,
            link: link
        )
    }
}

enum Catalog {
    static let shared: AppConfiguration = loadConfiguration()
    static let bundledConfigurationURL: URL? = bundledCatalogURL()

    private static func loadConfiguration() -> AppConfiguration {
        guard let data = loadCatalogData() else {
            fatalError("Could not locate bundled catalog.json")
        }

        do {
            return try JSONDecoder().decode(AppConfiguration.self, from: data)
        } catch {
            fatalError("Could not decode bundled catalog.json: \(error)")
        }
    }

    static func loadConfiguration(from url: URL) throws -> AppConfiguration {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AppConfiguration.self, from: data)
    }

    static func encodedData(for configuration: AppConfiguration) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(configuration)
    }

    private static func loadCatalogData() -> Data? {
        guard let url = bundledCatalogURL() else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    private static func bundledCatalogURL() -> URL? {
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "catalog", withExtension: "json") {
            return url
        }
        #endif

        return Bundle.main.url(forResource: "catalog", withExtension: "json")
    }
}
