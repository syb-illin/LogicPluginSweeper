import Foundation

public enum UpdateChannel: String, CaseIterable, Codable, Sendable {
    case stable
    case nightly
}

public struct SemanticVersion: Comparable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [Identifier]

    public enum Identifier: Codable, Hashable, Sendable {
        case numeric(Int)
        case textual(String)
    }

    public init?(tag: String) {
        let value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = value.first == "v" || value.first == "V" ? String(value.dropFirst()) : value
        let parts = withoutPrefix.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        let versionAndPrerelease = parts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let components = versionAndPrerelease[0].split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components.allSatisfy({ $0.allSatisfy { $0.isNumber } }),
              let major = Int(components[0]), let minor = Int(components[1]), let patch = Int(components[2]) else { return nil }

        self.major = major
        self.minor = minor
        self.patch = patch
        if versionAndPrerelease.count == 2 {
            let identifiers = versionAndPrerelease[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !identifiers.isEmpty, identifiers.allSatisfy({ !$0.isEmpty }) else { return nil }
            self.prerelease = identifiers.map { identifier in
                let value = String(identifier)
                return Int(value).map(Identifier.numeric) ?? .textual(value)
            }
        } else {
            self.prerelease = []
        }
    }

    public var description: String {
        let base = "\(major).\(minor).\(patch)"
        guard !prerelease.isEmpty else { return base }
        return base + "-" + prerelease.map { identifier in
            switch identifier { case .numeric(let value): String(value); case .textual(let value): value }
        }.joined(separator: ".")
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (left, right) {
            case let (.numeric(left), .numeric(right)): return left < right
            case (.numeric, .textual): return true
            case (.textual, .numeric): return false
            case let (.textual(left), .textual(right)): return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

public struct GitHubReleaseAsset: Codable, Hashable, Sendable {
    public let name: String
    public let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

public struct GitHubRelease: Codable, Hashable, Sendable {
    public let tagName: String
    public let name: String
    public let htmlURL: URL
    public let prerelease: Bool
    public let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case prerelease
        case assets
    }

    public var version: SemanticVersion? { SemanticVersion(tag: tagName) }

    public func preferredDownloadURL() -> URL { assets.first(where: { $0.name.hasSuffix(".dmg") })?.browserDownloadURL ?? assets.first(where: { $0.name.hasSuffix(".zip") })?.browserDownloadURL ?? htmlURL }
}

public struct UpdateOffer: Identifiable, Hashable, Sendable {
    public let id: String
    public let version: SemanticVersion
    public let releaseName: String
    public let releaseURL: URL
    public let downloadURL: URL
    public let prerelease: Bool

    public init(release: GitHubRelease) throws {
        guard let version = release.version else { throw ReleaseService.ReleaseServiceError.invalidVersion(release.tagName) }
        id = release.tagName
        self.version = version
        releaseName = release.name
        releaseURL = release.htmlURL
        downloadURL = release.preferredDownloadURL()
        prerelease = release.prerelease
    }
}

public struct ReleaseService: Sendable {
    public let repository: String
    private let session: URLSession

    public init(repository: String = "syb-illin/LogicPluginSweeper", session: URLSession = .shared) {
        self.repository = repository
        self.session = session
    }

    public func latestRelease(channel: UpdateChannel = .stable) async throws -> GitHubRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30") else { throw ReleaseServiceError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("LogicPluginSweeper/0.1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw ReleaseServiceError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        return try Self.selectLatest(releases: releases, channel: channel)
    }

    public static func selectLatest(releases: [GitHubRelease], channel: UpdateChannel) throws -> GitHubRelease {
        guard let release = releases
            .filter({ channel == .nightly ? $0.prerelease : !$0.prerelease })
            .compactMap({ release in release.version.map { ($0, release) } })
            .max(by: { $0.0 < $1.0 })?.1 else {
            throw ReleaseServiceError.noSemanticRelease
        }
        return release
    }

    public func updateOffer(currentVersion: SemanticVersion, channel: UpdateChannel = .stable) async throws -> UpdateOffer? {
        let release = try await latestRelease(channel: channel)
        guard let version = release.version, Self.isNewer(version, than: currentVersion, channel: channel) else { return nil }
        return try UpdateOffer(release: release)
    }

    public static func isNewer(_ available: SemanticVersion, than current: SemanticVersion, channel: UpdateChannel) -> Bool {
        if current < available { return true }
        guard channel == .nightly, current.prerelease.isEmpty, !available.prerelease.isEmpty else { return false }
        return (current.major, current.minor, current.patch) <= (available.major, available.minor, available.patch)
    }

    public enum ReleaseServiceError: Error, LocalizedError, Sendable {
        case invalidURL
        case httpStatus(Int)
        case noSemanticRelease
        case invalidVersion(String)

        public var errorDescription: String? {
            switch self {
            case .invalidURL: "URL GitHub invalide."
            case .httpStatus(let status): "GitHub a répondu avec le statut HTTP \(status)."
            case .noSemanticRelease: "Aucune release SemVer exploitable n’a été trouvée."
            case .invalidVersion(let value): "Version SemVer invalide : \(value)."
            }
        }
    }
}
