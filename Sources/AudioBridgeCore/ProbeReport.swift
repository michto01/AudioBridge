import Foundation

public struct ProbeReport: Codable, Sendable {
    public let capturedAt: Date
    public let operatingSystem: String
    public let permissionStatus: String
    public let permissionContext: String
    public let catalog: CatalogSnapshot
    public init(catalog: CatalogSnapshot, permissionStatus: String, permissionContext: String) {
        self.capturedAt = Date()
        self.operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
        self.permissionStatus = permissionStatus
        self.permissionContext = permissionContext
        self.catalog = catalog
    }
}
