import Foundation

enum OrbitIssue: Equatable, Identifiable {
    /// The one blocking condition the app can still hit: its background service is not
    /// answering on localhost. It used to be `databaseBootstrapFailed`, which surfaced raw
    /// SQLite text ("SQLite error 26: file is not a database …") for a database this app no
    /// longer opens at all (plan 51 decision D1). No storage-layer detail reaches the UI.
    case daemonUnreachable(message: String)

    var id: String {
        switch self {
        case .daemonUnreachable(let message):
            return "daemon-unreachable-\(message)"
        }
    }

    var message: String {
        switch self {
        case .daemonUnreachable(let message):
            return message
        }
    }

    var actionTitle: String? {
        switch self {
        case .daemonUnreachable:
            return "Retry"
        }
    }
}
