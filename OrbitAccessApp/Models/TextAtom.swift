import Foundation

/// Row shape of `text_atoms`. The GRDB record conformances were dropped with the direct
/// SQLite reads (plan 51 decision D1); the app now receives atoms as `SearchHit` over HTTP.
struct TextAtom: Codable, Identifiable, Sendable {
    let id: Int64
    let eventId: Int64
    let role: String
    let label: String?
    let text: String
    let elementPath: String
    let elementHash: String?

    enum CodingKeys: String, CodingKey {
        case id, role, label, text
        case eventId = "event_id"
        case elementPath = "element_path"
        case elementHash = "element_hash"
    }
}
