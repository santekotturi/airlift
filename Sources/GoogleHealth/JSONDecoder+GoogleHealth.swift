import Foundation

extension JSONDecoder {
    /// Shared decoder for Google OAuth + Health API payloads.
    ///
    /// The Health API is pre-GA and "built in public" — field additions are
    /// expected (PRD §4). We do **not** use `.convertFromSnakeCase` globally so
    /// each model can map keys explicitly and tolerate drift; date strings are
    /// handled per-field where they appear (civil times need offset-aware parsing,
    /// see `CivilTime`).
    static let googleHealth: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()
}
