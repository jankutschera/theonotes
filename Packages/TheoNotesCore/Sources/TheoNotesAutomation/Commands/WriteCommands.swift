// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// `create`, `append`, `edit`, `overwrite`, `tags add|remove|rename|delete`, `pin add|remove`,
/// `trash`, `archive` and `restore`. Check order (rulings M5-R45, M5-R51, M5-R59): arguments, the
/// library, the note, the address's syntax, the content lock, the address against the text,
/// `--base`, then the change. State-changing commands print nothing on success; only `create`
/// prints a record.
enum WriteCommands {
    static let handlers: [[String]: CommandHandler] = [
        ["create"]: create,
        ["append"]: append,
        ["edit"]: edit,
        ["overwrite"]: overwrite,
        ["tags", "add"]: tagsAdd,
        ["tags", "remove"]: tagsRemove,
        ["tags", "rename"]: tagsRename,
        ["tags", "delete"]: tagsDelete,
        ["pin", "add"]: pinAdd,
        ["pin", "remove"]: pinRemove,
        ["trash"]: trash,
        ["archive"]: archive,
        ["restore"]: restore,
    ]

    private static func service(_ env: CommandEnvironment) throws(AutomationError) -> AutomationService {
        AutomationService(library: try env.library(), context: env.context)
    }

    // MARK: create

    private static func create(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let title = parsed.positionals.first
        let template = parsed.value("--template")
        let ifNotExists = parsed.flag("--if-not-exists")
        // A template never reads stdin: `create X --template T` in a script must not wait for it.
        let content = template == nil ? env.content(parsed) : (parsed.value("--content") ?? "")
        try AutomationService.validateCreate(
            title: title, content: content, ifNotExists: ifNotExists, template: template)
        let tags = try TagArgument.list(parsed.value("--tags"))
        let fields = try NoteFields.parse(parsed.fieldsArgument, spec: parsed.spec)
        let record = try service(env).create(
            title: title, content: content, tags: tags, ifNotExists: ifNotExists, template: template)
        ReadCommands.writeRecord(record, fields: fields, format: parsed.format, env: env)
    }

    // MARK: append, edit, overwrite

    private static func append(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let selector = try NoteSelector.parse(id: parsed.positionals.first, title: parsed.value("--title"))
        let position = try position(parsed.value("--position"))
        let content = try requiredContent(parsed, env)
        _ = try service(env).append(
            selector, content: content, position: position, address: parsed.value("--section"),
            preservingModifiedDate: parsed.flag("--no-update-modified"))
    }

    /// `--content`, else stdin; neither given and nothing on stdin is `usage` (ruling M5-R79). An
    /// explicit `--content ""` is a request for empty content.
    private static func requiredContent(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) -> String {
        if let given = parsed.value("--content") { return given }
        let piped = env.content(parsed)
        guard !piped.isEmpty else { throw AutomationError(code: .usage, message: "Content is required") }
        return piped
    }

    private static func position(_ raw: String?) throws(AutomationError) -> AppendPosition {
        guard let raw else { return .end }
        guard let position = AppendPosition(rawValue: raw) else {
            throw AutomationError(code: .usage, message: "Invalid position: \(raw) (use beginning or end)")
        }
        return position
    }

    private static func edit(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let selector = try NoteSelector.parse(id: parsed.positionals.first, title: parsed.value("--title"))
        let edits = try EditSpec.fromCLI(parsed)
        _ = try service(env).edit(
            selector, edits: edits, address: parsed.value("--section"), gate: .cli(force: parsed.flag("--force")),
            preservingModifiedDate: parsed.flag("--no-update-modified"))
    }

    private static func overwrite(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let selector = try NoteSelector.parse(id: parsed.positionals.first, title: parsed.value("--title"))
        let content = try requiredContent(parsed, env)
        _ = try service(env).overwrite(
            selector, content: content, base: parsed.value("--base"), address: parsed.value("--section"),
            gate: .cli(force: parsed.flag("--force")), preservingModifiedDate: parsed.flag("--no-update-modified"))
    }

    // MARK: tags

    /// The note and the words after it. With `--title` every positional is a word; otherwise the
    /// first is the note id.
    private static func noteAndWords(_ parsed: ParsedCommand) throws(AutomationError) -> (NoteSelector, [String]) {
        if let title = parsed.value("--title") { return (.title(title), parsed.positionals) }
        let selector = try NoteSelector.parse(id: parsed.positionals.first, title: nil)
        return (selector, Array(parsed.positionals.dropFirst()))
    }

    private static func tagsAdd(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let (selector, tags) = try noteAndWords(parsed)
        guard !tags.isEmpty else { throw AutomationError(code: .usage, message: "<tags> is required") }
        for tag in tags { _ = try TagArgument.name(tag) }
        _ = try service(env).addTags(selector, tags: tags)
    }

    private static func tagsRemove(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let (selector, tags) = try noteAndWords(parsed)
        guard !tags.isEmpty else { throw AutomationError(code: .usage, message: "<tags> is required") }
        for tag in tags { _ = try TagArgument.name(tag) }
        _ = try service(env).removeTags(selector, tags: tags)
    }

    /// A tag given as an argument or as an option, exactly one of them.
    private static func tagValue(
        _ name: String, argument: String?, option: String?
    ) throws(AutomationError) -> String {
        switch (argument, option) {
        case (let value?, nil), (nil, let value?): return value
        case (nil, nil): throw AutomationError(code: .usage, message: "<\(name)> is required")
        case (_?, _?):
            throw AutomationError(code: .usage, message: "Provide the tag as an argument or option, not both")
        }
    }

    private static func tagsRename(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let old = try tagValue("old", argument: parsed.positionals.first, option: parsed.value("--from"))
        let new = try tagValue(
            "new", argument: parsed.positionals.count > 1 ? parsed.positionals[1] : nil,
            option: parsed.value("--to"))
        _ = try AutomationService.validateRename(old: old, new: new)
        _ = try service(env).renameTag(old: old, new: new, force: parsed.flag("--force"))
    }

    private static func tagsDelete(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let tag = try tagValue("tag", argument: parsed.positionals.first, option: parsed.value("--name"))
        _ = try TagArgument.name(tag)
        _ = try service(env).deleteTag(tag)
    }

    // MARK: pins

    private static func pinAdd(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let (selector, targets) = try noteAndWords(parsed)
        guard !targets.isEmpty else { throw AutomationError(code: .usage, message: "<targets> is required") }
        _ = try service(env).addPins(selector, targets: targets)
    }

    private static func pinRemove(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let (selector, targets) = try noteAndWords(parsed)
        guard !targets.isEmpty else { throw AutomationError(code: .usage, message: "<targets> is required") }
        _ = try service(env).removePins(selector, targets: targets)
    }

    // MARK: location

    private static func trash(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let selector = try NoteSelector.parse(id: parsed.positionals.first, title: parsed.value("--title"))
        _ = try service(env).trash(selector)
    }

    private static func archive(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let selector = try NoteSelector.parse(id: parsed.positionals.first, title: parsed.value("--title"))
        _ = try service(env).archive(selector)
    }

    private static func restore(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let selector = try NoteSelector.parse(id: parsed.positionals.first, title: parsed.value("--title"))
        _ = try service(env).restore(selector)
    }
}
