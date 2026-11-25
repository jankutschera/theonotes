# Use Theo Notes with Claude

#getting started#

You want Claude to work from your notes, as the second brain you may keep in another tool today. On the Mac, Claude can search, read and write your notes. This note shows how to connect it and what to ask.

On iPhone and iPad there is no Claude connection and no command-line tool. They have Apple Shortcuts actions and a URL scheme instead: see Settings ▸ Advanced ▸ API Token and URL Scheme. With iCloud sync on, what Claude writes on the Mac reaches them at the next sync.

## Connect Claude

1. Open Settings ▸ Automation and find Claude (MCP).
2. If Claude should see only some notes, fill in Only tags or Exclude tags first (see below).
3. For Claude Desktop, press **Copy Claude config** and add the `theonotes` entry to Claude Desktop's `claude_desktop_config.json`, then quit and reopen Claude Desktop. For Claude Code, press **Copy Claude Code command** and paste it into Terminal.

Theo Notes never edits Claude's own files, so you paste it yourself.

## Choose what Claude can see

Only tags limits Claude to the notes with those tags and the tags nested below them. Exclude tags keeps such notes out of reach, for example `private`. Leave both empty and Claude can reach the whole library. The tags go into what you copy, so copy and paste again after you change them. Locked notes can be listed, but their text stays closed.

## Ask for second-brain work

- "Find everything I wrote about the garden project and summarize it"
- "File this as a new note tagged work/acme: the client wants the draft on Friday"
- "Add today's decisions to my note Work log"
- "Catch this thought for me: call the dentist", which lands in the Inbox
- "List my open to-dos across all notes"
- "Read this week's logs and write my weekly review as a new note"

## Coming from another tool

Bring your notes over first, so Claude finds them here: [[Import, export and back up]] shows how, for Markdown folders, Evernote, Notion and Apple Notes.

## The theonotes command

The same library works from Terminal. Under Command-line tool in Settings ▸ Automation, press **Install in ~/.local/bin**. Then try:

```
theonotes search "weekly review"
theonotes create "Shopping list" --content "Milk" --tags groceries
theonotes append --title "Shopping list" --content "Eggs"
```

The app shows changes right away. Claude Code can run the same commands for you.

Back to the start: [[Welcome to Theo Notes]].
