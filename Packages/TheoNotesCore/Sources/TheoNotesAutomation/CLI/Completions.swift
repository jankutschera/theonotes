// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

/// Shell completion scripts (`theonotes --generate-completion-script zsh|bash|fish`), built from
/// `CommandTable` so a command or option added to the table is completed without further work.
enum Completions {
    static func script(shell: String) -> String {
        switch shell {
        case "zsh": zsh()
        case "bash": bash()
        case "fish": fish()
        default: ""
        }
    }

    // MARK: Table views

    /// Known values for options that take one of a few words.
    private static let valueWords: [String: [String]] = [
        "--format": ["tsv", "csv", "json"],
        "--location": ["notes", "trash", "archive", "all"],
        "--position": ["beginning", "end"],
    ]

    /// Every spelling of every option of `spec`, including `-h`/`--help`.
    private static func spellings(_ spec: CommandSpec) -> [String] {
        var result: [String] = []
        for option in spec.options {
            if let short = option.short { result.append("-\(short)") }
            result.append(option.long)
            result += option.aliases
        }
        return result + ["-h", "--help"]
    }

    private static var topLevelCommands: [String] { CommandTable.topLevelNames }

    // MARK: zsh

    private static func zsh() -> String {
        func arguments(_ spec: CommandSpec) -> String {
            var lines: [String] = []
            for option in spec.options {
                let names = (option.short.map { ["-\($0)"] } ?? []) + [option.long] + option.aliases
                let suffix: String
                if let value = option.valueName {
                    let action: String
                    if let words = valueWords[option.long] {
                        action = "(\(words.joined(separator: " ")))"
                    } else if option.long == "--data-dir" {
                        action = "_files -/"
                    } else {
                        action = " "
                    }
                    suffix = "=:\(value):\(action)"
                } else {
                    suffix = ""
                }
                for name in names { lines.append("'\(name)\(suffix)'") }
            }
            return lines.joined(separator: " ")
        }

        var out = "#compdef theonotes\n\n_theonotes() {\n"
        out += "  local curcontext=\"$curcontext\" state line\n  typeset -A opt_args\n"
        out += "  _arguments -C \\\n"
        out += "    '(- *)'{-h,--help}'[Show help information.]' \\\n"
        out += "    '(- *)'{-v,--version}'[Show the version.]' \\\n"
        out += "    '--data-dir=:path:_files -/' \\\n"
        out += "    '--generate-completion-script=:shell:(zsh bash fish)' \\\n"
        out += "    '1: :->command' \\\n    '*:: :->args' && return\n\n"
        out += "  case $state in\n"
        out += "    command)\n      compadd -- help \(topLevelCommands.joined(separator: " "))\n      ;;\n"
        out += "    args)\n      case $words[1] in\n"
        out += "        help)\n          compadd -- all \(topLevelCommands.joined(separator: " "))\n          ;;\n"
        for command in topLevelCommands {
            if let children = CommandTable.groups[command] {
                out += "        \(command))\n"
                out += "          if (( CURRENT == 2 )); then\n"
                out += "            compadd -- \(children.joined(separator: " "))\n            return\n          fi\n"
                out += "          case $words[2] in\n"
                for child in children {
                    guard let spec = CommandTable.spec([command, child]) else { continue }
                    out += "            \(child)) _arguments \(arguments(spec)) ;;\n"
                }
                out += "          esac\n          ;;\n"
            } else if let spec = CommandTable.spec([command]) {
                out += "        \(command)) _arguments \(arguments(spec)) ;;\n"
            }
        }
        out += "      esac\n      ;;\n  esac\n}\n\n_theonotes \"$@\"\n"
        return out
    }

    // MARK: bash

    private static func bash() -> String {
        var out = "# bash completion for theonotes\n\n_theonotes() {\n"
        out += "  local cur prev cmd sub i word\n"
        out += "  COMPREPLY=()\n  cur=\"${COMP_WORDS[COMP_CWORD]}\"\n  prev=\"${COMP_WORDS[COMP_CWORD-1]}\"\n\n"
        out += "  case \"$prev\" in\n"
        out += "    --data-dir) COMPREPLY=($(compgen -d -- \"$cur\")); return ;;\n"
        out += "    --generate-completion-script) COMPREPLY=($(compgen -W \"zsh bash fish\" -- \"$cur\")); return ;;\n"
        for (option, words) in valueWords.sorted(by: { $0.key < $1.key }) {
            out += "    \(option)) COMPREPLY=($(compgen -W \"\(words.joined(separator: " "))\" -- \"$cur\")); return ;;\n"
        }
        out += "  esac\n\n"
        out += "  cmd=\"\"; sub=\"\"\n"
        out += "  for (( i = 1; i < COMP_CWORD; i++ )); do\n"
        out += "    word=\"${COMP_WORDS[i]}\"\n"
        out += "    case \"$word\" in\n"
        out += "      --data-dir) (( i++ )); continue ;;\n      -*) continue ;;\n    esac\n"
        out += "    if [[ -z \"$cmd\" ]]; then cmd=\"$word\"; elif [[ -z \"$sub\" ]]; then sub=\"$word\"; fi\n"
        out += "  done\n\n"
        out += "  if [[ -z \"$cmd\" ]]; then\n"
        out += "    COMPREPLY=($(compgen -W \"help --help --version --data-dir --generate-completion-script "
        out += "\(topLevelCommands.joined(separator: " "))\" -- \"$cur\"))\n    return\n  fi\n\n"
        out += "  case \"$cmd\" in\n"
        out += "    help) COMPREPLY=($(compgen -W \"all \(topLevelCommands.joined(separator: " "))\" -- \"$cur\")) ;;\n"
        for command in topLevelCommands {
            if let children = CommandTable.groups[command] {
                out += "    \(command))\n"
                out += "      case \"$sub\" in\n"
                for child in children {
                    guard let spec = CommandTable.spec([command, child]) else { continue }
                    out += "        \(child)) COMPREPLY=($(compgen -W \"\(spellings(spec).joined(separator: " "))\" -- \"$cur\")) ;;\n"
                }
                out += "        *) COMPREPLY=($(compgen -W \"\(children.joined(separator: " ")) --help\" -- \"$cur\")) ;;\n"
                out += "      esac\n      ;;\n"
            } else if let spec = CommandTable.spec([command]) {
                out += "    \(command)) COMPREPLY=($(compgen -W \"\(spellings(spec).joined(separator: " "))\" -- \"$cur\")) ;;\n"
            }
        }
        out += "  esac\n}\n\ncomplete -F _theonotes theonotes\n"
        return out
    }

    // MARK: fish

    private static func fish() -> String {
        var out = "# fish completion for theonotes\n\ncomplete -c theonotes -f\n"
        out += "complete -c theonotes -s h -l help -d 'Show help information'\n"
        out += "complete -c theonotes -s v -l version -d 'Show the version'\n"
        out += "complete -c theonotes -l data-dir -r -F -d 'Use the library in this folder'\n"
        out += "complete -c theonotes -l generate-completion-script -x -a 'zsh bash fish'\n\n"
        let groups = CommandTable.groups.keys.sorted().joined(separator: " ")
        let none = "not __fish_seen_subcommand_from help \(topLevelCommands.joined(separator: " "))"
        out += "complete -c theonotes -n '\(none)' -a 'help \(topLevelCommands.joined(separator: " "))'\n"
        out += "complete -c theonotes -n '__fish_seen_subcommand_from help' -a 'all \(topLevelCommands.joined(separator: " "))'\n"
        for (group, children) in CommandTable.groups.sorted(by: { $0.key < $1.key }) {
            let condition = "__fish_seen_subcommand_from \(group); and not __fish_seen_subcommand_from \(children.joined(separator: " "))"
            out += "complete -c theonotes -n '\(condition)' -a '\(children.joined(separator: " "))'\n"
        }
        out += "\n"
        for spec in CommandTable.all {
            let condition: String
            if spec.path.count == 2 {
                condition = "__fish_seen_subcommand_from \(spec.path[0]); and __fish_seen_subcommand_from \(spec.path[1])"
            } else {
                condition = "__fish_seen_subcommand_from \(spec.path[0]); and not __fish_seen_subcommand_from \(groups)"
            }
            for option in spec.options {
                var line = "complete -c theonotes -n '\(condition)'"
                if let short = option.short { line += " -s \(short)" }
                line += " -l \(option.long.dropFirst(2))"
                if option.valueName != nil {
                    if let words = valueWords[option.long] {
                        line += " -x -a '\(words.joined(separator: " "))'"
                    } else if option.long == "--data-dir" {
                        line += " -r -F"
                    } else {
                        line += " -r"
                    }
                }
                out += line + "\n"
                for alias in option.aliases {
                    out += "complete -c theonotes -n '\(condition)' -l \(alias.dropFirst(2)) -r\n"
                }
            }
        }
        return out
    }
}
