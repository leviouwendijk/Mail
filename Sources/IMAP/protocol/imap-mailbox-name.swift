import Foundation

/// IMAP's modified UTF-7 for mailbox names (RFC 3501 §5.1.3).
public enum IMAPMailboxName {
    public static func encode(
        _ name: String
    ) -> String {
        var output = ""
        var pending: [UInt16] = []

        func flush() {
            guard !pending.isEmpty else {
                return
            }
            let bytes = pending.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
            let base64 = Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "/", with: ",")
                .replacingOccurrences(of: "=", with: "")
            output += "&\(base64)-"
            pending = []
        }

        for scalar in name.unicodeScalars {
            if (0x20...0x7E).contains(scalar.value) {
                flush()
                output += scalar == "&" ? "&-" : String(scalar)
            } else {
                pending += Array(String(scalar).utf16)
            }
        }
        flush()
        return output
    }

    public static func decode(
        _ encoded: String
    ) -> String {
        var output = ""
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let character = encoded[index]
            guard character == "&",
                  let end = encoded[index...].firstIndex(of: "-")
            else {
                output.append(character)
                index = encoded.index(after: index)
                continue
            }
            let run = encoded[encoded.index(after: index)..<end]
            if run.isEmpty {
                output += "&"
            } else {
                var base64 = run.replacingOccurrences(of: ",", with: "/")
                base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
                let bytes = Array(Data(base64Encoded: base64) ?? Data())
                let units = stride(from: 0, to: bytes.count - 1, by: 2).map {
                    UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1])
                }
                output += String(decoding: units, as: UTF16.self)
            }
            index = encoded.index(after: end)
        }
        return output
    }
}
