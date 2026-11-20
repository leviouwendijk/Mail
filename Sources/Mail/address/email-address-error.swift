import Errors
import Foundation

extension EmailAddress.Error:
    SemanticError,
    ErrorNamespaced,
    ErrorDispositionProviding
{
    public static let errorNamespace = "mail.address"

    public var errorCode: String {
        switch self {
        case .empty: return "empty"
        case .missingAt: return "missing_at"
        case .emptyLocalPart: return "empty_local_part"
        case .emptyDomain: return "empty_domain"
        case .emptyDomainLabel: return "empty_domain_label"
        case .localPartTooLong: return "local_part_too_long"
        case .domainTooLong: return "domain_too_long"
        case .invalidCharacter: return "invalid_character"
        }
    }

    public var errorPresentation: ErrorPresentation {
        .init(
            message: "Not a valid email address.",
            reason: reason
        )
    }

    public var errorDisposition: ErrorDisposition? {
        .invalid_input
    }

    private var reason: String {
        switch self {
        case .empty:
            return "It is empty."
        case .missingAt:
            return "It has no @."
        case .emptyLocalPart:
            return "Nothing comes before the @."
        case .emptyDomain:
            return "Nothing comes after the @."
        case .emptyDomainLabel:
            return "The domain has an empty part (two dots, or a dot at an end)."
        case .localPartTooLong:
            return "The part before the @ is longer than 64 bytes."
        case .domainTooLong:
            return "The domain is longer than 255 bytes."
        case .invalidCharacter(let character):
            return "It contains '\(character)', which addresses cannot hold (non-ASCII is not supported yet)."
        }
    }
}
