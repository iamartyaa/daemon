import Foundation

/// What the Keep hotkey should do, decided from what's in front (PRD "Save", first match wins).
public enum KeepAction: Equatable, Sendable {
    case voice, text, files, link, region, ignore
}

public struct ContextSnapshot: Equatable, Sendable {
    public var heldPastThreshold = false
    public var isExcluded = false
    public var frontmostBundleID: String?
    public var selectedText: String?
    public var finderSelection: [URL] = []
    public var pageURL: URL?             // nil when not a browser or the URL couldn't be read (Firefox)

    public init(heldPastThreshold: Bool = false, isExcluded: Bool = false, frontmostBundleID: String? = nil,
                selectedText: String? = nil, finderSelection: [URL] = [], pageURL: URL? = nil) {
        self.heldPastThreshold = heldPastThreshold; self.isExcluded = isExcluded
        self.frontmostBundleID = frontmostBundleID; self.selectedText = selectedText
        self.finderSelection = finderSelection; self.pageURL = pageURL
    }
}

public enum ContextRules {
    public static let holdThreshold: Duration = .milliseconds(400)
    static let finderBundleID = "com.apple.finder"

    public static func decide(_ s: ContextSnapshot) -> KeepAction {
        if s.isExcluded { return .ignore }
        if s.heldPastThreshold { return .voice }
        if let text = s.selectedText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .text }
        if s.frontmostBundleID == finderBundleID, !s.finderSelection.isEmpty { return .files }
        if Browser(bundleID: s.frontmostBundleID) != nil, s.pageURL != nil { return .link }
        return .region
    }
}

/// Known browsers and how to ask each for its page over AppleScript.
public enum Browser: Equatable, Sendable {
    case safariLike   // `front document` has URL and name
    case chromium     // `active tab of front window` has URL and title
    case firefox      // no AppleScript URL

    static let byBundleID: [String: Browser] = [
        "com.apple.Safari": .safariLike,
        "com.apple.SafariTechnologyPreview": .safariLike,
        "com.kagi.kagimacOS": .safariLike,          // Orion
        "com.google.Chrome": .chromium,
        "com.google.Chrome.canary": .chromium,
        "company.thebrowser.Browser": .chromium,   // Arc
        "com.brave.Browser": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "org.mozilla.firefox": .firefox,
    ]

    public init?(bundleID: String?) {
        guard let id = bundleID, let browser = Self.byBundleID[id] else { return nil }
        self = browser
    }

    /// AppleScript returning {url, title}, or nil when the browser has none.
    func pageScript(bundleID: String) -> String? {
        switch self {
        case .safariLike: "tell application id \"\(bundleID)\" to return {URL, name} of front document"
        case .chromium: "tell application id \"\(bundleID)\" to return {URL, title} of active tab of front window"
        case .firefox: nil
        }
    }

    /// Safari exposes selected page text over Accessibility; Chromium and Firefox need the ⌘C fallback.
    var accessibilitySelectionIsReliable: Bool { self == .safariLike }
}

/// Apps where Keep does nothing. Seeded with password managers; the whole list is user-editable.
public struct ExcludedApps {
    public static let defaultBundleIDs = [
        "com.1password.1password",      // 1Password 8
        "com.agilebits.onepassword7",   // 1Password 7
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
    ]
    static let key = "excludedApps"
    private let store: UserDefaults

    public init(store: UserDefaults = .standard) {
        self.store = store
        store.register(defaults: [Self.key: Self.defaultBundleIDs])
    }

    public var bundleIDs: [String] { store.stringArray(forKey: Self.key) ?? [] }

    public func contains(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains(bundleID)
    }

    public func add(_ bundleID: String) {
        guard !contains(bundleID) else { return }
        store.set(bundleIDs + [bundleID], forKey: Self.key)
    }

    public func remove(_ bundleID: String) {
        store.set(bundleIDs.filter { $0 != bundleID }, forKey: Self.key)
    }
}
