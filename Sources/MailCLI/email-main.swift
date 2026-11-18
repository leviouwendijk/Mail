import Arguments
import Foundation

@main
enum EmailCommand: ArgumentCommand {
    static let name = "email"
    static let defaultChild = HelpCommand.self

    static let children: [ArgumentCommandType] = [
        HelpCommand.self,
        PathCommand.self,
        ExampleCommand.self,
        CheckCommand.self,
        ModuleCommand.self,
        AccountsCommand.self,
        ProbeCommand.self,
        MailboxesCommand.self,
        SearchCommand.self,
        ReadCommand.self,
        DraftCommand.self,
        SendCommand.self,
    ]

    static func components() throws -> [CommandComponentLowerable] {
        [
            about("Read, search, draft and send mail over the accounts in ~/.config/mail/*.frame."),
        ]
    }

    static func main() async {
        await ArgumentProgram.main(
            command: Self.self,
            errorHandler: { error in
                EmailCLI.writeError(error)
                return 1
            }
        )
    }
}

enum HelpCommand: RunnableArgumentCommand {
    static let name = "help"

    static func run(
        _ invocation: ParsedInvocation
    ) async throws {
        print(
            ArgumentHelpRenderer().render(
                command: try EmailCommand.spec()
            )
        )
    }
}
