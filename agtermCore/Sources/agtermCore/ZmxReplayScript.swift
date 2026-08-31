public enum ZmxReplayScript {
    public static func render(argv: [String], integrationDirectory: String,
                              inheritedZdotdir: String?, shell: String) -> String {
        var statements = [
            CommandRestore.shellQuotedLine(argv),
            "'builtin' 'export' ZDOTDIR=\(quoted(integrationDirectory))",
        ]
        if let inheritedZdotdir {
            statements.append("'builtin' 'export' GHOSTTY_ZSH_ZDOTDIR=\(quoted(inheritedZdotdir))")
        } else {
            statements.append("'builtin' 'unset' GHOSTTY_ZSH_ZDOTDIR")
        }
        statements.append("'builtin' 'exec' -- \(quoted(shell)) -il")
        return statements.joined(separator: " ; ")
    }

    private static func quoted(_ value: String) -> String {
        CommandRestore.shellQuotedLine([value])
    }
}
