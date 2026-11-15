import Foundation

/// Manages the user-configurable list of hidden applications.
/// Persists to UserDefaults so it survives app restarts.
class HiddenAppsManager: ObservableObject {
    static let shared = HiddenAppsManager()
    
    private let key = "hiddenAppNames"
    
    /// Default apps to hide on first launch. Machine-specific entries come from
    /// `GuavaDefaultHiddenApps` in Info.plist, populated by build.sh from local.config.
    private static var defaultHidden: Set<String> {
        let configured = Bundle.main.object(forInfoDictionaryKey: "GuavaDefaultHiddenApps") as? [String] ?? []
        return Set(configured).union(["Guava"])
    }
    
    @Published var hiddenNames: Set<String> {
        didSet { save() }
    }
    
    private init() {
        if let saved = UserDefaults.standard.stringArray(forKey: key) {
            hiddenNames = Set(saved)
        } else {
            hiddenNames = Self.defaultHidden
        }
    }
    
    func isHidden(_ appName: String) -> Bool {
        hiddenNames.contains(appName)
    }
    
    func hide(_ appName: String) {
        hiddenNames.insert(appName)
    }
    
    func unhide(_ appName: String) {
        hiddenNames.remove(appName)
    }
    
    private func save() {
        UserDefaults.standard.set(Array(hiddenNames), forKey: key)
    }
}
