# Daemon v1 — QA and performance report

Run on 2026-10-14 against `feat/v1`, signed Apple Development build, on an Apple M3 Pro (36 GB). Budgets in the PRD
are for a base M1 with 8 GB; those numbers are still to be measured (`daemon-w3u`).

## How this was measured

- **Real use, real app.** Every keep and recall was driven in the running app with real keystrokes (⌃⌥S, ⌃⌥Space,
  hold for voice) in TextEdit, plus files put on the clipboard and kept with ⌘V in the Recall panel. After each keep the
  stored row was checked in `library.sqlite` (kind, MIME type, size, name/path, URL, dimensions, duration, segments,
  vectors, status).
- **Resources.** A sampler recorded, about 4× a second: CPU % and RSS (`ps`), memory footprint (`footprint`, the number
  Activity Monitor shows as Memory) for both processes, and system GPU utilization (`ioreg` IOAccelerator). Each step
  was time-stamped, and the table below is computed per step window. CPU 100% = one core.
- **GPU caveat.** macOS exposes GPU use only system-wide without root. Another app kept the GPU at ~70% throughout,
  so per-operation GPU cost isn't attributable; image/audio embeds pushed it to 96–100%. For exact numbers run
  `sudo powermetrics --samplers gpu_power -i 250` during a keep.
- **Ranking.** 30+ Recall queries ran through the real search against a copy of the library (`QALibraryTests`).

## Functional results

| # | Case | Result | Stored correctly? |
|---|---|---|---|
| 1 | Select text in TextEdit, ⌃⌥S | ✅ | `text`, `text/plain`, bytes, app + window title |
| 2 | ⌃⌥Space, type, ↵ pastes into the previous app | ✅ after fix | clipboard restored afterwards |
| 3 | PDF | ✅ | `pdf`, `application/pdf`, original path, 1 segment per page with text |
| 4 | PNG (3056×2056) | ✅ | `image`, `image/png`, width/height, OCR text (1.9 KB), thumbnail |
| 5 | Same PNG kept twice | ✅ | two items, **one stored file** (same SHA-256) |
| 6 | Word .docx | ✅ | `file`, docx MIME, text extracted |
| 7 | Markdown | ✅ | `file`, `text/markdown`, text indexed |
| 8 | Unicode/emoji text file (京都 ✈️🍣) | ✅ | text intact |
| 9 | 62 s audio | ✅ | `audio`, 62,220 ms, split into overlapping windows with vectors |
| 10 | 8 s video | ✅ after fix | `video`, 8,000 ms, frame window; dimensions now stored |
| 11 | Selection that is only a URL | ✅ after fix | `link`, `https://example.com/pricing` |
| 12 | Whitespace-only selection | ✅ | treated as "nothing selected" → region capture (PRD rule 5) |
| 13 | CJK + emoji selection | ✅ | stored intact |
| 14 | 10,000-word selection (83,787 chars) | ✅ | 31 overlapping chunks, all embedded, < 12 s |
| 15 | Hold ⌃⌥S 3 s (voice) | ✅ | `voice`, `audio/x-m4a`, 2.5 s (hold minus 0.4 s threshold) |
| 16 | Idle unload 2 min after media | ✅ | model process 2.43 GB → 162 MB |
| 17 | zip / 600 MB .mov via clipboard | ⚠️ not testable here | this Mac's DLP software strips those file URLs from the clipboard; Library unit tests cover zip and the 500 MB reference rule |

### Bugs found and fixed in this pass

1. **Recall list showed rows in the wrong order** (time order while the preview showed the top hit; ↵ pasted a
   different row than the highlighted one). Rows were identified by position; now by item.
2. **Search returned everything.** Meaning search always returns the nearest items; added a per-query cutoff
   (keep hits within 0.10 of the best and above mean + 1 sd). Keyword search now requires all words first.
3. **Permission prompts in a loop.** Ad-hoc signing pinned grants to one build; Screen Recording was requested on
   every keep; Accessibility on every launch; the trial date lived in the Keychain (prompt on launch). Now: signed with
   the Apple Development certificate, each permission requested once, trial in a plain file.
4. **Settings crashed** (KeyboardShortcuts resources missing from the app bundle). Fixed in `bundle.sh`.
5. **Dropping files on the menu bar icon did nothing.** Replaced delegate forwarding with a dedicated drop view.
6. Images pasted as file paths into text fields; voice notes titled with the window they were recorded over;
   "Paste into Daemon"; text items without MIME/size; ⌘V keeps without a source; video without dimensions;
   release builds missing Apple Events and microphone entitlements; UI tests flashing real toasts on screen.

### Still to verify by hand (need a person or a permission prompt)

- Settings window opens (crash fix) and the retention control works there.
- Drop a file on the menu bar icon (new drop view).
- Region screenshot and browser link keeps after granting Screen Recording and Automation once.
  Chrome page URLs were empty earlier because Automation was tied to an old build; now reset.
- Finder selection + ⌃⌥S (first use asks Automation for Finder once).
- Excluded apps (Passwords, Keychain Access), Quick Look, delete + undo, onboarding "Try it" step.

## Resources per operation

Memory is footprint. "Model" is the `DaemonEmbedder` process.

| Operation | App CPU avg / peak | App memory peak | Model CPU peak | Model memory | Wall time |
|---|---|---|---|---|---|
| Idle (no debug tooling) | 0.0% | 21 MB | 0.3% | 160 MB | — |
| Cold launch | 4% / 42% | 21 MB | 80% | 235 MB → 162 MB | ~2–3 s |
| Keep text | spikes 30–45% | 32–58 MB | < 4% | +0–100 MB | < 1 s to ready |
| Keep PDF (1 page) | 9% / 71% | 58 MB | 4% | 149 → 284 MB | ~1 s |
| Keep image, first media | 21% / **497%** | **218 MB** | 46% | 200 MB → **1.14 GB** | ~2 s |
| Keep 62 s audio | 16% / 69% | 116 MB | 17% | 1.06 → **2.43 GB** | ~2 s |
| Keep 8 s video | 16% / 61% | 75 MB | 5% | (already loaded) | ~1 s |
| Keep 10,000 words | 3% / 28% | 60 MB | 10% | +80 MB | ~10 s |
| Recall query | small | 52 MB | 2% | small | **10–14 ms** end to end |
| Filter-only query | — | — | — | — | < 1.3 ms |
| Idle unload (2 min) | — | — | — | 2.43 GB → 162 MB | — |

### Audio window length (model memory for one segment, fresh process)

| Window | Model memory | Time per segment (warm) | Time per hour of audio |
|---|---|---|---|
| 15 s | 1.24 GB | 0.17 s | ~41 s |
| **30 s (now used)** | **1.63 GB** | 0.35 s | ~43 s |
| 45 s | 2.02 GB | 0.55 s | ~44 s |
| 60 s (PRD) | 2.41 GB | 0.73 s | ~44 s |

Memory grows ~26 MB per second of audio in one input while total time is flat, so windows moved to 30 s (3 s overlap).

### Storage

`~/Library/Application Support/Daemon/Library/`: `library.sqlite` (items, segments, vectors at 768 × Float16 ≈ 1.5 KB
each, FTS5 keyword index), `files/<sha256>.<ext>` (deduplicated copies; > 500 MB kept by reference), `thumbnails/`.
23 items including images, audio and video used 7.8 MB. Retention removes items, files, thumbnails, vectors and index
rows after 7, 30 or 90 days (default 30).

## Where to optimize next (ranked by impact)

1. **Media model memory (~1 GB the moment an image or audio is kept).** The projector file holds both the vision and
   audio encoders; llama.cpp loads both. Splitting it into vision-only and audio-only files (or loading one encoder)
   should roughly halve the first-media jump. Already bounded in time by the 2-minute idle restart.
2. **Text compute buffers.** Model memory grows with the longest text seen (~400 tokens → 630 MB, ~1,200 → 1.4 GB,
   2,048 → 2.3 GB) and stays until idle restart. Text chunks of ~512 tokens (now ~700–900) would cap the transient at
   ~0.7 GB at the cost of ~1.5× more vectors.
3. **Text recognition on big images uses ~5 cores for ~1–2 s in the app.** Run Vision OCR on a 2,560 px copy instead
   of full resolution (screenshots at 3056×2056 lose nothing readable), or `.fast` above ~8 MP.
4. **Toast animation CPU.** Keeping/Kept with shimmer and flight costs ~20–30% of a core for ~3 s per keep. Capping the
   `TimelineView` to 30 fps and stopping the shimmer as soon as Kept arrives would roughly halve it.
5. **First query after launch takes 0.6–0.7 s** (model warm-up). Embed a dummy query at launch instead of only `stats`.
6. **Idle model process uses 0.3% CPU.** Small but non-zero for a process that should be blocked on stdin; worth a
   look with Instruments (likely Metal/residency housekeeping).
7. **Measure on a base M1 8 GB** before trusting any of these against the PRD budgets.
