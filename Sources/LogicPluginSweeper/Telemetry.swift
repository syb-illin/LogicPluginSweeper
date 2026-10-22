import Foundation

enum TelemetryValue: Encodable, Sendable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        }
    }
}

actor TelemetryClient {
    static let shared = TelemetryClient()

    private struct Event: Encodable, Sendable {
        let event: String
        let properties: [String: TelemetryValue]
        let timestamp: Date
        let distinctID: String

        enum CodingKeys: String, CodingKey {
            case event
            case properties
            case timestamp
            case distinctID = "distinct_id"
        }
    }

    private struct Batch: Encodable, Sendable {
        let apiKey: String
        let batch: [Event]

        enum CodingKeys: String, CodingKey {
            case apiKey = "api_key"
            case batch
        }
    }

    private let apiKey = "phc_ndRDwaMQNtPh9znNdUoJfBo2Ldrzf4Cr2gZKfRfWC4oz"
    private let endpoint = URL(string: "https://eu.i.posthog.com/batch/") ?? URL(fileURLWithPath: "/")
    private let session: URLSession
    private let defaults: UserDefaults
    private var events: [Event] = []
    private var flushTask: Task<Void, Never>?

    init(session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
    }

    func capture(_ name: String, properties: [String: TelemetryValue] = [:]) {
        guard isEnabled else { return }
        events.append(Event(event: name, properties: properties, timestamp: .now, distinctID: distinctID))
        guard events.count >= 10 else {
            scheduleFlush()
            return
        }
        flush()
    }

    func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard isEnabled, !events.isEmpty else {
            events.removeAll()
            return
        }

        let pending = events
        events.removeAll(keepingCapacity: true)
        let request = makeRequest(events: pending)
        Task { [session] in
            _ = try? await session.data(for: request)
        }
    }

    private var isEnabled: Bool {
        guard let value = defaults.object(forKey: "logicPluginSweeper.telemetryEnabled") as? Bool else { return true }
        return value
    }

    private var distinctID: String {
        if let value = defaults.string(forKey: "logicPluginSweeper.telemetryID"), !value.isEmpty { return value }
        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: "logicPluginSweeper.telemetryID")
        return value
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func makeRequest(events: [Event]) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(Batch(apiKey: apiKey, batch: events))
        return request
    }
}
