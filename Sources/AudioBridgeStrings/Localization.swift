import Foundation

/// Only operator UI uses this bundle. Audio, IDs and remote contracts never do.
/// Immutable bundles; language changes are persisted and invalidate the SwiftUI
/// locale environment. No lookup takes place on an audio thread.
private enum InterfaceStrings {
    static let resources: Bundle = {
        // A standalone helper in Contents/Helpers may have a CLI main bundle.
        // Resolve the containing app's Resources without copying unsigned
        // resource bundles into a directory reserved for nested executable code.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let candidates = [Bundle.main.resourceURL,
            executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources"),
            executable.deletingLastPathComponent()]
        for candidate in candidates {
            if let path = candidate?.appendingPathComponent("AudioBridge_AudioBridgeStrings.bundle"),
               let bundle = Bundle(url: path) { return bundle }
        }
        return Bundle.module // Standard SwiftPM command-line lookup fallback.
    }()
    static let english = resources.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)) ?? resources
    static let czech = resources.path(forResource: "cs", ofType: "lproj").flatMap(Bundle.init(path:)) ?? english
    static var bundle: Bundle {
        (UserDefaults.standard.string(forKey: "AudioBridge.interfaceLanguage")
            ?? UserDefaults(suiteName: "cz.bytelab.audiobridge")?.string(forKey: "AudioBridge.interfaceLanguage")) == "cs" ? czech : english
    }
}
public func L(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: InterfaceStrings.bundle)
}
/// Driver/plugin names and errors fall back verbatim; known UI states translate.
public func LT(_ value: String) -> String {
    InterfaceStrings.bundle.localizedString(forKey: value, value: value, table: "Localizable")
}
