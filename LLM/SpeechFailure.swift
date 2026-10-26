import Foundation

/// Preserve the domain/code and underlying cause instead of a generic NSError sentence.
enum SpeechFailure {
    static func describe(_ error: Error, stage: String) -> String {
        var details = [stage]
        var current = error as NSError
        for _ in 0..<4 {
            details.append("\(current.localizedDescription) [\(current.domain): \(current.code)]")
            if let reason = current.localizedFailureReason { details.append(reason) }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return details.joined(separator: "\n")
    }
}
