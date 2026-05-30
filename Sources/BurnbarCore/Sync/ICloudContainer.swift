import Foundation

/// Where Burnbar's cross-device rollups live.
public enum ICloudLocation: Equatable, Sendable {
    /// The app's iCloud ubiquity container's `Burnbar/` directory (best case).
    case container(URL)
    /// `~/Library/Mobile Documents/com~apple~CloudDocs/Burnbar/` — used when the
    /// ubiquity container isn't provisioned but iCloud Drive is enabled.
    case fallback(URL)
    /// Neither location is reachable (iCloud Drive disabled / signed out).
    case unavailable(reason: String)

    /// The resolved `Burnbar/` directory URL, or `nil` when unavailable.
    public var url: URL? {
        switch self {
        case let .container(url), let .fallback(url): return url
        case .unavailable: return nil
        }
    }
}

/// Resolves the `Burnbar/` directory inside iCloud Drive, with a defined
/// fallback chain and a clear unavailable state. Path detection only — writing,
/// atomicity, and scheduling are later 2.2.x sub-tickets.
///
/// All filesystem touchpoints are injected so every branch is unit-testable
/// without a real iCloud account.
public struct ICloudContainer: Sendable {
    private let ubiquityURLProvider: @Sendable () -> URL?
    private let homeDirectory: URL
    private let directoryExists: @Sendable (URL) -> Bool
    private let makeDirectory: @Sendable (URL) throws -> Void

    public init(
        ubiquityURLProvider: @escaping @Sendable ()
            -> URL? = { FileManager.default.url(forUbiquityContainerIdentifier: nil) },
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        directoryExists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        makeDirectory: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }
    ) {
        self.ubiquityURLProvider = ubiquityURLProvider
        self.homeDirectory = homeDirectory
        self.directoryExists = directoryExists
        self.makeDirectory = makeDirectory
    }

    /// Resolve the `Burnbar/` directory. The ubiquity lookup can block, so call
    /// this **off the main thread**.
    public func resolve() -> ICloudLocation {
        // 1. The app's ubiquity container (preferred).
        if let ubiquity = ubiquityURLProvider() {
            let dir = ubiquity.appendingPathComponent("Burnbar", isDirectory: true)
            do {
                try makeDirectory(dir)
                return .container(dir)
            } catch {
                return .unavailable(reason: "iCloud container is not writable: \(error.localizedDescription)")
            }
        }

        // 2. The user's iCloud Drive folder, if present.
        let cloudDocs = homeDirectory
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if directoryExists(cloudDocs) {
            let dir = cloudDocs.appendingPathComponent("Burnbar", isDirectory: true)
            do {
                try makeDirectory(dir)
                return .fallback(dir)
            } catch {
                return .unavailable(reason: "iCloud Drive folder is not writable: \(error.localizedDescription)")
            }
        }

        // 3. Nothing reachable.
        return .unavailable(
            reason: "iCloud unavailable — neither the ubiquity container nor iCloud Drive is reachable."
        )
    }
}
