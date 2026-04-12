import Combine
import Foundation

extension Notification.Name {
    static let ghosttyTemplatesDidChange = Notification.Name("GhosttyTemplatesDidChange")
}

final class TemplateStore: ObservableObject {
    var templates: [StoredTemplate] { storedTemplates }

    struct StoredTemplate: Identifiable {
        let path: String
        let template: SessionTemplate

        var id: String { template.id }
        var name: String { template.name }
        var updatedAt: Date { template.updatedAt }
        var windowCount: Int { template.windows.count }
        var tabCount: Int { template.windows.flatMap(\.tabs).count }
    }

    private var storedTemplates: [StoredTemplate] = []
    private var changeObserver: NSObjectProtocol?
    private var suppressedNotificationPath: String?

    init() {
        changeObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyTemplatesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            if self.consumeSuppressedNotificationReload(note.object) {
                return
            }
            self.loadTemplates()
        }
    }

    deinit {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
    }

    func loadTemplates() {
        let fileManager = FileManager.default

        guard let urls = try? fileManager.contentsOfDirectory(
            at: Self.templatesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            replaceTemplates([], notifyObservers: true)
            return
        }

        replaceTemplates(
            urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard
                    let data = try? Data(contentsOf: url),
                    let template = try? Self.jsonDecoder.decode(SessionTemplate.self, from: data)
                else {
                    return nil
                }

                return StoredTemplate(path: url.path, template: template)
            }
            .sorted { lhs, rhs in
                let nameCompare = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if nameCompare != .orderedSame {
                    return nameCompare == .orderedAscending
                }
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            },
            notifyObservers: true
        )
    }

    @discardableResult
    func save(template: SessionTemplate) throws -> StoredTemplate {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: Self.templatesDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let existing = storedTemplates.first(where: { $0.id == template.id })?.template
        let now = Date()
        var writableTemplate = template
        writableTemplate.kind = "template"
        writableTemplate.version = SessionTemplate.currentVersion
        writableTemplate.createdAt = existing?.createdAt ?? template.createdAt
        writableTemplate.updatedAt = now

        let url = Self.templatesDirectory.appendingPathComponent("\(writableTemplate.id).json")
        let data = try Self.jsonEncoder.encode(writableTemplate)
        try data.write(to: url, options: [.atomic])

        let stored = StoredTemplate(path: url.path, template: writableTemplate)
        upsertTemplate(stored, notifyObservers: true)
        suppressNextNotificationReload(for: url)
        NotificationCenter.default.post(name: .ghosttyTemplatesDidChange, object: url)
        return stored
    }

    /// Writes the template to disk without posting a notification or reloading the store.
    /// Use this for debounced auto-save during editing to avoid the save→reload→re-render
    /// oscillation cycle.
    @discardableResult
    func silentSave(template: SessionTemplate) throws -> StoredTemplate {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: Self.templatesDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let existing = storedTemplates.first(where: { $0.id == template.id })?.template
        let now = Date()
        var writableTemplate = template
        writableTemplate.kind = "template"
        writableTemplate.version = SessionTemplate.currentVersion
        writableTemplate.createdAt = existing?.createdAt ?? template.createdAt
        writableTemplate.updatedAt = now

        let url = Self.templatesDirectory.appendingPathComponent("\(writableTemplate.id).json")
        let data = try Self.jsonEncoder.encode(writableTemplate)
        try data.write(to: url, options: [.atomic])

        let stored = StoredTemplate(path: url.path, template: writableTemplate)
        upsertTemplate(stored, notifyObservers: false)
        return stored
    }

    func delete(template: StoredTemplate) throws {
        let url = URL(fileURLWithPath: template.path)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        removeTemplate(id: template.id, notifyObservers: true)
        suppressNextNotificationReload(for: url)
        NotificationCenter.default.post(name: .ghosttyTemplatesDidChange, object: url)
    }

    @discardableResult
    func duplicate(template: StoredTemplate) throws -> StoredTemplate {
        var copy = template.template
        copy.id = UUID().uuidString.lowercased()
        copy.name = "\(template.name) (Copy)"
        copy.createdAt = Date()
        copy.updatedAt = copy.createdAt
        return try save(template: copy)
    }

    private func replaceTemplates(_ templates: [StoredTemplate], notifyObservers: Bool) {
        if notifyObservers {
            objectWillChange.send()
        }
        storedTemplates = templates
    }

    private func upsertTemplate(_ template: StoredTemplate, notifyObservers: Bool) {
        var nextTemplates = storedTemplates
        if let idx = nextTemplates.firstIndex(where: { $0.id == template.id }) {
            nextTemplates[idx] = template
        } else {
            nextTemplates.append(template)
        }
        nextTemplates.sort { lhs, rhs in
            let nameCompare = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameCompare != .orderedSame {
                return nameCompare == .orderedAscending
            }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
        replaceTemplates(nextTemplates, notifyObservers: notifyObservers)
    }

    private func removeTemplate(id: String, notifyObservers: Bool) {
        replaceTemplates(
            storedTemplates.filter { $0.id != id },
            notifyObservers: notifyObservers
        )
    }

    private func suppressNextNotificationReload(for url: URL) {
        suppressedNotificationPath = url.path
    }

    private func consumeSuppressedNotificationReload(_ object: Any?) -> Bool {
        guard let suppressedNotificationPath else { return false }
        guard let url = object as? URL, url.path == suppressedNotificationPath else {
            return false
        }
        self.suppressedNotificationPath = nil
        return true
    }
}

extension TemplateStore {
    static let templatesDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config")
        .appendingPathComponent("ghostty")
        .appendingPathComponent("templates")

    static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(templateTimestampFormatter.string(from: date))
        }
        return encoder
    }()

    static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = templateTimestampFormatter.date(from: value) {
                return date
            }
            if let date = SessionStore.parsedTimestampFormatter.date(from: value) {
                return date
            }
            if let date = SessionStore.parsedTimestampFormatterNoFraction.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid template timestamp: \(value)"
            )
        }
        return decoder
    }()

    private static let templateTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
