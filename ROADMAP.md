# ScratchPad roadmap

ScratchPad is a native macOS scratch pad: an AppKit shell around a CodeMirror 6 editor, with scratches
stored as plain files in `~/Library/Application Support/ScratchPad/scratches`.

This document lists what is built today and the ideas worth doing next.

## Implemented

### Scratches and files
- Scratches are ordinary files, so the folder can be synced, grepped or put under git. Edits save automatically (debounced).
- The file type comes from the extension and can be changed later. When content is pasted into an empty scratch or used for "New Scratch from Clipboard", its type is detected automatically (JSON, XML, HTML, Markdown, HTTP, diff, CSV/TSV, code and more).
- Scratches can be organised in folders: a folders column, drag and drop, creating a folder from the "new" menu, and rename, move and delete.
- The sidebar list can be grouped by type or by date edited. A two-row header holds the controls and a clickable breadcrumb. Use ⌃⌘S to show or hide the sidebar, and ⌘1 to reveal the current scratch in it.
- **Tabs:** Chrome-style tabs for open files in the toolbar. Drag to reorder, middle-click or × to close, double-click to rename, and right-click for Close Others / Close to the Left / Close to the Right. ⌘W closes a tab, ⌥⌘W closes the others, and ⌃⇥ / ⌃⇧⇥ switch tabs.
- Navigation:
  - Back and forward history.
  - Recent Scratches (⌘E), which also lists files opened from outside the scratch folder.
  - Next and previous scratch.
- **Go to Symbol (⌘[)** shows an outline of the current file for every file type. Languages with a Lezer grammar are read from the syntax tree; the others (HTTP requests, SQL statements, tables, plain text) from their lines.
- **Go to Scratch by Name (⇧⌘O)** works like IntelliJ's "Go to File":
  - Fuzzy matching on camel humps and word starts, e.g. `apcl` finds `api-client.http` and `FIS` finds `FindInScratches`.
  - Matched letters are highlighted.
  - `folder/name` queries match the folder, and a trailing `name:42` jumps to that line.
  - Folders and opened files are included in the results.
- **Opening outside files:**
  - Drop files on the Dock icon, use Finder's "Open With", or press ⌘O.
  - Files open in place and edits save to the original file.
  - Binary, non-UTF-8 and very large files are refused with a message.
  - "Copy into Scratches" makes a scratch copy of an outside file.
- **External folders:**
  - Add any folder with `scratchpad <folder>`, by dropping it on the Dock icon or the sidebar, or with Add Folder to Sidebar… (⌥⌘O).
  - It appears in the folder tree and the folders column, marked External (orange, with its location), with subfolders collapsed.
  - Its files open in place; new files, renames, moves within that folder and deletes act on the real files.
  - Build output, dependencies (`node_modules`, `build`, `target`…), hidden files and binaries are skipped, with at most 5,000 files per folder.
  - Changes on disk are picked up live. "Remove from Sidebar" forgets the folder without touching it.
- **Command line tool** (ScratchPad ▸ Install Command Line Tool… links `/usr/local/bin/scratchpad`):
  - `scratchpad file…` opens files;
  - `scratchpad folder` (or `.`) adds an external folder;
  - `command | scratchpad -` turns piped text into a new scratch with its type detected.
- Copy File Path, Copy File, Reveal in Finder, and multi-select actions (compare, copy, delete).

### Editor
- CodeMirror 6 with syntax highlighting for JSON, XML, HTML, Markdown, HTTP, diff, CSV/TSV, JavaScript/TypeScript, Java, Python, shell, CSS, SQL, YAML, OpenAPI/Swagger, TOML, properties, Kotlin, Go, Rust and C/C++.
- IntelliJ-style keymap, which can be customised:
  - multi-caret editing (next occurrence, carets above and below, carets at line ends);
  - extend and shrink selection, duplicate, delete or move lines;
  - line and block comments, matching bracket, go to line;
  - folding: ⌘⇧+ and ⌘⇧− fold and unfold, plus Collapse All and Expand All.
- Find and replace in the open file.
- **Find in Files (⇧⌘F)** searches scratches, external folders and opened files:
  - Filters: **In** (everywhere, scratches, any folder, an external folder or its subfolders, opened files), **Type** (with file counts) and **File mask** (`*.json, !*test*`). Reset Filters undoes them.
  - Match case, whole words and regular expressions are remembered between uses.
  - Results are grouped by file, with location, an EXTERNAL or OPENED tag, and match counts.
  - A preview pane shows the lines around the selected match, with every match highlighted.
  - Right-click a result to copy `path:line`, reveal it, or narrow the search to its folder or type.
  - Rich text documents are searched too. Every folder menu has "Find in This Folder…".
- Reformat and compact for JSON and XML.
- Soft wrap, and font zoom with ⌘+, ⌘− and Reset Font Size.
- Find Action (⇧⌘A) runs any command, dev tool or text transform (encode/decode, hash, case conversion, line tools, time, insert).

### Preview
- Markdown and HTML preview: off, split or full. Markdown is sanitised and renders Mermaid diagrams; HTML runs in a sandboxed iframe with scripts disabled.
- **OpenAPI / Swagger** specs (`openapi.yaml`, `swagger.json`…) render as an API reference with Swagger UI, Scalar or the Kong spec renderer, all bundled so they work offline.
- **Export:** Markdown and HTML previews export as PDF, HTML or MHTML; OpenAPI references export as a self-contained HTML page or MHTML.
- **Copy Preview as Rich Text:** a Copy button in the Markdown preview (and a menu command) puts HTML, RTF and plain text on the clipboard, so it pastes formatted into Mail, Notes, Docs, Confluence or Slack.

### CSV and TSV
- CSV (`.csv`) and TSV (`.tsv`, `.tab`) file types. Each column is coloured differently, and the header row is emphasised.
- Table preview:
  - a sticky header and row numbers;
  - numeric columns are right-aligned;
  - missing cells are flagged;
  - a rows × columns and delimiter summary.
- **Smart paste:** pasting into a CSV/TSV scratch converts the delimiter automatically. Comma, semicolon, tab or pipe rows are rewritten to match the file, and tables copied from a spreadsheet or web page (HTML) become rows.
- Pasted CSV/TSV is recognised as a table and opens with the table preview.

### Rich text
- A Rich Text file type, saved as `.rtfd` (opens in TextEdit and Quick Look). Plain `.rtf` files are also supported, but text only.
- Formatting bar and Format menu:
  - text styles: Title, Heading, Subheading, Body and Monospaced;
  - size, bold (⌘B), italic (⌘I), underline (⌘U) and strikethrough;
  - text colour and highlight;
  - left, centre, right and justified alignment;
  - bulleted and numbered lists;
  - the Fonts panel (⌘T), clear formatting, and a word count.
- Images:
  - paste, drop, or Insert Image…;
  - resize by dragging corner handles (with a live size readout) or from presets (Small, Medium, Large, Fit Width, Original);
  - sizes are kept when saved.
- Find (⌘F), zoom, and undo work as usual.
- Converting a scratch between rich text and a plain type converts its content.

### Running code
- Run Java (pick a JDK), JavaScript (Node, falling back to JavaScriptCore), TypeScript, Python and shell scratches, with a run console.
- A shared npm `package.json` and `node_modules` for JS/TS scratches.
- HTTP client for `.http` files: run one request or all of them, copy as cURL, paste cURL, open a response in a new scratch. `@name = value` variables, dynamic variables (`{{$uuid}}`, `{{$timestamp}}`, `{{$isoTimestamp}}`, `{{$randomInt}}`) and `< path` file bodies are supported.
- Diff scratches: compare two scratches, or a scratch with the clipboard, in a side-by-side diff view.

### Dev tools
- Dedicated pages: Base64, URL encoding, HTML entities, string escaping, hex, a JWT decoder, hashes (including HMAC), a case converter, line tools, text statistics, timestamps and generators.
- **MCP Tester:** connects to Model Context Protocol servers over stdio or SSE/HTTP, configured with `mcpServers` JSON or form fields. It shows server info, lists tools, prompts and resources, and calls tools through a form generated from each tool's input schema.

## Roadmap ideas

### Near term
- **Rich text:**
  - Export to HTML, Markdown and PDF.
  - Links (⌘K insert or edit), checklists, and inline code style.
  - Copy as Markdown.
  - Simple tables.
  - Keep images in `.rtf` by offering to convert to `.rtfd`.
- **Search:** replace in files, saved searches, search history, and a .gitignore-aware external folder scan.
- **CSV/TSV:**
  - Sort and filter in the table preview.
  - Edit cells in place.
  - Column statistics (sum, average, distinct).
  - Convert to and from JSON, Markdown tables and SQL `INSERT`s.
  - Pin the header row in the editor.
- **Opened files:**
  - Reload when the file changes on disk, and warn on conflicting edits.
  - Show a badge for "outside" files in the breadcrumb.
  - "Forget" entries from Recent.
- **Go to Scratch:** search file *contents* (IntelliJ's Search Everywhere tabs: Files, Actions, Text).
- **Quick capture:** a global hotkey that opens a small floating scratch window from any app.
- **Menu bar extra:** pinned scratches and "append clipboard to scratch".

### Editing
- Snippets and live templates, with variables such as date, UUID and clipboard.
- Split editors, so two scratches can be shown side by side.
- Markdown helpers: a table formatter, auto-continued lists, paste a URL over a selection to make a link, and a table of contents.
- JSON tools: JSONPath/jq queries, sort keys, convert to YAML, CSV or TypeScript types, and schema validation.
- Inline evaluation for JavaScript and Python (results shown next to lines, like Quokka).
- Spell checking for Markdown and plain text.
- Vim keybindings as an option.

### Organisation
- Pin and star scratches, plus tags and colour labels.
- Automatic archiving of untouched scratches after N days, with a restore option.
- Version history for each scratch: local snapshots with diff and restore.
- Git integration for the scratches folder: commit, history and sync.
- Templates for new scratches (meeting notes, API request, bug report).

### Sharing and sync
- iCloud Drive or a custom folder for the scratches location, for syncing between Macs.
- Share a scratch as a GitHub Gist or a pastebin link.
- Export a folder of scratches as a zip.

### Dev tools
- Regex tester, cron expression explainer, colour converter, UUID/ULID inspector.
- Number base converter, and a unit and data-size converter.
- Text diff of the clipboard history, plus clipboard history itself.
- JWT encoder and signer.
- QR code generator.

### Polish
- Themes, and a choice of fonts for the editor and rich text.
- Light, dark and auto modes for the rich text page.
- Settings import and export, and keymap presets (VS Code, Sublime).
- Quick Look and Spotlight importers, so scratches are searchable system-wide.
- Shortcuts / App Intents actions: create a scratch, append text, run a transform.
- More command line options: `--wait` (for `$EDITOR`/git), `--line N`, `--new json`, and an "open in ScratchPad" Finder Quick Action.
