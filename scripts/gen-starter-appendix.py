#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

"""Rebuilds the appendix of docs/release/2026-11-15-getting-started-texts-v2.md (STARTER-R3, R16).

Every row names something the Getting Started texts mention and a line of source that shows it exists. A row's
needle is a piece of that line; the script finds the first line holding it and prints `file:line`. A needle that
is no longer found fails the run, so a renamed menu item or label cannot slip by. When a text names something new,
add a row here.

    python3 -I scripts/gen-starter-appendix.py          # print the table, fail on a missing line
    python3 -I scripts/gen-starter-appendix.py --write  # also replace the table in the owner's file
"""

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOC = ROOT / "docs/release/2026-11-15-getting-started-texts-v2.md"
HEADER = "| Platform | What the text names | Source (file:line) |\n|---|---|---|\n"

ROWS = [
    ('iOS', 'New Note button (⌘N)', 'Apps/TheoNotesIOS/Sources/MobileLibraryView.swift', 'Button("New Note", systemImage: "square.and.pencil") {'),
    ('iOS', 'Quick Open: bottom-bar magnifier of the note list', 'Apps/TheoNotesIOS/Sources/MobileLibraryView.swift', 'Button("Quick Open", systemImage: "doc.text.magnifyingglass") { showingQuickOpen = true }.accessibilityIdentifier("list-quick-open")'),
    ('iOS', 'Quick Open takes a title, #tag, @section', 'Apps/TheoNotesIOS/Sources/MobilePanels.swift', 'TextField("Title, #tag, @section, +template", text: $query)'),
    ('iOS', 'Note Actions button', 'Apps/TheoNotesIOS/Sources/MobileLibraryView.swift', '} label: { Image(systemName: "ellipsis.circle").accessibilityLabel("Note Actions") }'),
    ('iOS', 'Note Actions > Note Info', 'Apps/TheoNotesIOS/Sources/MobileLibraryView.swift', 'Button("Note Info", systemImage: "info.circle") { showingInfo = true }.keyboardShortcut("i", modifiers: [.command, .shift])'),
    ('iOS', 'Note Info: Type menu with the three kinds and Remove Type', 'Apps/TheoNotesIOS/Sources/MobilePanels.swift', 'Section("Type") {'),
    ('iOS', 'Note Info: Backlinks', 'Apps/TheoNotesIOS/Sources/MobilePanels.swift', 'Section("Backlinks") {'),
    ('iOS', 'Note Info: Unlinked Mentions with a Link button', 'Apps/TheoNotesIOS/Sources/MobilePanels.swift', 'Section("Unlinked Mentions") {'),
    ('iOS', 'Note Info: Link button of a mention', 'Apps/TheoNotesIOS/Sources/MobilePanels.swift', 'Button("Link") {'),
    ('iOS', 'Note Actions > Find in Note', 'Apps/TheoNotesIOS/Sources/MobileLibraryView.swift', 'Button("Find in Note", systemImage: "magnifyingglass") { editor.command(.find) }'),
    ('iOS', 'Note Actions > More', 'Apps/TheoNotesIOS/Sources/MobileLibraryView.swift', 'Menu("More", systemImage: "ellipsis") {'),
    ('iOS', 'Note Actions > More > Find and Replace', 'Apps/TheoNotesIOS/Sources/MobileLibraryView.swift', 'Button("Find and Replace", systemImage: "text.magnifyingglass") { editor.command(.findAndReplace) }.disabled(!editor.editable)'),
    ('iOS', 'Search notes field above the note list', 'Apps/TheoNotesIOS/Sources/MobileLibraryView.swift', '.searchable(text: $sceneNavigation.query, prompt: "Search notes")'),
    ('iOS', 'Note Actions > Lock Note / Remove Note Lock', 'Apps/TheoNotesIOS/Sources/MobileLibraryView.swift', 'Button(note.isLocked ? "Remove Note Lock" : "Lock Note", systemImage: note.isLocked ? "lock.open" : "lock") {'),
    ('iOS', 'Note Actions > Close Locked Notes', 'Apps/TheoNotesIOS/Sources/MobileLibraryView.swift', 'Button("Close Locked Notes", systemImage: "lock.fill") { closePrivateAccess() }'),
    ('iOS', 'Note Actions > Export', 'Apps/TheoNotesIOS/Sources/MobileLibraryView.swift', 'Menu("Export", systemImage: "square.and.arrow.up") {'),
    ('iOS', 'Export format names (Markdown, TextBundle, Plain Text, HTML, PDF, Rich Text (RTF))', 'Apps/TheoNotesIOS/Sources/MobileRenderedExport.swift', 'case .markdown: "Markdown"'),
    ('iOS', 'Note Actions > Export > Print', 'Apps/TheoNotesIOS/Sources/MobileLibraryView.swift', 'Button("Print") { export(format: .pdf, printDocument: true) }'),
    ('iOS', 'Share Markdown', 'Apps/TheoNotesIOS/Sources/MobileLibraryView.swift', 'Button("Share Markdown", systemImage: "square.and.arrow.up") {'),
    ('iOS', 'Formatting menu in the bar at the bottom of the note', 'Apps/TheoNotesIOS/Sources/MobileLibraryView.swift', '} label: { barIcon("textformat").accessibilityLabel("Formatting") }'),
    ('iOS', 'Formatting > Indent', 'Apps/TheoNotesIOS/Sources/MobileLibraryView.swift', 'formatMenuButton("Indent", "increase.indent", .indent)'),
    ('iOS', 'Attach menu (Photo Library, Insert File, Scan Document, New Sketch)', 'Apps/TheoNotesIOS/Sources/MobileLibraryView.swift', 'Button("Photo Library", systemImage: "photo.on.rectangle") { beginAttachment(.photos) }'),
    ('iOS', 'Attach label', 'Apps/TheoNotesIOS/Sources/MobileLibraryView.swift', '} label: { barIcon("plus.circle").accessibilityLabel("Attach") }'),
    ('iOS', 'Camera button (Take Photo)', 'Apps/TheoNotesIOS/Sources/MobileLibraryView.swift', '.accessibilityLabel("Take Photo").accessibilityIdentifier("toolbar-camera").disabled(attachmentDisabled(.camera))'),
    ('iOS', 'Sidebar rows Inbox, Ideas, Logs, References', 'Apps/TheoNotesIOS/Sources/MobileLibraryView.swift', 'scopeRow("Inbox", "tray", .inbox, sceneObservation.snapshot.counts.inbox)'),
    ('iOS', 'Sidebar rows To Do, Today, Untagged, Locked', 'Apps/TheoNotesIOS/Sources/MobileLibraryView.swift', 'scopeRow("To Do", "checkmark.circle", .todo, sceneObservation.snapshot.counts.todo)'),
    ('iOS', 'Tag context menu: Edit Tag', 'Apps/TheoNotesIOS/Sources/MobileLibraryView.swift', 'Button("Edit Tag", systemImage: "pencil") { editingTag = tag }'),
    ('iOS', 'Edit Tag sheet: Tag path (rename), Icon, Pin Tag', 'Apps/TheoNotesIOS/Sources/MobilePanels.swift', 'TextField("Tag path", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()'),
    ('iOS', 'Edit Tag sheet: Pin Tag', 'Apps/TheoNotesIOS/Sources/MobilePanels.swift', 'Button(tag.isPinned ? "Unpin Tag" : "Pin Tag", systemImage: "pin") {'),
    ('iOS', 'Library Options menu, Settings and Import Notes', 'Apps/TheoNotesIOS/Sources/MobileLibraryView.swift', '} label: { Label("Library Options", systemImage: "books.vertical") }'),
    ('iOS', 'Import Notes button', 'Apps/TheoNotesIOS/Sources/MobileLibraryView.swift', 'Button("Import Notes", systemImage: "square.and.arrow.down") { importingNotes = true; importingFile = true }.disabled(importBusy)'),
    ('iOS', 'Sort Inbox button at the top of the Inbox list', 'Apps/TheoNotesIOS/Sources/MobileLibraryView.swift', 'Button("Sort Inbox", systemImage: "tray.full") {'),
    ('iOS', 'Sort Inbox: Archive, Move to Trash, Skip with keys a, t, s', 'Apps/TheoNotesIOS/Sources/MobileSortInboxSheet.swift', 'actionButton("Archive", symbol: "archivebox", key: "a", action: .archive)'),
    ('iOS', 'Sort Inbox: Open Note', 'Apps/TheoNotesIOS/Sources/MobileSortInboxSheet.swift', 'Button("Open Note", systemImage: "arrow.up.right.square") {'),
    ('iOS', 'Sort Inbox: Archive the Rest…', 'Apps/TheoNotesIOS/Sources/MobileSortInboxSheet.swift', 'Button("Archive the Rest…", systemImage: "archivebox") {'),
    ('iOS', 'Settings > General > Hide Markdown', 'Apps/TheoNotesIOS/Sources/MobileSettings.swift', 'Toggle("Hide Markdown", isOn: $hideMarkdown)'),
    ('iOS', 'Settings > General > Checked To-Dos at Bottom', 'Apps/TheoNotesIOS/Sources/MobileSettings.swift', 'Toggle("Checked To-Dos at Bottom"'),
    ('iOS', 'Settings > General > Keep Tags in Exports', 'Apps/TheoNotesIOS/Sources/MobileSettings.swift', 'Toggle("Keep Tags in Exports", isOn: $library.preferences.keepTagsOnExport)'),
    ('iOS', 'Settings > Privacy > Require Authentication to Open Theo Notes', 'Apps/TheoNotesIOS/Sources/MobileSettings.swift', 'Toggle("Require Authentication to Open Theo Notes", isOn: Binding(get: { library.appLockEnabled }, set: { enabled in'),
    ('iOS', 'Settings > Privacy > Unlock Notes with Face ID / Touch ID', 'Apps/TheoNotesIOS/Sources/MobileSettings.swift', 'Toggle("Unlock Notes with " + label, isOn: Binding(get: { library.biometryEnabled }, set: { enabled in'),
    ('iOS', 'Face ID or Touch ID label', 'Apps/TheoNotesIOS/Sources/MobileBiometricKeychain.swift', 'return context.biometryType == .faceID ? "Face ID" : "Touch ID"'),
    ('iOS', 'Locked notes close when Theo Notes becomes inactive', 'Apps/TheoNotesIOS/Sources/MobileSettings.swift', 'Text("Locked notes close when Theo Notes becomes inactive. Titles remain visible in the library.")'),
    ('iOS', 'Settings > Privacy > Set Note Password', 'Apps/TheoNotesIOS/Sources/MobileSettings.swift', 'Button(library.hasNotePassword ? "Change Note Password" : "Set Note Password") {'),
    ('iOS', 'Settings > Advanced > Backup and Restore', 'Apps/TheoNotesIOS/Sources/MobileSettings.swift', 'Label("Backup and Restore", systemImage: "externaldrive")'),
    ('iOS', 'Backup and Restore: Create Backup, Choose Backup to Restore', 'Apps/TheoNotesIOS/Sources/MobileBackups.swift', 'Button("Create Backup", systemImage: "square.and.arrow.up") {'),
    ('iOS', 'Backup and Restore: Merge / Replace All', 'Apps/TheoNotesIOS/Sources/MobileBackups.swift', 'Text("Replace All").tag(BackupRestoreMode.replaceAll)'),
    ('iOS', 'Backup and Restore: safety backup before replace', 'Apps/TheoNotesIOS/Sources/MobileBackups.swift', 'Button("Create Safety Backup and Replace", role: .destructive) { restore() }'),
    ('iOS', 'Settings > Advanced > Automation: API Token and URL Scheme', 'Apps/TheoNotesIOS/Sources/MobileSettings.swift', 'NavigationLink("API Token and URL Scheme") { MobileAutomationSettings(library: library) }'),
    ('iOS', 'Apple Shortcuts actions', 'Apps/TheoNotesIOS/Sources/MobileAppIntents.swift', 'struct CreateShortcutNote: AppIntent {'),
    ('iOS', 'Settings > Restore Getting Started Notes', 'Apps/TheoNotesIOS/Sources/MobileSettings.swift', 'Button { restoreGettingStarted() } label: { Label(MobileGettingStarted.title, systemImage: "lifepreserver") }'),
    ('iOS', 'Captured notes show a tray mark', 'Apps/TheoNotesIOS/Sources/MobileNoteRow.swift', 'if note.captureSource != nil { Image(systemName: "tray.and.arrow.down").font(.caption).accessibilityLabel("Captured") }'),
    ('iOS', 'Note kind shown in the note row', 'Apps/TheoNotesIOS/Sources/MobileNoteRow.swift', '.font(.caption).accessibilityLabel("Type: \\(type.displayName)")'),
    ('iOS', 'Voice Note sheet with Stop Recording', 'Apps/TheoNotesIOS/Sources/MobileVoiceCaptureView.swift', 'Button("Stop Recording") { Task { await model.stop() } }.buttonStyle(.borderedProminent)'),
    ('iOS widgets', 'Thought control', 'Apps/TheoNotesIOSWidgets/CaptureControls.swift', '}.displayName("Thought").description("Open a new thought in Theo Notes.")'),
    ('iOS widgets', 'Voice control', 'Apps/TheoNotesIOSWidgets/CaptureControls.swift', '}.displayName("Voice").description("Open voice capture in Theo Notes.")'),
    ('iOS widgets', 'New Note widget', 'Apps/TheoNotesIOSWidgets/CaptureWidgets.swift', '}.configurationDisplayName("New Note").description("Start writing a new note.")'),
    ('iOS widgets', 'Next Up widget (next reminder, to-do or thought)', 'Apps/TheoNotesIOSWidgets/NextUpWidget.swift', '}.configurationDisplayName("Next Up").description("Your next reminder, to-do or thought.")'),
    ('iOS share', 'Share extension Save button', 'Apps/TheoNotesIOSShare/ShareViewController.swift', 'save.setTitle("Save", for: .normal)'),
    ('Mac', 'Capture Thought in the menu bar item', 'Apps/TheoNotesMac/Sources/Capture/CaptureMenuBar.swift', 'case .capture: "Capture Thought"'),
    ('Mac', 'Capture Thought shortcut: Control-Option-Command-N', 'Apps/TheoNotesMac/Sources/Capture/KeyCombo.swift', '/// Control + Option + Command + N (`kVK_ANSI_N` = 45).'),
    ('Mac', 'Settings ▸ Capture: Capture Thought shortcut', 'Apps/TheoNotesMac/Sources/Settings/CaptureSettingsView.swift', 'Toggle("Capture Thought shortcut", isOn: Binding(get: { settings.shortcutEnabled }, set: model.setShortcutEnabled))'),
    ('Mac', 'Settings ▸ Capture: Show in menu bar', 'Apps/TheoNotesMac/Sources/Settings/CaptureSettingsView.swift', 'Toggle("Show in menu bar", isOn: $settings.showInMenuBar)'),
    ('Mac', 'The Capture tab of Settings', 'Apps/TheoNotesMac/Sources/Settings/SettingsView.swift', 'case .capture: "Capture"'),
    ('Mac', 'View ▸ Quick Open… (⌘O)', 'Apps/TheoNotesMac/Sources/Commands/TheoNotesCommands.swift', 'Button("Quick Open…") { app?.showQuickOpen(main: window, noteWindow: noteWindow) }'),
    ('Mac', '⌘F Find in a note (Edit ▸ Find)', 'Apps/TheoNotesMac/Sources/Commands/FormatCommands.swift', 'FormatMenuItem("Find…", .find, KeyboardShortcut("f", modifiers: .command)),'),
    ('Mac', 'Note ▸ Next Up', 'Apps/TheoNotesMac/Sources/Commands/TheoNotesCommands.swift', 'Button(NextUpMenu.title) { app?.showNextUp(preferring: window) }'),
    ('Mac', 'File ▸ Capture Voice Note', 'Apps/TheoNotesMac/Sources/Focus/VoiceCapturePanel.swift', 'static let captureTitle = "Capture Voice Note"'),
    ('Mac', 'Edit ▸ Insert Voice Note', 'Apps/TheoNotesMac/Sources/Focus/VoiceCapturePanel.swift', 'static let insertTitle = "Insert Voice Note"'),
    ('Mac', 'Note ▸ Next Up', 'Apps/TheoNotesMac/Sources/Focus/NextUpPanel.swift', 'static let title = "Next Up"'),
    ('Mac', 'Note ▸ Remind Me…', 'Apps/TheoNotesMac/Sources/Focus/ReminderSheet.swift', 'static let title = "Remind Me"'),
    ('Mac', 'Note ▸ Note History…', 'Apps/TheoNotesMac/Sources/Focus/NoteHistorySheet.swift', 'static let title = "Note History…"'),
    ('Mac', 'Note ▸ Privacy ▸ Lock Note / Remove Lock from Note / Lock Now', 'Apps/TheoNotesMac/Sources/Commands/TheoNotesCommands.swift', 'static let lockNote = "Lock Note"'),
    ('Mac', 'Lock Now', 'Apps/TheoNotesMac/Sources/Commands/TheoNotesCommands.swift', 'static let lockNow = "Lock Now"'),
    ('Mac', 'File ▸ Import Notes…', 'Apps/TheoNotesMac/Sources/Import/ImportCommands.swift', 'Button("Import Notes…") { choose(.notes) }'),
    ('Mac', 'File ▸ Import From', 'Apps/TheoNotesMac/Sources/Import/ImportCommands.swift', 'Menu("Import From") {'),
    ('Mac', 'File ▸ Export Notes…', 'Apps/TheoNotesMac/Sources/Export/ExportCommands.swift', 'Button("Export Notes…") {'),
    ('Mac', 'File ▸ Print…', 'Apps/TheoNotesMac/Sources/Export/PrintCommands.swift', 'Button("Print…") {'),
    ('Mac', 'File ▸ Backup Notes…', 'Apps/TheoNotesMac/Sources/Backup/BackupCommands.swift', 'Button("Backup Notes…") { window?.backup.backUp() }'),
    ('Mac', 'File ▸ Restore Backup…', 'Apps/TheoNotesMac/Sources/Backup/BackupCommands.swift', 'Button("Restore Backup…") { window?.backup.chooseBackupToRestore() }'),
    ('Mac', 'Help ▸ Restore Getting Started Notes', 'Apps/TheoNotesMac/Sources/Help/GettingStartedMenu.swift', 'static let title = "Restore Getting Started Notes"'),
    ('Mac', 'View ▸ Sort Inbox', 'Apps/TheoNotesMac/Sources/Commands/TheoNotesCommands.swift', 'Button("Sort Inbox") { window?.showSortInbox() }'),
    ('Mac', 'Sort Inbox button in the list', 'Apps/TheoNotesMac/Sources/Library/NoteListView.swift', 'Button("Sort Inbox", systemImage: "tray.full") { state.showSortInbox() }'),
    ('Mac', 'Sort Inbox: Open', 'Apps/TheoNotesMac/Sources/Library/SortInboxSheet.swift', 'Button("Open") { open(note.id) }'),
    ('Mac', 'Archive the Rest…', 'Apps/TheoNotesMac/Sources/Library/SortInboxSheet.swift', 'Button("Archive the Rest…") { confirmsArchiveRest = true }'),
    ('Mac', 'Note ▸ Type', 'Apps/TheoNotesMac/Sources/Library/NoteTypeMenu.swift', 'static let submenu = "Type"'),
    ('Mac', 'Info panel: Backlinks', 'Apps/TheoNotesMac/Sources/Info/InfoPanelModel.swift', 'case .backlinks: "Backlinks"'),
    ('Mac', '⌘N New Note', 'Apps/TheoNotesMac/Sources/Commands/TheoNotesCommands.swift', '.keyboardShortcut("n")'),
    ('Mac', '⌘O Quick Open', 'Apps/TheoNotesMac/Sources/Commands/TheoNotesCommands.swift', '.keyboardShortcut("o")'),
    ('Mac', 'Settings ▸ General ▸ Hide Markdown', 'Apps/TheoNotesMac/Sources/Settings/SettingsView.swift', 'Toggle("Hide Markdown", isOn: settings.binding(.hideMarkdown, \\.hideMarkdown))'),
    ('Mac', 'Settings ▸ General ▸ Checked to-dos at bottom', 'Apps/TheoNotesMac/Sources/Settings/SettingsView.swift', 'Toggle("Checked to-dos at bottom"'),
    ('Mac', 'Settings ▸ Privacy ▸ Require Touch ID or your Mac password…', 'Apps/TheoNotesMac/Sources/Settings/PrivacySettingsView.swift', 'Toggle("Require Touch ID or your Mac password to open Theo Notes", isOn: Binding('),
    ('Mac', 'Settings ▸ Privacy ▸ lock delay for notes', 'Apps/TheoNotesMac/Sources/Settings/PrivacySettingsModel.swift', 'private(set) var noteRelockDelay: Int'),
    ('Mac', 'Share extension and Login Items & Extensions approval', 'Apps/TheoNotesMac/Sources/Settings/CaptureSettingsView.swift', 'private static let approvalMessage = "Allow Theo Notes in System Settings ▸ General ▸ Login Items."'),
    ('Mac', 'Wiki link: ⌘-click opens, ⌥⌘-click opens in a new window', 'web/editor/src/editor/features/links.ts', '/** ⌘-click opens the link, wiki link or tag under the pointer (⌥⌘: a wiki link in a new window). */'),
    ('Mac', 'Open Link command ⇧⌘K', 'web/editor/src/editor/features/commands.ts', '{ key: "Mod-Shift-k", command: "openLink" },'),
    ('Both', 'To-do box toggles on click', 'web/editor/src/editor/features/todos.ts', 'el.addEventListener("click", (event) => {'),
    ('iOS', 'A tap on a link opens it (note 1, 3)', 'web/editor/src/editor/features/links.ts', 'const touchTap = ViewPlugin.fromClass('),
    ('iOS', 'A tapped wiki link with a heading opens that note at the heading (note 1)', 'Apps/TheoNotesIOS/Sources/MobileEditor.swift', 'let link = WikiLinkRef(target: request.target, heading: request.heading)'),
    ('iOS', 'Note Actions > Copy As (Markdown, Plain Text, HTML, Rich Text)', 'Apps/TheoNotesIOS/Sources/MobileLibraryView.swift', 'Menu("Copy As", systemImage: "doc.on.clipboard") {'),
    ('iOS', 'Copy As choices', 'Apps/TheoNotesIOS/Sources/MobileCopyAs.swift', 'case .markdown: "Markdown"; case .plainText: "Plain Text"'),
    ('iOS', 'Settings > iCloud row', 'Apps/TheoNotesIOS/Sources/MobileSettings.swift', 'Label(MobileCloudSyncStrings.pageTitle'),
    ('iOS', 'iCloud page title', 'Apps/TheoNotesIOS/Sources/MobileCloudSyncStrings.swift', 'static let pageTitle = "iCloud"'),
    ('iOS', 'Sync with iCloud switch', 'Apps/TheoNotesIOS/Sources/MobileCloudSyncStrings.swift', 'static let switchLabel = "Sync with iCloud"'),
    ('iOS', 'Notes are encrypted on the device; a backup is saved first', 'Apps/TheoNotesIOS/Sources/MobileCloudSyncStrings.swift', 'brings them to your other devices. Your notes are encrypted on this device'),
    ('iOS', 'First device of an iCloud account: recovery words sheet', 'Apps/TheoNotesIOS/Sources/MobileCloudSyncController.swift', '} catch CloudCoordinatorError.recoveryChoiceRequired {'),
    ('iOS', 'Save your recovery words (24 words)', 'Apps/TheoNotesIOS/Sources/MobileCloudSyncStrings.swift', 'static let sheetTitle = "Save your recovery words"'),
    ('iOS', 'Note password asked to start syncing', 'Apps/TheoNotesIOS/Sources/MobileCloudSyncStrings.swift', 'static let notePasswordPrompt'),
    ('iOS', 'Settings > General > Keep Tags in Exports', 'Apps/TheoNotesIOS/Sources/MobileSettings.swift', 'Toggle("Keep Tags in Exports"'),
    ('iOS', 'From Template at the bottom of the note list', 'Apps/TheoNotesIOS/Sources/MobileLibraryView.swift', 'Button("From Template", systemImage: "doc.badge.plus") { showingTemplates = true }.accessibilityIdentifier("list-from-template")'),
    ('iOS', 'New from Template sheet: Create', 'Apps/TheoNotesIOS/Sources/MobilePanels.swift', 'Button("Create") {'),
    ('Mac', 'Settings ▸ iCloud tab', 'Apps/TheoNotesMac/Sources/Sync/CloudSyncStrings.swift', 'static let tabTitle = "iCloud"'),
    ('Mac', 'The iCloud tab is shown when the build offers iCloud sync (Release: yes)', 'Apps/TheoNotesMac/Sources/Settings/SettingsView.swift', 'if environment.cloudSyncAvailable { CloudSyncSettingsView(controller: environment.cloudSync) }'),
    ('Both', 'Release builds offer iCloud sync (REL-R91)', 'project.yml', 'REL-R91 (Jan, 2026-11-10): version 1 ships with iCloud sync'),
    ('Mac', 'Sync with iCloud switch', 'Apps/TheoNotesMac/Sources/Sync/CloudSyncStrings.swift', 'static let switchLabel = "Sync with iCloud"'),
    ('Mac', 'Notes are encrypted on the Mac; a backup is saved first', 'Apps/TheoNotesMac/Sources/Sync/CloudSyncStrings.swift', 'brings them to your other devices. Your notes are encrypted on this Mac'),
    ('Mac', 'First device of an iCloud account: recovery words sheet', 'Apps/TheoNotesMac/Sources/Sync/CloudSyncController.swift', 'beginRecoverySheet(.firstSetup)'),
    ('Mac', 'Save your recovery words (24 words)', 'Apps/TheoNotesMac/Sources/Sync/CloudSyncStrings.swift', 'static let sheetTitle = "Save your recovery words"'),
    ('Mac', 'Note password asked to start syncing', 'Apps/TheoNotesMac/Sources/Sync/CloudSyncStrings.swift', 'static let notePasswordPrompt'),
    ('Both', 'iCloud Keychain carries the key; it must be on', 'Packages/TheoNotesCore/Sources/TheoNotesCore/CloudSync/CloudSyncState.swift', 'Check that iCloud Keychain is turned on'),
    ('Both', 'The same iCloud account on every device', 'Apps/TheoNotesMac/Sources/Sync/CloudSyncStrings.swift', 'case .accountChanged: "Different iCloud account"'),
    ('Mac', 'File ▸ Import Notes… takes folders', 'Apps/TheoNotesMac/Sources/Import/ImportCommands.swift', '+ [UTType.folder]'),
    ('Both', 'A folder of Markdown such as an Obsidian vault', 'Packages/TheoNotesCore/Sources/TheoNotesCore/Import/FileImporter.swift', 'and folders of Markdown (Obsidian, UpNote, Apple Notes exports)'),
    ('Mac', 'Import From ▸ Bear… / Apple Notes… / Apple Notes Export… / Evernote… / Notion…', 'Apps/TheoNotesMac/Sources/Import/ImportCommands.swift', 'Menu("Import From") {'),
    ('Mac', 'Edit ▸ Copy As', 'Apps/TheoNotesMac/Sources/Export/CopyAsCommands.swift', 'Menu("Copy As") {'),
    ('Mac', 'Settings ▸ General ▸ Keep tags when exporting and copying', 'Apps/TheoNotesMac/Sources/Settings/SettingsView.swift', 'Toggle("Keep tags when exporting and copying"'),
    ('Mac', 'Settings ▸ Advanced: Last daily copy', 'Apps/TheoNotesMac/Sources/Settings/SettingsView.swift', 'LabeledContent("Last daily copy")'),
    ('Mac', 'File ▸ New Note from Template…', 'Apps/TheoNotesMac/Sources/Commands/TheoNotesCommands.swift', 'Button("New Note from Template…")'),
    ('Both', 'Template: a note tagged #template', 'Packages/TheoNotesCore/Sources/TheoNotesCore/Templates/Templates.swift', '/// A note that serves as a template: tagged `#template`'),
    ('Both', 'Template placeholders {{date}} and {{weekday}}', 'Packages/TheoNotesCore/Sources/TheoNotesCore/Templates/Templates.swift', 'case "weekday": return weekday()'),
    ('Both', 'The #template tag is removed from the new note', 'Packages/TheoNotesCore/Sources/TheoNotesCore/Templates/Templates.swift', 'let text = NoteStore.removingTags(from: normalized, matching: isTemplateTag) ?? normalized'),
    ('Both', 'A template is not listed under Logs or Inbox', 'Packages/TheoNotesCore/Sources/TheoNotesCore/Store/LibraryQueries.swift', '"n.location = \'notes\' AND n.noteType = ? AND NOT \\(template.sql)",'),
    ('Mac', 'Settings ▸ Automation: Claude (MCP)', 'Apps/TheoNotesMac/Sources/Settings/AutomationSettingsView.swift', 'Text("Claude (MCP)")'),
    ('Mac', 'Only tags', 'Apps/TheoNotesMac/Sources/Settings/AutomationSettingsView.swift', 'LabeledContent("Only tags")'),
    ('Mac', 'Exclude tags', 'Apps/TheoNotesMac/Sources/Settings/AutomationSettingsView.swift', 'LabeledContent("Exclude tags")'),
    ('Mac', 'Copy Claude config', 'Apps/TheoNotesMac/Sources/Settings/AutomationSettingsView.swift', 'Button("Copy Claude config")'),
    ('Mac', 'Copy Claude Code command', 'Apps/TheoNotesMac/Sources/Settings/AutomationSettingsView.swift', 'Button("Copy Claude Code command")'),
    ('Mac', 'The tags go into what is copied', 'Apps/TheoNotesMac/Sources/Settings/AutomationSettingsView.swift', 'ClaudeConfig.desktopSnippet(binary: binaryPath, onlyTags: onlyList, excludeTags: excludeList)'),
    ('Mac', "Merge the theonotes entry; Theo Notes never edits Claude's files", 'Apps/TheoNotesMac/Sources/Settings/AutomationSettingsView.swift', 'claude_desktop_config.json: if your file already has "mcpServers", merge the "theonotes" entry'),
    ('Mac', 'Command-line tool: Install in ~/.local/bin', 'Apps/TheoNotesMac/Sources/Settings/AutomationSettingsView.swift', 'Button("Install in ~/.local/bin")'),
    ('Mac', 'Command-line tool header', 'Apps/TheoNotesMac/Sources/Settings/AutomationSettingsView.swift', 'Text("Command-line tool")'),
    ('Mac', "MCP search_notes (find and summarize, open to-dos, this week's logs)", 'Packages/TheoNotesCore/Sources/TheoNotesAutomation/Generated/MCPToolCatalog.swift', '"name":"search_notes"'),
    ('Mac', 'MCP create_note with tags (file a note, weekly review)', 'Packages/TheoNotesCore/Sources/TheoNotesAutomation/Generated/MCPToolCatalog.swift', '"name":"create_note","outputSchema"'),
    ('Mac', 'MCP append_to_note (add to a running log)', 'Packages/TheoNotesCore/Sources/TheoNotesAutomation/Generated/MCPToolCatalog.swift', '"name":"append_to_note"'),
    ('Mac', 'MCP capture_thought (catch a thought)', 'Packages/TheoNotesCore/Sources/TheoNotesAutomation/Generated/MCPToolCatalog.swift', '"name":"capture_thought"'),
    ('Both', 'Search: @todo, @last7days, #tag', 'Packages/TheoNotesCore/Sources/TheoNotesCore/Search/SearchParser.swift', '.init(prefix: "last", suffix: "days", created: false, chineseNumerals: false),'),
    ('Mac', 'theonotes search', 'Packages/TheoNotesCore/Sources/TheoNotesAutomation/CLI/CommandTable.swift', '["search"], arguments: [ArgumentSpec(name: "query-arg")],'),
    ('Mac', 'theonotes create --content --tags', 'Packages/TheoNotesCore/Sources/TheoNotesAutomation/CLI/CommandTable.swift', '["create"], arguments: [ArgumentSpec(name: "title")],'),
    ('Mac', 'theonotes append --title --content', 'Packages/TheoNotesCore/Sources/TheoNotesAutomation/CLI/CommandTable.swift', '["append"],'),
    ('Mac', 'Formatting bar at the bottom of the note: Heading, Todo, Lists, Bold, Italic, Highlight, Link, Create Table, File…', 'Apps/TheoNotesMac/Sources/EditorHost/FormattingBar.swift', 'static let controls: [Control] = ['),
    ('Mac', 'View ▸ Hide Formatting Bar', 'Apps/TheoNotesMac/Sources/EditorHost/FormattingBar.swift', 'static let hideTitle = "Hide Formatting Bar"'),
    ('Mac', 'View ▸ Show / Hide Formatting Bar (⇧⌘Y)', 'Apps/TheoNotesMac/Sources/Commands/TheoNotesCommands.swift', 'Button(FormattingBar.viewMenuTitle(shown: showsFormattingBar))'),
    ('Mac', '⇧⌘Y', 'Apps/TheoNotesMac/Sources/EditorHost/FormattingBar.swift', 'static let shortcut = KeyboardShortcut("y", modifiers: [.command, .shift])'),
]


def table() -> str:
    out, missing = [], []
    for platform, what, path, needle in ROWS:
        lines = (ROOT / path).read_text(encoding="utf-8").splitlines()
        hit = next((i + 1 for i, line in enumerate(lines) if needle in line), None)
        if hit is None:
            missing.append(f"{path}: {needle}")
        else:
            out.append(f"| {platform} | {what} | `{path}:{hit}` |")
    if missing:
        sys.exit("not found:\n" + "\n".join(missing))
    return "\n".join(out) + "\n"


def main() -> None:
    rows = table()
    if "--write" in sys.argv[1:]:
        text = DOC.read_text(encoding="utf-8")
        start = text.index(HEADER) + len(HEADER)
        DOC.write_text(text[:start] + rows, encoding="utf-8")
    else:
        sys.stdout.write(rows)


if __name__ == "__main__":
    main()
