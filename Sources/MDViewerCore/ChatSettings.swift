import Foundation

/// A model Claude Code offers, as it lists them when it starts (in its answer
/// to initialize), with what the model can do.
public struct ClaudeModel: Codable, Equatable, Sendable {
    /// What `--model` takes: "default", "opus", "haiku".
    public let value: String
    public let displayName: String
    /// For example "Opus 4.8 · Most capable for complex work".
    public let description: String?
    /// The levels `--effort` takes for this model; empty when it has none.
    public let effortLevels: [String]
    public let supportsAutoMode: Bool

    public init(value: String, displayName: String, description: String?, effortLevels: [String], supportsAutoMode: Bool) {
        self.value = value
        self.displayName = displayName
        self.description = description
        self.effortLevels = effortLevels
        self.supportsAutoMode = supportsAutoMode
    }

    /// The model behind the choice, for people: "Sonnet 4.6" rather than
    /// "Default (recommended)". Taken from the description's first part.
    public var name: String {
        if let first = descriptionParts.first { return first }
        return displayName.replacingOccurrences(of: " (recommended)", with: "")
    }

    /// The rest of the description: "Best for everyday tasks".
    public var summary: String? {
        let rest = descriptionParts.dropFirst()
        return rest.isEmpty ? nil : rest.joined(separator: " · ")
    }

    private var descriptionParts: [String] {
        (description ?? "").components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    init?(json: JSONValue) {
        guard let value = json["value"]?.string else { return nil }
        self.init(value: value, displayName: json["displayName"]?.string ?? value, description: json["description"]?.string,
                  effortLevels: (json["supportedEffortLevels"]?.array ?? []).compactMap(\.string),
                  supportsAutoMode: json["supportsAutoMode"]?.bool ?? false)
    }
}

/// How Claude Code is started: nil and false mean its own defaults.
public struct LaunchOptions: Equatable, Sendable {
    public var model: String?
    public var effort: String?
    public var autoMode: Bool

    public init(model: String? = nil, effort: String? = nil, autoMode: Bool = false) {
        self.model = model
        self.effort = effort
        self.autoMode = autoMode
    }
}

/// The model, effort and mode the user chose in the chat, remembered between launches.
public struct ChatSettings: Codable, Equatable, Sendable {
    public var model: String
    /// nil: the model's own default effort.
    public var effort: String?
    /// On: Claude Code's Auto mode approves routine actions itself. Off: it asks.
    public var autoMode: Bool

    public init(model: String = "default", effort: String? = nil, autoMode: Bool = false) {
        self.model = model
        self.effort = effort
        self.autoMode = autoMode
    }

    /// What to start Claude Code with. A choice the chosen model can't take
    /// (an effort level it lacks, Auto mode on Haiku) is left out rather than
    /// failing; until Claude Code has listed its models, the choices are passed as they are.
    public func launchOptions(models: [ClaudeModel]) -> LaunchOptions {
        let model = self.model == "default" ? nil : self.model
        guard let chosen = models.first(where: { $0.value == self.model }) else {
            return LaunchOptions(model: model, effort: effort, autoMode: autoMode)
        }
        return LaunchOptions(model: model,
                             effort: effort.flatMap { chosen.effortLevels.contains($0) ? $0 : nil },
                             autoMode: autoMode && chosen.supportsAutoMode)
    }
}
