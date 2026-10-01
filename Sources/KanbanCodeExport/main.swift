import Foundation
import KanbanCodeCore

// Prints a session as Markdown for `kanban export`, see ConversationExportCommand.

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("-h") || args.contains("--help") {
    print(ConversationExportCommand.usage)
    exit(0)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("kanban-code-export: \(message)\n".utf8))
    exit(1)
}

do {
    let command = try ConversationExportCommand.parse(args)
    let stdout = FileHandle.standardOutput
    try await command.run { stdout.write(Data($0.utf8)) }
} catch let error as ConversationExportCommand.Failure {
    fail(error.description)
} catch {
    fail("\(error)")
}
