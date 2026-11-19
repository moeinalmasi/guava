import Foundation

/// Manages the user-configurable list of hidden applications.
/// Persists to UserDefaults so it survives app restarts.
class HiddenAppsManager: ObservableObject {
    static let shared = HiddenAppsManager()
    
    private let key = "hiddenAppNames"
    private let appliedDefaultsKey = "appliedDefaultHiddenApps"
    
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
        let defaults = Self.defaultHidden
        if let saved = UserDefaults.standard.stringArray(forKey: key) {
            // Hide defaults added to local.config since the last launch, once,
            // so apps the user later unhides stay visible.
            let applied = Set(UserDefaults.standard.stringArray(forKey: appliedDefaultsKey) ?? saved)
            hiddenNames = Set(saved).union(defaults.subtracting(applied))
        } else {
            hiddenNames = defaults
        }
        UserDefaults.standard.set(Array(defaults), forKey: appliedDefaultsKey)
        save()
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
