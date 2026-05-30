import CryptoKit
import Foundation
#if canImport(IOKit)
import IOKit
#endif

/// Produces a stable, privacy-preserving identifier for this Mac: the first 16
/// hex characters of `SHA-256(hardware UUID)`.
///
/// M2 names each machine's iCloud rollup file `{machine_id}.jsonl`, so the id
/// must be stable across reboots and reinstalls and collision-free across Macs.
/// The raw hardware UUID is hashed so it never leaves the device, and only the
/// truncated digest is persisted/used.
///
/// Implemented as a namespace of static functions (no stored state) so it is
/// trivially safe to call from any concurrency domain.
public enum MachineIdentity {
    /// `UserDefaults` key the computed id is cached under.
    public static let defaultsKey = "xyz.andybowu.Burnbar.machineId"

    /// The cached machine id, computing + persisting it on first use.
    ///
    /// - Parameters:
    ///   - defaults: Storage for the cached value (injectable for tests).
    ///   - hardwareUUID: Source of the raw hardware UUID (injectable for tests).
    /// - Returns: 16-char lowercase hex id, stable across reboots/reinstalls.
    public static func current(
        defaults: UserDefaults = .standard,
        hardwareUUID: () -> String? = readHardwareUUID
    ) -> String {
        if let cached = defaults.string(forKey: defaultsKey), cached.count == 16 {
            return cached
        }
        let id = machineID(fromUUID: hardwareUUID())
        defaults.set(id, forKey: defaultsKey)
        return id
    }

    /// Pure mapping: first 16 hex chars of `SHA-256(uuid)`. Derived only from the
    /// UUID — no timestamp or random salt — so it is identical across reinstalls.
    /// Falls back to a fixed sentinel when the UUID is unavailable (still
    /// deterministic per machine).
    static func machineID(fromUUID uuid: String?) -> String {
        let input = uuid ?? "burnbar-unknown-hardware-uuid"
        let digest = SHA256.hash(data: Data(input.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    /// Read `IOPlatformUUID` from the `IOPlatformExpertDevice` IOKit node.
    public static func readHardwareUUID() -> String? {
        #if canImport(IOKit)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(
            service,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        ) else { return nil }
        return property.takeRetainedValue() as? String
        #else
        return nil
        #endif
    }
}
