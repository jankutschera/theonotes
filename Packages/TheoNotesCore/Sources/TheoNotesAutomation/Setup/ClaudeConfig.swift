// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// The text a user pastes into Claude to start the Theo Notes MCP server. The app only builds the
/// text; it never writes a Claude configuration file.
public enum ClaudeConfig {
    /// `{"mcpServers":{"theonotes":{"command":"<abs>","args":["mcp-server",…]}}}`, pretty-printed,
    /// for Claude Desktop's `claude_desktop_config.json`.
    public static func desktopSnippet(binary: String, onlyTags: [String], excludeTags: [String]) -> String {
        let args = serverArguments(onlyTags: onlyTags, excludeTags: excludeTags)
            .map { JSONValue.string($0).serialized(sortedKeys: false) }
            .joined(separator: ", ")
        return """
        {
          "mcpServers": {
            "theonotes": {
              "command": \(JSONValue.string(binary).serialized(sortedKeys: false)),
              "args": [\(args)]
            }
          }
        }
        """
    }

    /// `claude mcp add theonotes -- '<abs>' mcp-server [--only-tags 'a,b'] [--exclude-tags 'x']`
    /// for Claude Code.
    public static func claudeCodeCommand(binary: String, onlyTags: [String], excludeTags: [String]) -> String {
        let args = serverArguments(onlyTags: onlyTags, excludeTags: excludeTags)
        let rest = args.enumerated().map { index, arg in
            // The subcommand and the flag names stay bare; flag values are quoted.
            index == 0 || arg.hasPrefix("--") ? arg : ShellQuote.quote(arg)
        }
        return (["claude mcp add theonotes --", ShellQuote.quote(binary)] + rest).joined(separator: " ")
    }

    /// `mcp-server` plus the scope flags. Tags lose surrounding blanks and a leading `#`; blank
    /// ones are dropped; a flag with no tag left is left out (`theonotes mcp-server --help`).
    static func serverArguments(onlyTags: [String], excludeTags: [String]) -> [String] {
        var args = ["mcp-server"]
        let only = cleaned(onlyTags)
        let exclude = cleaned(excludeTags)
        if !only.isEmpty { args += ["--only-tags", only.joined(separator: ",")] }
        if !exclude.isEmpty { args += ["--exclude-tags", exclude.joined(separator: ",")] }
        return args
    }

    static func cleaned(_ tags: [String]) -> [String] {
        tags.compactMap { tag in
            var name = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasPrefix("#") { name.removeFirst() }
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
    }
}
