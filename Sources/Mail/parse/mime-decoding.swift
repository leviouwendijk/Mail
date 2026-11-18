import Foundation

public extension MIMEEncoding {
    /// Text in `charset`, falling back to UTF-8 and then Latin-1, which accepts any bytes.
    static func decodeText(
        _ data: Data,
        charset: String?
    ) -> String {
        if let charset,
           let encoding = stringEncoding(charset: charset),
           let text = String(data: data, encoding: encoding)
        {
            return text
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    static func stringEncoding(
        charset: String
    ) -> String.Encoding? {
        let encoding = CFStringConvertIANACharSetNameToEncoding(charset.trimmingCharacters(in: .whitespaces) as CFString)
        guard encoding != kCFStringEncodingInvalidId else {
            return nil
        }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
    }

    static func decodeBase64(
        _ data: Data
    ) -> Data {
        Data(base64Encoded: data, options: .ignoreUnknownCharacters) ?? Data()
    }

    static func decodeQuotedPrintable(
        _ data: Data
    ) -> Data {
        let bytes = Array(data)
        var output = Data(capacity: bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == UInt8(ascii: "=") else {
                output.append(byte)
                index += 1
                continue
            }
            if index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "\n") {
                index += 2
            } else if index + 2 < bytes.count, bytes[index + 1] == UInt8(ascii: "\r"), bytes[index + 2] == UInt8(ascii: "\n") {
                index += 3
            } else if index + 2 < bytes.count, let value = hexValue(bytes[index + 1], bytes[index + 2]) {
                output.append(value)
                index += 3
            } else {
                output.append(byte)
                index += 1
            }
        }
        return output
    }

    /// Decodes RFC 2047 encoded words, dropping whitespace between adjacent ones.
    static func decodeEncodedWords(
        _ text: String
    ) -> String {
        guard text.contains("=?") else {
            return text
        }
        return MailGrammar.EncodedText().parseComplete(text) ?? text
    }

    private static func hexValue(
        _ high: UInt8,
        _ low: UInt8
    ) -> UInt8? {
        UInt8(String(decoding: [high, low], as: UTF8.self), radix: 16)
    }
}
