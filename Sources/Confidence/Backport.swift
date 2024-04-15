import Foundation

public extension URL {
    struct Backport {
        var base: URL

        public init(base: URL) {
            self.base = base
        }
    }

    var backport: Backport {
        Backport(base: self)
    }
}

public extension URL.Backport {
    var path: String {
        if #available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *) {
            return self.base.path(percentEncoded: false)
        } else {
            return self.base.path
        }
    }

    func appending<S>(components: S...) -> URL where S: StringProtocol {
        if #available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *) {
            return components.reduce(self.base) { acc, cur in
                return acc.appending(component: cur)
            }
        } else {
            return components.reduce(self.base) { acc, cur in
                return acc.appendingPathComponent(String(cur))
            }
        }
    }
}

public extension Date {
    struct Backport {
    }

    static var backport: Backport.Type { Backport.self }
}

public extension Date.Backport {
    static var now: Date {
        if #available(macOS 12, iOS 15, tvOS 15, watchOS 8, *) {
            return Date.now
        } else {
            return Date()
        }
    }

    static var nowISOString: String {
        if #available(macOS 12, iOS 15, tvOS 15, watchOS 8, *) {
            return toISOString(date: Date.now)
        } else {
            return toISOString(date: Date())
        }
    }

    static func toISOString(date: Date) -> String {
        if #available(macOS 12, iOS 15, tvOS 15, watchOS 8, *) {
            return date.ISO8601Format()
        } else {
            let dateFormatter = DateFormatter()
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateFormatter.timeZone = TimeZone(abbreviation: "GMT")
            dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
            return dateFormatter.string(from: date).appending("Z")
        }
    }
}
