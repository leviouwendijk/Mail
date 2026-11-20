import Foundation
import Mail
import Testing

enum EncodingTests {
    static func quotedPrintable() throws {
        try Expect.equal(
            MIMEEncoding.quotedPrintable("café = ok"),
            "caf=C3=A9 =3D ok",
            "Non-ASCII and equals sign"
        )
        try Expect.equal(
            MIMEEncoding.quotedPrintable("trailing \nnext"),
            "trailing=20\r\nnext",
            "Trailing space encoded, LF becomes CRLF"
        )

        let wrapped = MIMEEncoding.quotedPrintable(String(repeating: "é", count: 40))
        let lines = wrapped.components(separatedBy: "\r\n")
        try Expect.true(lines.count > 1, "Long line gets soft breaks")
        try Expect.true(lines.allSatisfy { $0.count <= 76 }, "Lines stay within 76 columns")
        try Expect.true(lines.dropLast().allSatisfy { $0.hasSuffix("=") }, "Soft breaks end in =")
        try Expect.false(lines.contains { $0.dropLast().hasSuffix("=C") }, "Escapes are not split")
    }

    static func encodedWord() throws {
        try Expect.equal(MIMEEncoding.encodedWord("Afspraak morgen"), "Afspraak morgen", "ASCII passes through")
        try Expect.equal(MIMEEncoding.encodedWord("Héllo"), "=?UTF-8?B?SMOpbGxv?=", "Non-ASCII is B-encoded")

        let long = MIMEEncoding.encodedWord(String(repeating: "ë", count: 40))
        let words = long.components(separatedBy: "\r\n ")
        try Expect.true(words.count > 1, "Long text splits into several words")
        try Expect.true(words.allSatisfy { $0.count <= 75 }, "Each word fits 75 characters")
        let decoded = words
            .map { Data(base64Encoded: String($0.dropFirst(10).dropLast(2)))! }
            .reduce(Data(), +)
        try Expect.equal(String(decoding: decoded, as: UTF8.self), String(repeating: "ë", count: 40), "Words reassemble")
    }

    static func displayName() throws {
        try Expect.equal(MIMEEncoding.displayName("Jan de Vries"), "Jan de Vries", "Atom-safe stays bare")
        try Expect.equal(MIMEEncoding.displayName("Vries, Jan"), "\"Vries, Jan\"", "Specials are quoted")
        try Expect.equal(MIMEEncoding.displayName("Say \"hi\""), "\"Say \\\"hi\\\"\"", "Quotes are escaped")
        try Expect.equal(MIMEEncoding.displayName("Zoë"), "=?UTF-8?B?Wm/Dqw==?=", "Non-ASCII is encoded")
    }
}
