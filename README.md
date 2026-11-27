# ScratchPad

A native macOS scratch pad for developers. ScratchPad is an AppKit app wrapped around a
[CodeMirror 6](https://codemirror.net/) editor. Scratches are plain files on disk, and the app adds the tools you
usually open a browser tab for: running code, sending HTTP requests, previewing Markdown and OpenAPI specs,
diffing text, testing MCP servers, and dozens of encode/decode utilities.

- **Plain files, no database.** Every scratch is a normal file in
  `~/Library/Application Support/ScratchPad/scratches`, so you can grep it, sync it, or put it under git.
- **IntelliJ-style editing.** Multiple carets, extend/shrink selection, line moves, Find Action, Go to Symbol and
  Find in Files, all with keybindings you can customise.
- **Runs things.** Java, JavaScript, TypeScript, Python, shell and `.http` request files run from the editor, with
  output in a console.

Requires macOS 13 (Ventura) or newer.

---

## Contents

- [Install](#install)
- [Features](#features)
  - [Scratches and files](#scratches-and-files)
  - [Editor](#editor)
  - [Supported file types](#supported-file-types)
  - [Navigation and search](#navigation-and-search)
  - [Preview and export](#preview-and-export)
  - [CSV and TSV](#csv-and-tsv)
  - [Rich text](#rich-text)
  - [Running code](#running-code)
  - [HTTP client](#http-client)
  - [Diff](#diff)
  - [Dev tools](#dev-tools)
  - [MCP Tester](#mcp-tester)
- [Command line tool](#command-line-tool)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Settings and data locations](#settings-and-data-locations)
- [Building from source](#building-from-source)
- [Project layout](#project-layout)
- [How it works](#how-it-works)
- [Releasing](#releasing)
- [Roadmap](#roadmap)

---

## Install

Download `ScratchPad-<version>-macos-arm64.zip` from the
[Releases](https://github.com/tsanthosh1/scratchpad/releases) page, unzip it, and move `ScratchPad.app` to
`/Applications`.

The release build is for Apple Silicon and is signed ad hoc, not with an Apple Developer ID, so macOS
Gatekeeper blocks it the first time you open it. Either right-click the app and choose **Open**, or run:

```bash
xattr -dr com.apple.quarantine /Applications/ScratchPad.app
```

To build it yourself, see [Building from source](#building-from-source).

---

## Features

### Scratches and files

- **New Scratch** (⌘N) asks for a name and type. **New Scratch from Clipboard** (⇧⌘N) creates one from the
  clipboard and detects the type (JSON, XML, HTML, Markdown, HTTP, diff, CSV/TSV, code and more). Pasting into an
  empty scratch detects the type the same way.
- Edits save automatically after a short pause. ⌘S saves right away.
- The file type comes from the extension and can be changed later. Changing a scratch between rich text and a
  plain type converts its content.
- **Folders:** create, rename, move and delete folders, and drag scratches between them. A folders column and a
  breadcrumb header sit above the list, which can be grouped by type or by date edited.
- **Tabs:** open files appear as tabs in the toolbar. Drag to reorder, middle-click or × to close, double-click to
  rename, and right-click for Close Others / Close to the Left / Close to the Right.
- **Opening outside files:** ⌘O, Finder's *Open With*, or dropping files on the Dock icon. Outside files are edited
  in place and save back to the original. Binary, non-UTF-8 and very large files are refused with a message.
  *Copy into Scratches* makes a scratch copy.
- **External folders:** add any folder to the sidebar with *Add Folder to Sidebar…* (⌥⌘O), by dropping it on the
  Dock icon or sidebar, or with `scratchpad <folder>`. Its files open in place, and new files, renames, moves and
  deletes act on the real files. Changes on disk show up live. `node_modules`, `build`, `target` and similar
  folders, hidden files and binaries are skipped, up to 5,000 files per folder. *Remove from Sidebar* forgets the
  folder without touching it.
- Copy File Path (⌥⌘C), Copy File (⇧⌘C), Reveal in Finder, and multi-select actions in the list: compare, copy,
  delete.

### Editor

- CodeMirror 6 with syntax highlighting, bracket matching, code folding and autocompletion.
- IntelliJ-style keymap:
  - multiple carets (next occurrence, all occurrences, carets above/below, carets at line ends);
  - extend and shrink selection, select line;
  - duplicate, delete, and move lines; start new line;
  - line and block comments, jump to matching bracket, go to line;
  - folding, with Collapse All and Expand All.
- Find and replace in the current file (⌘F).
- **Reformat Code** (⌥⌘L) for JSON, XML, HTML, Markdown, HTTP, diff, JavaScript, TypeScript, Java, CSS, SQL, YAML
  and OpenAPI, using Prettier, `sql-formatter` and `xml-formatter`. **Compact** (⌥⇧⌘L) minifies JSON and XML.
- Soft wrap, tab size, font family and font size (⌘= / ⌘− / ⌘0) are configurable.
- **Find Action** (⇧⌘A) runs any command, dev tool or text transform by name (encode/decode, hash, case
  conversion, line tools, time, insert).

### Supported file types

| Type | Extensions | Format | Run | Preview |
| --- | --- | :-: | :-: | :-: |
| JSON | `json` `jsonc` `json5` | ✓ (+ compact) | | |
| XML | `xml` `xsd` `xsl` `wsdl` `plist` `svg` `pom` | ✓ (+ compact) | | |
| HTML | `html` `htm` `xhtml` | ✓ | | ✓ |
| Markdown | `md` `markdown` `mdown` | ✓ | | ✓ |
| OpenAPI / Swagger | `openapi.yaml/.yml/.json`, `swagger.yaml/.yml/.json` | ✓ | | ✓ |
| Rich Text | `rtfd` `rtf` | | | native editor |
| CSV / TSV | `csv` / `tsv` `tab` | | | table |
| HTTP | `http` `rest` | ✓ | ✓ | |
| Diff | `diff` | ✓ | | diff view |
| JavaScript | `js` `mjs` `cjs` `jsx` | ✓ | ✓ | |
| TypeScript | `ts` `mts` `cts` `tsx` | ✓ | ✓ | |
| Java | `java` | ✓ | ✓ | |
| Python | `py` | | ✓ | |
| Shell | `sh` `bash` `zsh` | | ✓ | |
| CSS | `css` `scss` `less` | ✓ | | |
| SQL | `sql` | ✓ | | |
| YAML | `yaml` `yml` | ✓ | | |
| TOML, Properties | `toml`, `properties` `env` `ini` `conf` `cfg` | | | |
| Kotlin, Go, Rust, C/C++ | `kt` `kts`, `go`, `rs`, `c` `cc` `cpp` `cxx` `h` `hpp` | | | |
| Plain Text | `txt` `log` | | | |

### Navigation and search

- **Go to Scratch by Name** (⇧⌘O) works like IntelliJ's *Go to File*: fuzzy matching on camel humps and word
  starts (`apcl` finds `api-client.http`), highlighted matches, `folder/name` queries, and `name:42` to jump to a
  line. Folders and opened files are included.
- **Go to Symbol** (⌘[) shows the document's outline for every file type. Languages with a Lezer grammar are read
  from the syntax tree, and others (HTTP requests, SQL statements, tables, plain text) from their lines.
- **Recent Scratches** (⌘E), back/forward history (⌥⌘← / ⌥⌘→), and next/previous scratch (⇧⌘] / ⇧⌘[).
- **Find in Files** (⇧⌘F) searches scratches, external folders and opened files, including rich text documents:
  - filters for **In** (everywhere, scratches, a folder or external folder, opened files), **Type** (with file
    counts) and **File mask** (`*.json, !*test*`);
  - match case, whole words and regex, remembered between uses;
  - results grouped by file, with a preview pane of surrounding lines;
  - right-click a result to copy `path:line`, reveal it, or narrow the search to its folder or type.

### Preview and export

- **Markdown** renders in-page, sanitised with DOMPurify, and supports [Mermaid](https://mermaid.js.org/) diagrams in
  fenced `mermaid` blocks. **HTML** renders in a sandboxed iframe with scripts disabled.
- Toggle the preview with ⇧⌘V (off / split) and full preview with ⌥⇧⌘V.
- **Copy Preview as Rich Text** puts HTML, RTF and plain text on the clipboard, so Markdown pastes formatted into
  Mail, Notes, Docs, Confluence or Slack.
- **OpenAPI / Swagger** specs render as an API reference with your choice of
  [Swagger UI](https://swagger.io/tools/swagger-ui/), [Scalar](https://scalar.com/) or the
  [Kong spec renderer](https://github.com/Kong/spec-renderer). The libraries are bundled, so this works offline.
- **Export** (toolbar button or *Export Preview…*):
  - Markdown/HTML previews export as **PDF**, **HTML** or **MHTML**.
  - OpenAPI references export as a self-contained **HTML** page (viewer library, styles and spec inlined) or
    **MHTML**.

### CSV and TSV

- Each column is coloured differently and the header row is emphasised.
- Table preview with a sticky header, row numbers, right-aligned numeric columns, flagged missing cells, and a
  rows × columns / delimiter summary. Parsing follows RFC 4180 (quoted fields can contain delimiters, newlines and
  doubled quotes).
- **Smart paste:** rows using comma, semicolon, tab or pipe are rewritten to the file's delimiter, and tables copied
  from a spreadsheet or web page become rows.

### Rich text

Rich text scratches are saved as `.rtfd` packages, which open in TextEdit and Quick Look and keep images. Plain
`.rtf` holds text only. They are edited in a native AppKit text view, not the code editor:

- text styles (Title, Heading, Subheading, Body, Monospaced), size, bold, italic, underline, strikethrough, text
  colour and highlight;
- alignment, bulleted and numbered lists, the Fonts panel (⌘T), clear formatting, and a word count;
- images: paste, drop or *Insert Image…*, then resize by dragging the corner handles or with presets (Small,
  Medium, Large, Fit Width, Original).

### Running code

Press **Run** (⌃R) to run the current scratch. Output goes to the run console (⌘4 to toggle, ⌘K to clear) and
**Stop** is ⌘F2. Each run happens in a temporary folder under `~/Library/Caches/ScratchPad/runs`.

| Language | How it runs | Needs |
| --- | --- | --- |
| Java | Single-file source launch (`java Foo.java`) | A JDK. Pick one from those found by `/usr/libexec/java_home` in Settings. |
| JavaScript | `node scratch.js`; falls back to the built-in JavaScriptCore (no `require`, `fs` or timers) if Node isn't found | Node.js (optional) |
| TypeScript | Node's built-in type stripping | Node.js 22.6 or newer |
| Python | `python3 scratch.py` | Python 3 |
| Shell | `/bin/bash scratch.sh` | — |
| HTTP | The built-in HTTP client (see below) | — |

JavaScript and TypeScript scratches share one `package.json` and `node_modules` in
`~/Library/Application Support/ScratchPad/packages`, linked into each run, so `npm install` a package once and
`require`/`import` it from any scratch. Set the Node path and packages folder in Settings if they aren't detected.

### HTTP client

`.http` / `.rest` files use IntelliJ's HTTP request syntax:

```http
@baseUrl = https://httpbin.org

### Create an item
POST {{baseUrl}}/post
Content-Type: application/json

{
  "id": "{{$uuid}}",
  "createdAt": "{{$isoTimestamp}}"
}

### Upload a file
POST {{baseUrl}}/post
Content-Type: application/octet-stream

< ./payload.bin
```

- Requests are separated by `###`. `@name = value` defines a variable used as `{{name}}`. Dynamic variables are
  `{{$uuid}}`, `{{$timestamp}}`, `{{$isoTimestamp}}` and `{{$randomInt}}`.
- A body line of the form `< path` sends that file's contents (absolute, `~`, or relative to the `.http` file's
  folder).
- **Run** (⌃R) sends the request under the cursor. **Run All Requests in File** is ⌥⇧⌃R.
- The response viewer shows status, timing, headers and a pretty-printed body, with copy and search.
  **Open Response in New Scratch** is ⌥⇧⌘O.
- **Copy Request as cURL** (⌥⇧⌘C) and **Paste cURL as HTTP Request** (⌥⇧⌘I) convert between the two.

### Diff

- Compare two scratches (select both in the list, then ⌘D), or a scratch with the clipboard, in a side-by-side
  diff view built on `@codemirror/merge`.
- `.diff` scratches toggle between the raw patch and a diff view with ⇧⌘V.

### Dev tools

Dedicated pages, also reachable from Find Action (⇧⌘A):

| Tool | What it does |
| --- | --- |
| Base64 | Encode and decode, including URL-safe Base64 |
| URL Encoding | Percent-encode and decode |
| HTML Entities | Escape and unescape |
| String Escaping | JSON / Java string literals and `\u` escapes |
| Hex | UTF-8 text ↔ hex |
| JWT Decoder | Claims (with readable names), expiry, and signature check |
| Hash | MD5, SHA-1, SHA-256, SHA-384, SHA-512 and HMAC |
| Case Converter | camelCase, PascalCase, snake_case, CONSTANT_CASE, kebab-case, Title Case |
| Line Tools | Clean, trim, dedupe (optionally ignoring case), sort, shuffle, reverse and join lists |
| Text Statistics | Characters, words, lines and bytes |
| Timestamps | Unix time ↔ dates, across time zones |
| Generators | UUIDs, random strings and passwords |
| MCP Tester | See below |

The same transforms are available on the editor's selection through Find Action.

### MCP Tester

A page for testing [Model Context Protocol](https://modelcontextprotocol.io/) servers:

- Configure servers in the same `mcpServers` JSON format used by Claude Desktop and other MCP clients, or with the
  form fields:
  - **Stdio:** a command with arguments and environment variables (e.g. `DEBUG=1, API_KEY=xyz`);
  - **SSE / HTTP:** a URL such as `http://localhost:8000/sse`, with optional headers (e.g.
    `Authorization: Bearer …`).

  ```json
  {
    "mcpServers": {
      "mcp-remote": {
        "command": "npx",
        "args": ["-y", "mcp-remote", "http://localhost:8000/sse"]
      }
    }
  }
  ```

- Shows the server name, version and protocol version after `initialize`.
- Lists the server's **tools**, **prompts** and **resources**. Tools get an input form generated from their JSON
  schema (string, number, boolean, array and object fields) and can be called with `tools/call`.
- The configuration is remembered between launches.

---

## Command line tool

Choose **ScratchPad ▸ Install Command Line Tool…** to link `/usr/local/bin/scratchpad` to the script inside the app.
It asks for an admin password if needed.

```bash
scratchpad notes.md          # open a file; edits save back to it
scratchpad ~/work/project    # add a folder to the sidebar as an external folder
scratchpad .                 # add the current folder
some-command | scratchpad -  # open piped text as a new scratch (type detected)
scratchpad                   # bring ScratchPad to the front
```

The tool uses the `scratchpad://` URL scheme and the bundle ID `dev.tsanthosh.scratchpad`.

---

## Keyboard shortcuts

These are the defaults. All of them can be changed in **Settings ▸ Keymap**, and overrides are stored in
`keymap.json`.

**Scratches and navigation**

| Action | Shortcut |
| --- | --- |
| New Scratch / from Clipboard | ⌘N / ⇧⌘N |
| Open File… | ⌘O |
| Add Folder to Sidebar… | ⌥⌘O |
| Save | ⌘S |
| Rename Scratch… | ⇧⌘R |
| Delete Scratch | ⌥⌘⌫ |
| Go to Scratch by Name… | ⇧⌘O |
| Go to Symbol… | ⌘[ |
| Recent Scratches… | ⌘E |
| Find Action / Dev Tools… | ⇧⌘A |
| Back / Forward | ⌥⌘← / ⌥⌘→ |
| Next / Previous Scratch | ⇧⌘] / ⇧⌘[ |
| Reveal in Scratch List | ⌘1 |
| Close Tab / Close Other Tabs | ⌘W / ⌥⌘W |
| Next / Previous Tab | ⌃⇥ / ⌃⇧⇥ |

**Editing**

| Action | Shortcut |
| --- | --- |
| Add Selection for Next Occurrence / Unselect | ⌃G / ⌃⇧G |
| Select All Occurrences | ⌃⌘G |
| Add Caret Above / Below | ⌥⌘↑ / ⌥⌘↓ |
| Carets at Ends of Selected Lines | ⌥⇧G |
| Extend / Shrink Selection | ⌥↑ / ⌥↓ |
| Select Line | ⌘L |
| Duplicate Line or Selection | ⌘D |
| Delete Line | ⌘⌫ |
| Move Line Up / Down | ⌥⇧↑ / ⌥⇧↓ |
| Start New Line | ⇧↩ |
| Line / Block Comment | ⌘/ / ⌥⌘/ |
| Jump to Matching Bracket | ⌃M |
| Reformat / Compact | ⌥⌘L / ⌥⇧⌘L |
| Collapse / Expand | ⇧⌘− / ⇧⌘= |
| Collapse All / Expand All | ⌥⇧⌘− / ⌥⇧⌘= |

**Find, run and view**

| Action | Shortcut |
| --- | --- |
| Find / Replace | ⌘F |
| Find Next / Previous | ⌘G / ⇧⌘G |
| Go to Line… | ⌃L |
| Find in Files… | ⇧⌘F |
| Run / Stop | ⌃R / ⌘F2 |
| Run All HTTP Requests | ⌥⇧⌃R |
| Copy as cURL / Paste cURL | ⌥⇧⌘C / ⌥⇧⌘I |
| Open Response in New Scratch | ⌥⇧⌘O |
| Toggle Scratch List | ⌃⌘S |
| Toggle Run Console / Clear Console | ⌘4 / ⌘K |
| Toggle Preview or Diff / Full Preview | ⇧⌘V / ⌥⇧⌘V |
| Font Size Bigger / Smaller / Reset | ⌘= / ⌘− / ⌘0 |

In the scratch list, ⌘D compares the selected scratches, ⌘C copies them, ⌘⌫ deletes them and ↩ renames.

---

## Settings and data locations

Open Settings with ⌘,. It covers the editor (font family, font size, tab size, line wrap, autocompletion), the JDK
and Java version, the Node path and packages folder, and the keymap.

| What | Where |
| --- | --- |
| Scratches | `~/Library/Application Support/ScratchPad/scratches` |
| Shared npm packages | `~/Library/Application Support/ScratchPad/packages` |
| Keymap overrides | `~/Library/Application Support/ScratchPad/keymap.json` |
| Run folders (temporary) | `~/Library/Caches/ScratchPad/runs` |
| Other preferences | macOS user defaults for `dev.tsanthosh.scratchpad` |

---

## Building from source

Prerequisites:

- macOS 13 or newer
- Swift 5.9 or newer (Xcode or the Command Line Tools; the Xcode IDE isn't needed)
- Node.js 18 or newer with npm (Node 22 is used in CI)

```bash
git clone https://github.com/tsanthosh1/scratchpad.git
cd scratchpad
scripts/build-app.sh            # release build
open build/ScratchPad.app
```

`scripts/build-app.sh [release|debug]` does the following:

1. Installs the web dependencies if `web/node_modules` is missing, then runs `npm run build`. esbuild bundles
   `web/src/editor.js` into `web/dist/editor.bundle.js`, and the static pages and viewer libraries (Mermaid,
   Swagger UI, Scalar, Kong) are copied next to it.
2. Builds the Swift package with `swift build -c <config>`.
3. Assembles `build/ScratchPad.app` from the binary, `web/dist`, `Resources/Info.plist` and the
   `Resources/bin/scratchpad` CLI script.
4. Signs the bundle ad hoc (`codesign --sign -`).

If you only change web code, `cd web && npm run build` and then copy `web/dist/*` into
`build/ScratchPad.app/Contents/Resources/web/`, or simply re-run the script.

---

## Project layout

```
.
├── Package.swift                 Swift package (one executable target, macOS 13+)
├── Sources/ScratchPad/           The AppKit app
├── web/                          The editor and preview, bundled with esbuild
│   └── src/
├── Resources/
│   ├── Info.plist                Bundle ID, version, document types, scratchpad:// URL scheme
│   └── bin/scratchpad            Command line tool (bash)
├── scripts/build-app.sh          Builds build/ScratchPad.app
├── .github/workflows/release.yml Release workflow
└── ROADMAP.md                    What's built and what's next
```

**Swift (`Sources/ScratchPad`)**

| File | Responsibility |
| --- | --- |
| `AppDelegate.swift` | App lifecycle, menus, opening files and `scratchpad://` URLs, installing the CLI |
| `MainWindowController.swift` | The main window: toolbar, tabs, editor/preview/console layout, export, most commands |
| `EditorController.swift` | Hosts the CodeMirror `WKWebView` and the Swift ↔ JavaScript bridge |
| `SidebarViewController.swift` | Scratch list, folders column, external folders, drag and drop |
| `TabBar.swift` | Chrome-style tab strip |
| `ScratchStore.swift` | Scratches, folders and external folders on disk; file watching |
| `Language.swift` | File types: names, extensions, icons, and format/run/preview capabilities |
| `Keymap.swift` | Command table, default shortcuts and `keymap.json` overrides |
| `Settings.swift`, `SettingsWindowController.swift` | Preferences, app paths, and the Settings window |
| `CommandPaletteController.swift`, `FuzzyMatcher.swift` | Find Action, Go to Scratch, Go to Symbol, Recent, and fuzzy matching |
| `FindInScratchesController.swift` | Find in Files |
| `Runner.swift`, `Toolchains.swift`, `ConsoleViewController.swift` | Running scratches, finding JDKs/Node/Python, and the console |
| `HTTPFile.swift`, `HTTPClient.swift`, `Curl.swift` | `.http` parsing and variables, sending requests, cURL conversion |
| `RichText.swift` | Rich text page, formatting bar, images, `.rtf`/`.rtfd` I/O |
| `Export.swift`, `PDFExport.swift` | OpenAPI viewers, HTML/MHTML/PDF export |
| `DevTools.swift`, `DevToolPage.swift`, `ToolPages.swift`, `ToolKit.swift`, `Transforms.swift` | Dev tool pages and text transforms |
| `MCPClient.swift`, `MCPTesterPage.swift` | MCP JSON-RPC client (stdio and SSE/HTTP) and its UI |
| `UI.swift`, `ToolbarKit.swift`, `TitleField.swift`, `Toast.swift` | Shared UI components |

**Web (`web/src`)**

| File | Responsibility |
| --- | --- |
| `index.html`, `editor.js` | Editor page and entry point: CodeMirror setup, keymap, bridge to Swift |
| `languages.js`, `completions.js` | Language modes and autocompletion |
| `format.js`, `jsonfmt.js`, `httpfmt.js` | Reformatting (Prettier, sql-formatter, xml-formatter, custom JSON and HTTP) |
| `symbols.js` | Go to Symbol outlines |
| `findPanel.js` | In-file find and replace panel |
| `preview.js` | Markdown (marked + DOMPurify + Mermaid) and HTML preview |
| `csv.js` | CSV/TSV parsing, column colours, table preview, smart paste |
| `http.js`, `response.js` | HTTP request highlighting and the response viewer |
| `diff.js`, `diffdoc.js` | Side-by-side diff view |
| `viewer.html`, `viewer.js`, `viewer.css` | OpenAPI viewers for the preview and exports |

---

## How it works

- **Native shell, web editor.** The window, sidebar, tabs, settings, rich text editor, dev tools and MCP tester are
  AppKit. The code editor, previews, diff and HTTP response viewer run in `WKWebView`s that load the bundled
  `web/` files. The page and Swift talk through a `bridge` script message handler. The page posts edits, commands
  and requests, and Swift calls back into the page with JavaScript.
- **Files are the source of truth.** `ScratchStore` lists files from the scratches folder and any external folders,
  and watches them for changes. There is no index or database to get out of sync.
- **One command table.** Every action has an entry in `Keymap.swift` with an id, title, category and default key.
  The menus, Find Action and the keymap editor are all built from that table.
- **No network needed.** All editor, preview and OpenAPI viewer libraries are bundled into the app. Only HTTP
  requests and MCP connections you start yourself reach the network.

---

## Releasing

Releases are built by GitHub Actions ([`.github/workflows/release.yml`](.github/workflows/release.yml)) when a
`v*` tag is pushed. The workflow builds the app on a macOS runner, zips it, and creates a GitHub release with the
zip attached and generated notes.

1. Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in `Resources/Info.plist` and commit.
2. Tag and push:

   ```bash
   git tag -a v0.1.1 -m "ScratchPad v0.1.1" && git push origin v0.1.1
   ```

---

## Roadmap

See [ROADMAP.md](ROADMAP.md) for the full list of what's implemented and what's planned next.
