import ArgumentParser

public struct MimaApp: ParsableCommand {
    public init() {}
    public static let configuration = CommandConfiguration(
        commandName: "mima",
        abstract: """
           M I M A
           Split Identity. Keep it real.
        """,
        version: "0.1.0",
        subcommands: [Secret.self, Group.self, Run.self, Env.self, Import.self, MCP.self, Doctor.self],
        defaultSubcommand: nil
    )
}
