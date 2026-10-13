import DaemonCore
import SwiftUI
import UniformTypeIdentifiers

struct RecallView: View {
    @ObservedObject var model: RecallViewModel
    @FocusState private var queryFocused: Bool
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.divider)
            if model.isRecent {
                recentGrid
            } else {
                chips
                Divider().overlay(Theme.divider)
                HStack(spacing: 0) {
                    resultList.frame(width: 384)
                    Divider().overlay(Theme.divider)
                    preview.frame(maxWidth: .infinity)
                }
            }
            Divider().overlay(Theme.divider)
            footer
        }
        .frame(width: Theme.Size.recallPanel.width, height: Theme.Size.recallPanel.height)
        .background(.panelFill)
        .overlay(alignment: .bottom) { banner.padding(.bottom, 50) }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Theme.Radius.panel)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(Theme.border, lineWidth: 1))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.searchSimilar(to: url) }
            }
            return true
        }
        .onAppear { queryFocused = true }
        .onChange(of: model.focusRequest) { queryFocused = true }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            Mark(size: 18, color: Theme.textSecondary)
            if let similar = model.similarTo {
                Text("Like \(similar)")
                    .font(Theme.Font.caption)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.well, in: Capsule())
                    .foregroundStyle(Theme.textPrimary)
            }
            TextField("", text: $model.query, prompt: Text("Recall anything…").foregroundStyle(Theme.textTertiary))
                .textFieldStyle(.plain)
                .font(Theme.Font.query)
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.accent)
                .focused($queryFocused)
            if model.isRecent {
                Text(model.countLine).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            } else {
                KeyHint(key: "⇥", label: "filters")
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 58)
    }

    // MARK: - Chips

    private var chips: some View {
        HStack(spacing: 4) {
            ForEach(model.chips, id: \.filter) { chip in
                let selected = chip.filter == model.filter
                HStack(spacing: 5) {
                    Text(chip.filter.rawValue).font(Theme.Font.chip).foregroundStyle(Theme.textPrimary)
                    Text("\(chip.count)").font(Theme.Font.small).foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 12).frame(height: 26)
                .background(selected ? Theme.panelTop : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Theme.kbdBorder : .clear, lineWidth: 1))
                .contentShape(Capsule())
                .onTapGesture { model.filter = chip.filter }
                .accessibilityAddTraits(.isButton)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    // MARK: - Results

    private var resultList: some View {
        let hits = model.visibleHits
        return Group {
            if hits.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(hits.enumerated()), id: \.element.id) { i, hit in
                                ResultRow(hit: hit, thumbnail: model.dataSource.thumbnailURL(for: hit.item),
                                          selected: i == model.selection)
                                    .onTapGesture(count: 2) { model.select(hit); model.paste() }
                                    .onTapGesture { model.select(hit) }
                                    .onDrag { dragProvider(hit) }
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: model.selection) { model.selectedHit.map { proxy.scrollTo($0.id) } }
                }
            }
        }
    }

    private var emptyState: some View {
        Text(model.emptyMessage)
            .font(Theme.Font.body)
            .foregroundStyle(Theme.textSecondary)
            .multilineTextAlignment(.center)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var preview: some View {
        if let hit = model.selectedHit {
            VStack(alignment: .leading, spacing: 0) {
                if hit.item.kind == .text, let text = hit.item.text {
                    Text(text)
                        .font(Theme.Font.body).foregroundStyle(Theme.textPrimary)
                        .lineLimit(7)
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
                        .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                } else {
                    Thumbnail(item: hit.item, url: model.dataSource.thumbnailURL(for: hit.item), radius: Theme.Radius.card)
                        .frame(height: 140)
                }
                Text(hit.displayTitle)
                    .font(Theme.Font.previewTitle).foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .padding(.top, 14)
                Text(previewSubtitle(hit))
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    .padding(.top, 4)
                if let note = hit.item.note, !note.isEmpty {
                    Text("“\(note)”")
                        .font(Theme.Font.body.italic()).foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.border, lineWidth: 1))
                        .padding(.top, 10)
                }
                Spacer(minLength: 8)
                actionLine("Paste into \(model.previousAppName ?? "the app you were in")", key: "↵", primary: true)
                if let app = model.openAppName(for: hit) {
                    actionLine("Open in \(app)", key: "⌘↵", primary: false).padding(.top, 8)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        } else {
            Color.clear
        }
    }

    private func previewSubtitle(_ hit: SearchHit) -> String {
        var when = relativeDate(hit.item.createdAt)
        if ["Just now", "Today", "Yesterday"].contains(when) { when = when.lowercased() }
        var parts = [hit.item.sourceLabel, "kept \(when)"]
        if let badge = hit.timeBadge { parts.append(badge) }
        return parts.joined(separator: " · ")
    }

    private func actionLine(_ title: String, key: String, primary: Bool) -> some View {
        HStack {
            Text(title).font(Theme.Font.body).foregroundStyle(primary ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
            Spacer()
            Kbd(label: key, font: Theme.Font.small)
        }
    }

    // MARK: - Recent

    private var recentGrid: some View {
        let hits = model.visibleHits
        return VStack(alignment: .leading, spacing: 0) {
            if hits.isEmpty {
                emptyState
            } else {
                HStack {
                    Text("RECENT").font(Theme.Font.label).tracking(1).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    KeyHint(key: "⌘R", label: model.showingAll ? "Show recent" : "Show all")
                }
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                                                 count: RecallViewModel.gridColumns), spacing: 14) {
                            ForEach(Array(hits.enumerated()), id: \.element.id) { i, hit in
                                RecentCard(hit: hit, thumbnail: model.dataSource.thumbnailURL(for: hit.item),
                                           selected: model.browsing && i == model.selection)
                                    .onTapGesture(count: 2) { model.select(hit); model.paste() }
                                    .onTapGesture { model.select(hit) }
                                    .onDrag { dragProvider(hit) }
                            }
                        }
                        .padding(.horizontal, 20).padding(.bottom, 14)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: model.selection) { model.selectedHit.map { proxy.scrollTo($0.id) } }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Footer and banner

    private var footer: some View {
        HStack(spacing: 18) {
            if model.isRecent { FooterHint("↑↓", "Browse") }
            FooterHint("↵", "Paste")
            if !model.isRecent { FooterHint("⌘C", "Copy") }
            FooterHint("Space", "Preview")
            if !model.isRecent { FooterHint("⌘↵", "Open") }
            Spacer()
            FooterHint("Esc", "Close")
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    @ViewBuilder private var banner: some View {
        if let hit = model.pendingDelete {
            HStack(spacing: 10) {
                Text("Deleted \(hit.displayTitle)").lineLimit(1)
                Button("Undo") { model.undoDelete() }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                Kbd(label: "⌘Z", font: Theme.Font.small)
            }
            .bannerStyle()
        } else if let notice = model.notice {
            Text(notice).bannerStyle()
        }
    }

    private func dragProvider(_ hit: SearchHit) -> NSItemProvider {
        if let url = model.dataSource.fileURL(for: hit.item), let provider = NSItemProvider(contentsOf: url) {
            return provider
        }
        if let link = hit.item.url, let url = URL(string: link) { return NSItemProvider(object: url as NSURL) }
        return NSItemProvider(object: (hit.item.text ?? hit.displayTitle) as NSString)
    }
}

private extension View {
    func bannerStyle() -> some View {
        font(Theme.Font.caption)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14).frame(height: 30)
            .background(Theme.panelTop, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}

private struct FooterHint: View {
    let key: String
    let label: String
    init(_ key: String, _ label: String) { self.key = key; self.label = label }
    var body: some View {
        HStack(spacing: 6) {
            Kbd(label: key, font: Theme.Font.footerKey)
            Text(label).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
        }
    }
}

struct ResultRow: View {
    let hit: SearchHit
    let thumbnail: URL?
    let selected: Bool

    var body: some View {
        HStack(spacing: 14) {
            Thumbnail(item: hit.item, url: thumbnail).frame(width: 52, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.displayTitle).font(Theme.Font.title).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text("\(hit.item.sourceLabel) · \(relativeDate(hit.item.createdAt))")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let badge = hit.timeBadge {
                Text(badge)
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 7).frame(height: 20)
                    .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.kbd))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.kbd).strokeBorder(Theme.kbdBorder, lineWidth: 1))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
        .background(selected ? Theme.selectedRow : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .contentShape(Rectangle())
    }
}

struct RecentCard: View {
    let hit: SearchHit
    let thumbnail: URL?
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Thumbnail(item: hit.item, url: thumbnail, radius: Theme.Radius.thumb)
                .frame(height: 104)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.thumb)
                    .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2))
            Text(hit.displayTitle).font(Theme.Font.title).foregroundStyle(Theme.textPrimary).lineLimit(1)
                .padding(.top, 9)
            HStack {
                Text(hit.item.sourceLabel)
                Spacer()
                Text(trailing)
            }
            .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            .padding(.top, 2)
        }
        .contentShape(Rectangle())
    }

    private var trailing: String {
        let when = relativeDate(hit.item.createdAt)
        if hit.item.kind == .voice, let ms = hit.item.durationMs { return "\(timecode(ms: ms)) · \(when)" }
        return when
    }
}
