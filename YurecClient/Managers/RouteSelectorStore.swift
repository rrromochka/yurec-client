import Foundation

/// A selectable sing-box outbound group discovered directly from a profile.
///
/// The model intentionally contains no provider, country, or subscription
/// knowledge. Display labels and ordering come from the profile itself.
struct RouteSelectorDescriptor: Equatable {
    let tag: String
    let options: [String]
    let configDefault: String?
}

/// Describes a saved route that disappeared after a subscription refresh.
///
/// `fallbackOption` is nil when the refreshed profile removed the entire
/// selector rather than just the selected option.
struct RouteSelectionFallback: Equatable {
    let selectorTag: String
    let unavailableOption: String
    let fallbackOption: String?
}

/// A validated explicit choice captured before a subscription refresh starts.
struct PersistedRouteSelection: Equatable {
    let selectorTag: String
    let option: String
}

/// Reads and updates the standard sing-box `selector` outbound format.
enum RouteSelectorConfig {
    enum Error: LocalizedError {
        case invalidJSON

        var errorDescription: String? {
            "Profile config is not valid JSON."
        }
    }

    static func selectors(in data: Data) throws -> [RouteSelectorDescriptor] {
        guard let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.invalidJSON
        }
        return selectors(in: config)
    }

    static func selectors(in config: [String: Any]) -> [RouteSelectorDescriptor] {
        let outbounds = (config["outbounds"] as? [[String: Any]]) ?? []
        var seenTags = Set<String>()
        return outbounds.compactMap { outbound in
            guard (outbound["type"] as? String) == "selector",
                  let tag = outbound["tag"] as? String,
                  !tag.isEmpty,
                  seenTags.insert(tag).inserted else {
                return nil
            }

            let rawOptions = (outbound["outbounds"] as? [String]) ?? []
            var seen = Set<String>()
            let options = rawOptions.filter { !$0.isEmpty && seen.insert($0).inserted }
            guard !options.isEmpty else { return nil }

            let declaredDefault = outbound["default"] as? String
            let configDefault = declaredDefault.flatMap { options.contains($0) ? $0 : nil }
            return RouteSelectorDescriptor(tag: tag, options: options, configDefault: configDefault)
        }
    }

    /// Applies validated choices to selector outbounds in a runtime config.
    /// Invalid or stale choices are ignored rather than making sing-box fail.
    @discardableResult
    static func apply(defaults: [String: String], to config: inout [String: Any]) -> Bool {
        guard !defaults.isEmpty,
              var outbounds = config["outbounds"] as? [[String: Any]] else {
            return false
        }

        var changed = false
        for index in outbounds.indices {
            guard (outbounds[index]["type"] as? String) == "selector",
                  let tag = outbounds[index]["tag"] as? String,
                  let selected = defaults[tag],
                  let options = outbounds[index]["outbounds"] as? [String],
                  options.contains(selected) else {
                continue
            }

            if (outbounds[index]["default"] as? String) != selected {
                outbounds[index]["default"] = selected
                changed = true
            }
        }

        if changed {
            config["outbounds"] = outbounds
        }
        return changed
    }
}

/// Stores a route choice per profile and selector tag.
///
/// Subscription updates remain authoritative: when an option disappears, the
/// stale saved value is discarded and the new config default (or first option)
/// becomes effective automatically.
final class RouteSelectorStore {
    static let shared = RouteSelectorStore()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func selectors(for profileURL: URL) -> [RouteSelectorDescriptor] {
        guard let data = try? Data(contentsOf: profileURL) else { return [] }
        return (try? RouteSelectorConfig.selectors(in: data)) ?? []
    }

    func selectedOption(for selector: RouteSelectorDescriptor, profileURL: URL) -> String? {
        let key = selectionKey(profileURL: profileURL, selectorTag: selector.tag)
        if let stored = defaults.string(forKey: key) {
            if selector.options.contains(stored) {
                return stored
            }
            defaults.removeObject(forKey: key)
        }
        return selector.configDefault ?? selector.options.first
    }

    func setSelectedOption(_ option: String, selectorTag: String, profileURL: URL) {
        defaults.set(option, forKey: selectionKey(profileURL: profileURL, selectorTag: selectorTag))
    }

    func resolvedDefaults(for profileURL: URL) -> [String: String] {
        resolvedDefaults(for: profileURL, selectors: selectors(for: profileURL))
    }

    func resolvedDefaults(
        for profileURL: URL,
        selectors: [RouteSelectorDescriptor]
    ) -> [String: String] {
        Dictionary(uniqueKeysWithValues: selectors.compactMap { selector in
            selectedOption(for: selector, profileURL: profileURL).map { (selector.tag, $0) }
        })
    }

    /// Captures only explicit choices, not implicit server-side defaults.
    ///
    /// The snapshot is taken before the asynchronous download starts so a file
    /// watcher cannot erase a stale choice before fallback UX is generated.
    func persistedSelectionSnapshot(
        for selectors: [RouteSelectorDescriptor],
        profileURL: URL
    ) -> [PersistedRouteSelection] {
        selectors.compactMap { selector in
            let key = selectionKey(profileURL: profileURL, selectorTag: selector.tag)
            guard let stored = defaults.string(forKey: key),
                  selector.options.contains(stored) else {
                return nil
            }
            return PersistedRouteSelection(selectorTag: selector.tag, option: stored)
        }
    }

    /// Reconciles persisted choices after a subscription replaced the profile.
    ///
    /// Choices that still exist are preserved. A choice that disappeared is
    /// removed so the refreshed config's declared default (or first option)
    /// becomes authoritative, and a result is returned for user-facing UX.
    func reconcileSelectionsAfterRefresh(
        previousSelections: [PersistedRouteSelection],
        refreshedSelectors: [RouteSelectorDescriptor],
        profileURL: URL
    ) -> [RouteSelectionFallback] {
        let refreshedByTag = Dictionary(
            uniqueKeysWithValues: refreshedSelectors.map { ($0.tag, $0) }
        )

        return previousSelections.compactMap { previous in
            let key = selectionKey(profileURL: profileURL, selectorTag: previous.selectorTag)

            guard let refreshed = refreshedByTag[previous.selectorTag] else {
                defaults.removeObject(forKey: key)
                return RouteSelectionFallback(
                    selectorTag: previous.selectorTag,
                    unavailableOption: previous.option,
                    fallbackOption: nil
                )
            }

            guard !refreshed.options.contains(previous.option) else { return nil }
            defaults.removeObject(forKey: key)
            return RouteSelectionFallback(
                selectorTag: previous.selectorTag,
                unavailableOption: previous.option,
                fallbackOption: refreshed.configDefault ?? refreshed.options.first
            )
        }
    }

    private func selectionKey(profileURL: URL, selectorTag: String) -> String {
        "routeSelector_\(profileURL.standardizedFileURL.absoluteString)_\(selectorTag)"
    }
}
