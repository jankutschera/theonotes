# Use Theo Notes with Claude

#getting started#

On the Mac, Claude can work with your notes: search them, read them, add to them, or catch a thought for you. There are two ways in, and both live in Settings ▸ Automation.

## The theonotes command

Theo Notes comes with a small command-line tool called `theonotes`. In Settings ▸ Automation, choose Install under Command-line tool. Then try these in Terminal:

```
theonotes list
theonotes search "weekly review"
theonotes cat --title "Welcome to Theo Notes"
theonotes create "Shopping list" --content "Milk" --tags groceries
theonotes append --title "Shopping list" --content "Eggs"
```

It works on the same library as the app, and the app shows changes right away. Claude Code can run the same commands for you.

## The Claude connection

Theo Notes also speaks MCP, the way Claude connects to tools. Under Claude (MCP) in the same settings, press Copy Claude config for Claude Desktop, or Copy Claude Code command to paste into Terminal. Theo Notes never edits Claude's own files, so you paste it yourself.

Then you can ask things like:

- "Find my notes about the roadmap and summarize them"
- "Add this to my shopping list note"
- "Catch this thought for me: call the dentist"

## Choose what Claude can see

Use Only tags and Exclude tags in the same place to limit Claude to some notes, or to keep some out of reach. Leave both empty and Claude can reach the whole library. Locked notes can be listed, but their text stays closed.

Back to the start: [[Welcome to Theo Notes]].
