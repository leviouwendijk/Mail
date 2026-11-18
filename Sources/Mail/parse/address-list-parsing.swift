import Foundation
import Parsing

public extension NamedAddress {
    /// Parses an address-list header leniently: groups are flattened, a comment
    /// names a bare address, and entries that are not valid addresses are skipped.
    static func parseList(
        _ header: String
    ) -> [NamedAddress] {
        guard let tokens = MailGrammar.AddressTokens().parseComplete(header) else {
            return []
        }

        var entries: [NamedAddress] = []
        var phrase: [String] = []
        var angle: String?
        var comment: String?

        func flush() {
            defer {
                phrase = []
                angle = nil
                comment = nil
            }
            let name = phrase.isEmpty ? comment : phrase.joined(separator: " ")
            let address = angle ?? (phrase.count == 1 ? phrase[0] : nil)
            guard let address else {
                return
            }
            let display = angle == nil ? comment : name
            if let entry = try? NamedAddress(address, name: display.map(MIMEEncoding.decodeEncodedWords)) {
                entries.append(entry)
            }
        }

        for token in tokens {
            switch token {
            case .quoted(let text), .word(let text):
                phrase.append(text)
            case .comment(let text):
                comment = text.trimmingCharacters(in: .whitespaces)
            case .angle(let address):
                angle = address
            case .special(":"):
                // A group's display name; its members follow.
                phrase = []
            case .special:
                flush()
            }
        }
        flush()
        return entries
    }
}
