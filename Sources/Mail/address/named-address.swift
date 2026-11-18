/// An address with an optional display name, as in `Jan de Vries <jan@example.com>`.
public struct NamedAddress: Hashable, Sendable, Codable {
    public let name: String?
    public let address: EmailAddress

    public init(
        _ address: EmailAddress,
        name: String? = nil
    ) {
        self.address = address
        self.name = name.flatMap { $0.isEmpty ? nil : $0 }
    }

    public init(
        _ address: String,
        name: String? = nil
    ) throws(EmailAddress.Error) {
        self.init(
            try EmailAddress(address),
            name: name
        )
    }
}
