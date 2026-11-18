import Foundation

public enum MIMEEncoding {
    public static let crlf = "\r\n"
    public static let maximumLineLength = 76

    /// Base64 wrapped at 76 columns (RFC 2045 §6.8).
    public static func base64(
        _ data: Data
    ) -> String {
        data.base64EncodedString(
            options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]
        )
    }

    /// Quoted-printable with CRLF line breaks and soft breaks at 76 columns (RFC 2045 §6.7).
    public static func quotedPrintable(
        _ text: String
    ) -> String {
        normalizedLines(text)
            .map(quotedPrintableLine)
            .joined(separator: crlf)
    }

    /// Header text as-is when it is printable ASCII, otherwise as RFC 2047 `B` encoded words.
    public static func encodedWord(
        _ text: String
    ) -> String {
        if isPrintableASCII(text) {
            return text
        }

        // 75 characters per word minus the 12 of `=?UTF-8?B??=` leaves 63; 45 bytes encode to 60.
        var words: [String] = []
        var chunk = Data()
        for character in text {
            let bytes = Data(String(character).utf8)
            if chunk.count + bytes.count > 45 {
                words.append(encodedWordChunk(chunk))
                chunk = Data()
            }
            chunk.append(bytes)
        }
        if !chunk.isEmpty {
            words.append(encodedWordChunk(chunk))
        }
        return words.joined(separator: crlf + " ")
    }

    /// A display name as an atom, a quoted string, or encoded words.
    public static func displayName(
        _ name: String
    ) -> String {
        guard isPrintableASCII(name) else {
            return encodedWord(name)
        }
        let atomSafe = name.allSatisfy { character in
            character.isLetter || character.isNumber || " !#$%&'*+-/=?^_`{|}~".contains(character)
        }
        if atomSafe {
            return name
        }
        let escaped = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    public static func isPrintableASCII(
        _ text: String
    ) -> Bool {
        text.utf8.allSatisfy { (0x20...0x7E).contains($0) }
    }

    static func normalizedLines(
        _ text: String
    ) -> [Substring] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
    }

    private static func encodedWordChunk(
        _ data: Data
    ) -> String {
        "=?UTF-8?B?\(data.base64EncodedString())?="
    }

    private static func quotedPrintableLine(
        _ line: Substring
    ) -> String {
        let bytes = Array(line.utf8)
        var output = ""
        var column = 0

        for (index, byte) in bytes.enumerated() {
            let isLast = index == bytes.count - 1
            let token: String
            switch byte {
            case 0x20, 0x09:
                token = isLast ? hexEscape(byte) : String(UnicodeScalar(byte))
            case 33...60, 62...126:
                token = String(UnicodeScalar(byte))
            default:
                token = hexEscape(byte)
            }

            // Leave room for the soft break `=` unless this token ends the line.
            let limit = isLast ? maximumLineLength : maximumLineLength - 1
            if column + token.count > limit {
                output += "=" + crlf
                column = 0
            }
            output += token
            column += token.count
        }
        return output
    }

    private static func hexEscape(
        _ byte: UInt8
    ) -> String {
        "=" + String(format: "%02X", byte)
    }
}
