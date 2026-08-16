import Foundation

extension Date {
    static let orbitDisplayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var orbitDisplayString: String {
        Self.orbitDisplayFormatter.string(from: self)
    }
}

extension String {
    var orbitParsedDate: Date? {
        ISO8601DateFormatter().date(from: self)
            ?? Self.orbitSQLiteFormatter.date(from: self)
    }

    private static let orbitSQLiteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
