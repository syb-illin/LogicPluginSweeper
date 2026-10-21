import Foundation

enum TelemetrySizeBucket {
    static func label(for bytes: Int64) -> String {
        switch bytes {
        case ..<10_000_000: "0_10MB"
        case ..<100_000_000: "10_100MB"
        case ..<1_000_000_000: "100MB_1GB"
        default: "1GB_plus"
        }
    }
}
