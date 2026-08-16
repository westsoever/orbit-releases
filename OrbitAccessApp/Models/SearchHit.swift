import Foundation

struct SearchHit: Codable, Identifiable, Sendable {
    let atomId: Int
    let eventId: Int
    let atomUri: String
    let eventUri: String
    let appBundleId: String
    let appName: String
    let windowTitle: String?
    let timestamp: String
    let role: String
    let label: String?
    let snippetHtml: String
    let score: Double

    var id: Int { atomId }

    enum CodingKeys: String, CodingKey {
        case atomId = "atom_id"
        case eventId = "event_id"
        case atomUri = "atom_uri"
        case eventUri = "event_uri"
        case appBundleId = "app_bundle_id"
        case appName = "app_name"
        case windowTitle = "window_title"
        case timestamp, role, label
        case snippetHtml = "snippet_html"
        case score
    }
}
