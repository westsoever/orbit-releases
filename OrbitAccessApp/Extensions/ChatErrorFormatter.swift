import Foundation

enum ChatErrorFormatter {
    static func userMessage(for error: Error) -> String {
        if let bridgeError = error as? OrbitBridgeError {
            return message(for: bridgeError)
        }
        if let urlError = error as? URLError {
            return message(for: urlError)
        }
        let text = error.localizedDescription
        return friendlyServerMessage(text) ?? text
    }

    static func aiSetupMessage(for error: Error) -> String {
        if let preferencesError = error as? LLMPreferencesError {
            return preferencesError.localizedDescription
        }
        if error is CloudAIError {
            return cloudRegistrationMessage(for: error)
        }
        return userMessage(for: error)
    }

    static func relayRegistrationMessage(_ raw: String) -> String {
        friendlyServerMessage(raw) ?? raw
    }

    /// Plan 53 Phase 4 — the magic-link sign-in sheet.
    ///
    /// The relay speaks snake_case codes (`{"detail": {"error": "invalid_code"}}`), which
    /// `UserAuthService.errorMessage(from:)` unwraps and hands over raw. Those are wire
    /// codes, not user copy, so they are translated here rather than rendered. A network
    /// failure is answered separately: the relay being unreachable is the expected case
    /// while it is undeployed, and "sign-in failed" would be misleading.
    static func signInMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut:
                return "Could not reach the orbit relay. Sign-in needs it; everything else in orbit keeps working without it."
            case .notConnectedToInternet:
                return "No network connection. Sign-in needs one — orbit itself keeps capturing offline."
            default:
                return "Sign-in failed: \(urlError.localizedDescription)"
            }
        }
        guard case UserAuthError.registrationFailed(let raw) = error else {
            return userMessage(for: error)
        }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "invalid_code":
            return "That code is not right. Check the email and try again."
        case "code_expired":
            return "That code has expired. Send a new one."
        case "too_many_attempts":
            return "Too many attempts on this code. Send a new one."
        case "invalid_email":
            return "Enter a valid email address. Local-only orbit addresses cannot be used for a cloud account."
        case "rate_limit_exceeded":
            return "Too many codes requested today. Try again tomorrow."
        case "mail_delivery_failed":
            return "The relay could not send the email. Try again in a moment."
        case "relay_disabled":
            return "Cloud accounts are temporarily unavailable. Try again later."
        default:
            return friendlyServerMessage(raw) ?? "Sign-in failed: \(raw)"
        }
    }

    static func cloudRegistrationMessage(for error: Error) -> String {
        if let cloudError = error as? CloudAIError {
            return cloudError.localizedDescription
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut:
                return "Cloud AI service is unreachable. Start the relay (services/orbit-relay/run-local.sh) or set ORBIT_RELAY_URL."
            case .notConnectedToInternet:
                return "Cloud AI registration needs a network connection to reach the relay."
            default:
                return "Cloud AI registration failed: \(urlError.localizedDescription)"
            }
        }
        return userMessage(for: error)
    }

    static func isMissingCredentials(_ error: Error) -> Bool {
        let text: String
        if case OrbitBridgeError.serverMessage(let message) = error {
            text = message
        } else {
            text = error.localizedDescription
        }
        let lower = text.lowercased()
        return lower.contains("no ai credentials")
            || lower.contains("enable orbit cloud ai")
            || lower.contains("openrouter_api_key")
    }

    static func noChatAvailable(hasDatabase: Bool, hasDaemon: Bool) -> String {
        if !hasDatabase && !hasDaemon {
            return "Chat is unavailable while orbit is still starting. Wait a moment for the database and background service to load."
        }
        if !hasDatabase {
            return "Chat is unavailable because the orbit database is not ready yet. Retry from the notification in the bottom-left corner."
        }
        return "Chat is unavailable because orbit's background service is not responding. Quit and reopen the app, or use Retry in the sidebar."
    }

    private static func message(for error: OrbitBridgeError) -> String {
        switch error {
        case .invalidResponse:
            return "orbit returned an unexpected response. Quit and reopen the app to restart the background service."
        case .httpStatus(let code):
            switch code {
            case 503:
                return "orbit could not answer right now. Check that AI is configured (Cloud AI, an API key in ~/.orbit/.env, or a local Ollama model)."
            case 502, 504:
                return "orbit timed out while generating an answer. Try a shorter question or check your AI provider."
            default:
                return "orbit returned an error (HTTP \(code)). Quit and reopen the app if this keeps happening."
            }
        case .serverMessage(let message):
            return friendlyServerMessage(message) ?? message
        case .daemonOffline:
            return "orbit's background service is not responding. It starts automatically with the app — quit and reopen orbit if this persists."
        case .detectAlreadyRunning:
            // Chat never raises this; the case exists so detection's 409 stays distinct.
            return "orbit is already looking at your context."
        case .chatStreamStalled:
            // The safety net in `OrbitBridgeClient.chatStream` fired: the daemon answered
            // 200 and then went quiet without terminating the body. Name the log, because
            // unlike a model error there is nothing the user can reconfigure to fix it.
            return "orbit stopped responding part-way through the answer. Ask again — if it keeps happening, check ~/.orbit/daemon.log."
        }
    }

    private static func message(for error: URLError) -> String {
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
            return "Cannot reach orbit's background service yet. It should start automatically when you open the app — wait a moment and try again."
        case .timedOut:
            return "orbit took too long to respond. The daemon may be busy — try again."
        case .notConnectedToInternet:
            return "Network error while talking to orbit. The background service should be running on this Mac."
        default:
            return "Connection to orbit failed: \(error.localizedDescription)"
        }
    }

    private static func friendlyServerMessage(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("No AI credentials configured") {
            return trimmed
        }

        switch trimmed {
        case "relay_disabled":
            return "Cloud AI is temporarily unavailable. Try again later or add your own API key in ~/.orbit/.env."
        case "upstream_unavailable":
            return "The AI provider is temporarily unavailable. Try again in a few minutes."
        case "registration_limit_exceeded":
            return "Cloud AI registration limit reached. Try again tomorrow or add your own API key in ~/.orbit/.env."
        case "invalid_invite":
            return "Cloud AI registration failed: invalid invite code."
        case "install_id_already_registered":
            return "This Mac is already registered for Cloud AI. Open ~/.orbit/cloud.json or disable Cloud AI in Settings and try again."
        case "database unavailable":
            // The daemon's own 503 (`_require_db`, browser_bridge/server.py): it is answering
            // HTTP but has no open store. The app never opens the database itself any more, so
            // restarting the app cannot help and there is no "choose the file" flow to offer.
            return "orbit's daemon is running but could not open its context store. Stop and start the daemon from the sidebar, then check ~/.orbit/daemon.log."
        default:
            if trimmed.contains("rate_limit") || trimmed.contains("Daily cloud AI limit") {
                return "Daily Cloud AI limit reached. Try again tomorrow or add OPENROUTER_API_KEY to ~/.orbit/.env."
            }
            if trimmed.contains("Cloud AI session expired") {
                return trimmed
            }
            if trimmed.contains("Connection refused")
                || trimmed.contains("Failed to establish a new connection")
                || trimmed.contains("Connection error") {
                return "Could not reach the local AI model. If you use Ollama, run `ollama serve` and `ollama pull llama3.1`, or enable Cloud AI."
            }
            if trimmed.contains("model") && trimmed.contains("not found") {
                return "The configured local model was not found in Ollama. Run `ollama pull llama3.1` or set ORBIT_LOCAL_LLM_MODEL in ~/.orbit/.env."
            }
            if trimmed == trimmed.uppercased(), trimmed.contains("_") {
                return "orbit reported a problem: \(trimmed.replacingOccurrences(of: "_", with: " "))."
            }
            return nil
        }
    }
}
