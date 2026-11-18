import Mail
import Testing

enum AddressTests {
    static func valid() throws {
        let address = try EmailAddress("  jan.de-vries+tag@mail.example.org ")
        try Expect.equal(address.raw, "jan.de-vries+tag@mail.example.org", "Trimmed")
        try Expect.equal(String(address.localPart), "jan.de-vries+tag", "Local part")
        try Expect.equal(String(address.domain), "mail.example.org", "Domain")
    }

    static func invalid() throws {
        try Expect.throwsError("Empty") { _ = try EmailAddress("  ") }
        try Expect.throwsError("No at") { _ = try EmailAddress("jan.example.org") }
        try Expect.throwsError("Empty local") { _ = try EmailAddress("@example.org") }
        try Expect.throwsError("Empty domain") { _ = try EmailAddress("jan@") }
        try Expect.throwsError("Empty label") { _ = try EmailAddress("jan@example..org") }
        try Expect.throwsError("Space") { _ = try EmailAddress("jan de@example.org") }
        try Expect.throwsError("Angle bracket") { _ = try EmailAddress("<jan@example.org>") }
        try Expect.throwsError("Non-ASCII") { _ = try EmailAddress("jé@example.org") }
        try Expect.throwsError("Long local") { _ = try EmailAddress(String(repeating: "a", count: 65) + "@example.org") }
    }
}
