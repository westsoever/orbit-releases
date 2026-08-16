import Foundation

/// Decoded straight off `GET /api/score/inputs` (`docs/bridge-api-additions.md` route 4).
/// The four inputs are computed by the daemon; the 0–10 arithmetic below stays in Swift.
struct ScoreInputs: Sendable, Decodable {
    let taskCompletion: Double
    let focusDepth: Double
    let contextRichness: Double
    let captureConsistency: Double

    enum CodingKeys: String, CodingKey {
        case taskCompletion = "task_completion"
        case focusDepth = "focus_depth"
        case contextRichness = "context_richness"
        case captureConsistency = "capture_consistency"
    }
}

struct ProductivityScore: Sendable {
    let value: Double
    let inputs: ScoreInputs

    init(inputs: ScoreInputs) {
        self.inputs = inputs
        self.value = productivityScore(inputs)
    }
}

func productivityScore(_ inputs: ScoreInputs) -> Double {
    let raw = 0.35 * inputs.taskCompletion
        + 0.25 * inputs.focusDepth
        + 0.20 * inputs.contextRichness
        + 0.20 * inputs.captureConsistency
    return (raw * 10).rounded(toPlaces: 1)
}
