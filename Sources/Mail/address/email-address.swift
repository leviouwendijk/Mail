import Foundation
import Primitives

/// An RFC 5321 address (`local@domain`), limited to ASCII until SMTPUTF8 is supported.
public struct EmailAddress: CodableInvariant, Hashable, Sendable, CustomStringConvertible {
    public enum Error: Swift.Error, Sendable, Equatable {
        case empty
        case missingAt
        case emptyLocalPart
        case emptyDomain
        case emptyDomainLabel
        case localPartTooLong
        case domainTooLong
        case invalidCharacter(Character)
    }

    public let raw: String

    public init(
        _ raw: String
    ) throws(Error) {
        let candidate = raw.trimmingCharacters(
            in: .whitespaces
        )
        guard !candidate.isEmpty else {
            throw .empty
        }
        if let invalid = candidate.first(where: { !Self.isAllowed($0) }) {
            throw .invalidCharacter(invalid)
        }
        guard let at = candidate.lastIndex(of: "@") else {
            throw .missingAt
        }

        let local = candidate[..<at]
        let domain = candidate[candidate.index(after: at)...]

        guard !local.isEmpty else {
            throw .emptyLocalPart
        }
        guard local.utf8.count <= 64 else {
            throw .localPartTooLong
        }
        guard !domain.isEmpty else {
            throw .emptyDomain
        }
        guard domain.utf8.count <= 255 else {
            throw .domainTooLong
        }
        guard !domain.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty) else {
            throw .emptyDomainLabel
        }

        self.raw = candidate
    }

    public var localPart: Substring {
        raw[..<raw.lastIndex(of: "@")!]
    }

    public var domain: Substring {
        raw[raw.index(after: raw.lastIndex(of: "@")!)...]
    }

    public var description: String {
        raw
    }

    private static func isAllowed(
        _ character: Character
    ) -> Bool {
        guard character.isASCII, let scalar = character.asciiValue else {
            return false
        }
        switch scalar {
        case 0...32, 127:
            return false
        default:
            return !"<>(),;:\\\"[]".contains(character)
        }
    }
}
