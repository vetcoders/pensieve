# Pensieve

Native macOS markdown writing app. File-first. Source-first. 
Not Notion. Not Obsidian. Not an unwieldy monolith. 
A beautiful, fast, local markdown *pisak* — crafted for Maciej and Monika, and anyone who appreciates the pure joy of typing.

*𝚅𝚒𝚋𝚎𝚌𝚛𝚊𝚏𝚝𝚎𝚍. with AI Agents by VetCoders (c)2024-2026 LibraxisAI*

## The Vibe

- **`.md` is the source of truth. Always.** No proprietary databases trapping your thoughts.
- **SQLite is an index, not a prison.** We use GRDB.swift to make search instant, but your files remain just files.
- **The feeling of writing > feature count.** It’s about the flow.
- **Round-trip safety.** We never destroy your manual formatting.
- **AI is a silent assistant**, not the center of the product.

## Key Features

- **Line Numbers & Syntax Highlighting:** Perfect for the veterinarian/engineer who mixes text with `json`, `swift`, `python`, and `rust`.
- **WYSIWYG-style Preview & Two-Way Links:** For structural note-taking and seamless reading.
- **Split Modes:** `SOURCE` (Cmd+1), `SPLIT` (Cmd+2), `PREVIEW` (Cmd+3), and upcoming `FOCUS` (Cmd+4).
- **Fast Native Core:** Built on Swift 5.9+, SwiftUI, and AppKit's `NSTextView` with TextKit 2.

## Background & Heritage

Pensieve is the spiritual successor to an older Objective-C markdown editor (by Satoshi Iwaki) that served as our daily driver for over a year. We kept the essence (and the CSS) but rebuilt the engine entirely in modern Swift to drop legacy debt and gain native Apple Silicon performance.

---
Created by Maciej (operator), Monika (vision), and Klaudiusz (synthesis).