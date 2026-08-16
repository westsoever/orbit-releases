import Foundation

/// Row shape of `context_events`. GRDB record conformances dropped with the direct SQLite
/// reads (plan 51 decision D1).
struct ContextEvent: Codable, Identifiable, Sendable {
    let id: Int64
    let userId: String?
    let timestamp: String
    let appBundleId: String?
    let appName: String?
    let windowTitle: String?
    let focusedElementRole: String?
    let focusedElementLabel: String?
    let visibleText: String?
    let rawJson: String?
    let captureMethod: String?
    let captureTier: Int?
    let pageUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, timestamp
        case userId = "user_id"
        case appBundleId = "app_bundle_id"
        case appName = "app_name"
        case windowTitle = "window_title"
        case focusedElementRole = "focused_element_role"
        case focusedElementLabel = "focused_element_label"
        case visibleText = "visible_text"
        case rawJson = "raw_json"
        case captureMethod = "capture_method"
        case captureTier = "capture_tier"
        case pageUrl = "page_url"
    }
}
