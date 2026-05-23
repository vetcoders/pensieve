---
title: "Pensieve — design doc (MVP 0.1)"
date: 2026-05-22
status: approved-for-implementation
authors: maciej (operator) + monika (vision) + klaudiusz (synthesis)
format: vc-scaffold
target_skill: vc-implement (alias vc-justdo)
---

# Pensieve — design doc

Native macOS markdown writing app. File-first. Source-first.
Not Notion. Not Obsidian. Not MWeb-grade kombajn.
A beautiful, fast, local markdown pisak — for Maciej and Monika.

## 1. Założenia produktowe

### Filozofia

- `.md` jest źródłem prawdy. Zawsze.
- SQLite to indeks, nie więzienie danych.
- Feeling pisania > liczba features.
- Round-trip safety — nigdy nie niszczymy formatowania użytkownika.
- AI jest cichym asystentem, nie centrum produktu (Wave 2+).

### Użytkownicy

- **Maciej:** weterynarz / engineer, daily driver istniejący ObjC markdown editora od roku. Pisze `.md` z code blockami (`json`, `swift`, `python`, `rust`), wkleja JSON-y, debug logs. Wymaga **line numbers + code block syntax highlighting**.
- **Monika:** product owner Vista, prowadzi notatki strukturalne. Wymaga **floating toolbar na selection + WYSIWYG-style preview + sticky fullscreen + two-way links**.

Wspólne: pisarski feel iA Writer + biblioteka MWeb-style, ale bez kombajnu.

## 2. Stack technologiczny

| Warstwa | Wybór | Uzasadnienie |
|---|---|---|
| Język | Swift 5.9+ | Native macOS, brak Obj-C legacy debt |
| UI shell | SwiftUI | Window mgmt, sidebar, toolbar — declarative |
| Editor engine | AppKit NSTextView + TextKit 2 | Best feel, viewport layout, fragment-based |
| Markdown parser | `swift-markdown` (Apple) | Official cmark-gfm wrapper, AST emitting |
| Preview render | WKWebView | Custom CSS themes, easy export PDF/HTML |
| Storage | `.md` files + SQLite (GRDB.swift) | File-first; SQLite as index/FTS |
| File watcher | FSEvents | Native, low overhead |
| Minimum macOS | 13.0 (Ventura) | Required for TextKit 2 |
| Build | Swift Package Manager | Modern, opens natively in Xcode |

### Dependencies

```swift
.package(url: "https://github.com/apple/swift-markdown", from: "0.4.0"),
.package(url: "https://github.com/groue/GRDB.swift", from: "6.0.0"),
```

Nic więcej. No CocoaPods, no Carthage, no GCDWebServer, no AppAuth.

## 3. Architektura wysokopoziomowa

```
Pensieve/
├── Package.swift
├── Sources/Pensieve/
│   ├── App/
│   │   ├── PensieveApp.swift           — entry, scene management
│   │   ├── ContentView.swift          — 3-pane layout (sidebar | editor | preview)
│   │   ├── Commands.swift             — menu commands (File/Edit/View/Mode)
│   │   └── AppState.swift             — ObservableObject root
│   ├── Editor/
│   │   ├── EditorView.swift           — NSViewRepresentable wrapper
│   │   ├── MarkdownTextView.swift     — NSTextView subclass
│   │   ├── MarkdownTextStorage.swift  — NSTextContentStorage subclass
│   │   ├── SyntaxHighlighter.swift    — markdown tokenizer + colors
│   │   ├── CodeBlockHighlighter.swift — language detection per ``` block
│   │   ├── LineNumberGutter.swift     — NSRulerView subclass
│   │   ├── EditorModeController.swift — source/split/preview/focus modes
│   │   └── FontSizeController.swift   — Cmd+/- zoom
│   ├── Preview/
│   │   ├── PreviewView.swift          — NSViewRepresentable wrapper
│   │   ├── PreviewWebView.swift       — WKWebView subclass
│   │   ├── MarkdownRenderer.swift     — swift-markdown → HTML
│   │   └── ThemeManager.swift         — CSS theme loading
│   ├── Storage/
│   │   ├── DocumentModel.swift        — note metadata + content
│   │   ├── FolderManager.swift        — open folder + security-scoped bookmarks
│   │   ├── FileWatcher.swift          — FSEvents wrapper
│   │   ├── DocumentStore.swift        — load/save/autosave
│   │   └── IndexDatabase.swift        — SQLite/GRDB (stub w MVP 0.1)
│   ├── Sidebar/
│   │   └── SidebarView.swift          — file tree, search, deleted
│   └── Resources/
│       ├── markdown.css               — z legacy/MarkdownEditor/Resources
│       ├── gfm.css                    — z legacy
│       └── sample.md                  — z legacy (welcome file)
└── Tests/PensieveTests/
    └── (minimal smoke tests dla MVP 0.1)
```

## 4. Tryby edytora

```
Cmd+1  SOURCE       — czysty markdown, line numbers, syntax hl, code block coloring
Cmd+2  SPLIT        — source | rendered preview (synced scroll)
Cmd+3  PREVIEW      — sam rendered HTML
Cmd+4  FOCUS        — active sentence/paragraph highlighted (Wave 2)

Cmd+/  TOGGLE       — Rich Markdown ON/OFF per pane (Wave 2)
Cmd+=  Font bigger
Cmd+-  Font smaller
Cmd+0  Font reset
```

## 5. MVP 0.1 — Minimum Viable Demonstrator (ta sesja)

### Cel
App się otwiera, otwiera folder, listuje `.md`, edytujesz w NSTextView z TextKit 2, widzisz preview obok, Cmd+S zapisuje. Pisarski feel pow