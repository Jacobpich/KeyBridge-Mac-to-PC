import Foundation
import ServiceManagement

/// Keybridge used to be called MX Control. On the first launch under the new name, its
/// settings, device configs and Crossover pairings move over. (The Crossover key in the Keychain
/// moves over in `Crossover.loadIdentity`.)
enum Migration {
    /// MX Control's bundle id (v1.0.0 release).
    static let oldBundleID = "app.mxcontrol.Crossover"
    /// Where MX Control kept its Crossover key.
    static let oldKeychainServices = ["app.mxcontrol.Crossover.pairing"]
    private static let doneKey = "migratedFromMXControl"

    static func run() {
        guard let id = Bundle.main.bundleIdentifier, id != oldBundleID else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)

        // Settings (Crossover options, paired PCs, last battery levels). Window positions stay behind.
        var migrated = false
        if let old = defaults.persistentDomain(forName: oldBundleID), !old.isEmpty {
            var merged = defaults.persistentDomain(forName: id) ?? [:]
            for (k, v) in old where merged[k] == nil && !k.hasPrefix("NSWindow") && !k.hasPrefix("NSSplitView") {
                merged[k] = v
            }
            defaults.setPersistentDomain(merged, forName: id)
            migrated = true
        }

        let fm = FileManager.default
        // Device settings and button profiles.
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldSupport = support.appendingPathComponent("MX Control", isDirectory: true)
        let newSupport = support.appendingPathComponent("Keybridge", isDirectory: true)
        if fm.fileExists(atPath: oldSupport.path), !fm.fileExists(atPath: newSupport.path) {
            try? fm.moveItem(at: oldSupport, to: newSupport)
            migrated = true
        }
        // Files received over Crossover under the old name are temporary; drop them.
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? fm.removeItem(at: caches.appendingPathComponent(oldBundleID, isDirectory: true))

        // MX Control opened at login; keep doing that under the new name.
        if migrated, SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
    }
}
