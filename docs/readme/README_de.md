<p align="center">
  <img src="../brand/app-icon-1024.png" width="128" height="128" alt="App-Symbol von Theo Notes">
</p>

<h1 align="center">Theo Notes</h1>

<p align="center">
  <strong>Open-Source-Alternative zu Apple Notizen und Obsidian: Markdown-Notizen für Mac, iPhone, iPad und Apple Watch, mit einem MCP-Server für Claude.</strong>
</p>

<p align="center">
  <a href="https://apps.apple.com/app/id6832478875">App Store (iPhone, iPad, Apple Watch)</a> ·
  <a href="https://theonotes.app/download">Download für den Mac</a> ·
  <a href="https://theonotes.app">theonotes.app</a> ·
  <a href="../../README.md">English</a>
</p>

<p align="center">
  <img src="claude-mcp.gif" alt="Claude fragt theonotes mcp-server nach den offenen Aufgaben einer Reisenotiz und fügt eine Aufgabe hinzu">
</p>

## Was es ist

Theo Notes ist eine Notiz-App, die jede Notiz als Markdown speichert, genau so, wie du sie getippt hast.

- **Schreiben in Markdown** mit Überschriften, Listen, To-dos, Tabellen, Callouts, Codeblöcken, Formeln und Diagrammen. Die Formatierungszeichen treten beim Schreiben in den Hintergrund.
- **Ordnen mit Tags**, auch verschachtelt wie `#arbeit/kunden`, und Notizen untereinander verlinken.
- **Alles finden**: Volltextsuche über alle Notizen, auch Text in Bildern und gescannten PDFs.
- **Notizen sperren** mit Passwort (Touch ID und Face ID, wo verfügbar).
- **Sync über dein eigenes iCloud-Konto** zwischen Mac, iPhone und iPad.
- **Schnell festhalten**: Teilen-Menü, Widgets, Kurzbefehle und eine Watch-App für diktierte Notizen.
- **Notizen mitnehmen**: Import aus Apple Notizen, Evernote, Notion, Bear, Markdown-Dateien und ZIP-Archiven; Export als Markdown, HTML, PDF und vollständiges Backup.
- **Mit Claude und anderen KI-Werkzeugen nutzen**: Das Kommandozeilenwerkzeug `theonotes` liest, durchsucht und schreibt deine Notizen, `theonotes mcp-server` bietet dasselbe als MCP-Server.

## Mit Claude nutzen

Die Mac-App bringt einen MCP-Server mit, `theonotes mcp-server`, der deine Bibliothek über stdio an Claude gibt. Er läuft auf deinem Mac und liest die Bibliothek dort; nichts geht an einen Server von uns.

**Claude Desktop (ein Klick):** Installiere die Mac-App (ab 1.2) und öffne sie einmal, dann **Settings → Automation** öffnen und **Connect to Claude** klicken. Claude zeigt seinen eigenen Installationsdialog; klicke **Install**. Optional fragt er nach **Only tags** / **Exclude tags**, um einzuschränken, welche Notizen Claude sieht.

**Claude Code:** Füge dieses Repository als Plugin-Marktplatz hinzu und installiere das Plugin:

```text
/plugin marketplace add https://github.com/jankutschera/theonotes
/plugin install theonotes@theonotes
```

Das Plugin startet den Server in der installierten App und wird so mit der App aktualisiert. Die Tag-Grenzen stehen unter `/config`.

Dann frag Claude zum Beispiel: „Was ist in meiner Reisenotiz noch offen?“

Der Server liest und schreibt die Bibliothek direkt; die App muss dafür nicht laufen. Die App-Sperre gilt für ihn nicht.

**Andere Wege:** **Settings → Automation → Other ways to connect** kopiert einen Eintrag für `claude_desktop_config.json` oder einen `claude mcp add`-Befehl fürs Terminal, mit `--only-tags` / `--exclude-tags` aus den Feldern. Andere MCP-Clients starten `theonotes mcp-server` genauso (vorher **Install in ~/.local/bin** klicken, dann gilt der kurze Pfad `~/.local/bin/theonotes`).

### Ohne die App

Einen eigenen Download von `theonotes` gibt es noch nicht. Du kannst es aus diesem Repository nur mit Swift bauen:

```sh
cd Packages/TheoNotesCore
swift build -c release --product theonotes
.build/release/theonotes --help
```

Es braucht eine bestehende Theo-Notes-Bibliothek und legt selbst keine an. Standardmäßig nutzt es die Bibliothek der installierten Mac-App; `--data-dir <pfad>` oder `THEONOTES_DATA_DIR` zeigt auf eine andere.

## App holen

| Plattform | Wo | Voraussetzung |
|---|---|---|
| Mac | [theonotes.app/download](https://theonotes.app/download) (kostenlos, notarisiert) | macOS 26 oder neuer |
| iPhone und iPad | [App Store](https://apps.apple.com/app/id6832478875) (kostenlos) | iOS / iPadOS 26 oder neuer |
| Apple Watch | wird mit der iPhone-App installiert | watchOS 26 oder neuer |

## Aus dem Quellcode bauen, Lizenz, Mitmachen

Bauanleitung, Lizenz (GPL-3.0-only), Markenhinweise und Regeln fürs Mitmachen stehen im [englischen README](../../README.md). Diese Übersetzung kann hinter dem englischen Original zurückliegen; im Zweifel gilt das Original.

Name, Logo und App-Symbol von „Theo Notes“ sind Marken der True Brew Birdie Ltd. und nicht von der GPL umfasst. Bear, Evernote, Notion, Obsidian und Apple Notizen sind Marken ihrer jeweiligen Inhaber; Theo Notes ist mit ihnen nicht verbunden. Claude ist eine Marke von Anthropic; Theo Notes ist mit Anthropic nicht verbunden.
