import AppKit
import SwiftUI

/// ⌥空格, anywhere on the desktop: a Spotlight-like bar over the paper library, a quick answer, the web, and 随手记.
/// Row order follows the server's router verdict (paper2brain/router.py) only in the plain ways below; /api/bot/route
/// logs what was typed and what was picked, to judge the router by.
struct FoundPaper: Decodable, Identifiable, Equatable {
    var id: String
    var title: String
    var shortName: String?
    var tldr: String?
    enum CodingKeys: String, CodingKey { case id, title, tldr, shortName = "short_name" }
}

struct RouteVerdict: Decodable, Equatable {
    var intent: String?
    var layer: String
}

struct Found: Decodable {
    var papers: [FoundPaper]
    var route: RouteVerdict
}

/// The web bar's "AI 推荐": a sentence, the library's papers that fit (even in other words), and what the web search found.
struct Overview: Decodable {
    var answer: String
    var papers: [FoundPaper]
    var web: [WebHit]
}

struct WebHit: Decodable {
    var title: String
    var url: String
    var why: String?
    var pid: String?
    var published: String?
}

/// The button at a row's right (⌘↵): the web bar's 加入论文库.
struct RowAction {
    let label: String
    let id: String
    let run: @MainActor () -> Void
}

struct SearchRow: Identifiable {
    let id: String  // the key /api/bot/route logs (m:*)
    var key: String { id + "|" + title }  // what keeps a row selected while others arrive above it
    let icon: String
    let title: String
    var subtitle: String?
    var stays = false  // the row's own result shows in the bar: do not close it
    var group = ""
    var action: RowAction?
    let run: @MainActor () -> Void
}

struct Source: Decodable, Equatable {
    var title: String
    var url: String
}

enum Answer: Equatable {
    case loading, done(String, [Source]), failed(String)
}

/// A finished question and answer of the conversation in the bar.
struct Turn: Equatable {
    var q: String
    var a: String
    var sources: [Source] = []
}

/// What the bar was showing when it closed, offered again for ten minutes (the 最近 group).
struct Session {
    var turns: [Turn]
    var at = Date()
}

@MainActor
final class SearchModel: ObservableObject {
    static let engine = UserDefaults.standard.string(forKey: "searchURL") ?? "https://cn.bing.com/search?q="
    private static let component = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))  // JS encodeURIComponent

    @Published var query = "" { didSet { if query != oldValue { changed() } } }
    @Published var found: Found?
    @Published var answer: Answer?  // to `asked`
    @Published var asked = ""  // the question being answered; non-empty = the bar is a conversation
    @Published var turns: [Turn] = []  // the finished ones before it
    @Published var overview: Overview?
    @Published var overviewLoading = false
    private var foundFor = "", overviewFor = ""
    private var pendingOverview: Task<Void, Never>?
    @Published var error: String?
    @Published var selected = 0
    var onClose: () -> Void = {}
    private let jot: Jot
    private var pending: Task<Void, Never>?
    private let resumable: Session?
    var lastKept: Session?

    init(jot: Jot, resume: Session? = nil) {
        self.jot = jot
        resumable = resume.flatMap { Date().timeIntervalSince($0.at) < 600 && !$0.turns.isEmpty ? $0 : nil }
    }

    var inChat: Bool { !asked.isEmpty }

    /// The conversation as it stands, for the controller to keep when the bar closes.
    var session: Session? {
        var all = turns
        if case let .done(a, sources) = answer { all.append(Turn(q: asked, a: a, sources: sources)) }
        return all.isEmpty ? nil : Session(turns: all)
    }

    func newChat() {
        turns = []; asked = ""; answer = nil; query = ""
    }

    private func resume(_ s: Session) {
        guard let last = s.turns.last else { return }
        turns = Array(s.turns.dropLast()); asked = last.q; answer = .done(last.a, last.sources); query = ""
    }

    /// Typing a link or a prefixed jot while in a conversation is something new, not a follow-up.
    private var leavesChat: Bool { isLink || text.range(of: #"^\s*(?:待办|想法|记住)\s*[:：]|^\s*(?:交给|让)\s*mac"#, options: [.regularExpression, .caseInsensitive]) != nil }

    var text: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The verdict is for what is typed now, not for the last letters before it.
    var live: Found? { foundFor == text ? found : nil }
    var isLink: Bool { text.range(of: #"^https?://\S+$"#, options: .regularExpression) != nil }

    /// The web bar's 前往 (main.js NAV): label, hash route.
    private static let nav = [("论文趋势", "trending"), ("论文", "papers"), ("讨论", "discuss"), ("研究", "research"), ("随手记", "bot/notes"), ("p2bot · 今天", "bot"),
                              ("p2bot · Mac 任务", "bot/tasks"), ("p2bot · 学术", "bot/academic"), ("未归类", "unsorted"), ("最近删除", "trash")]
    private static let homeNav: Set<String> = ["trending", "papers", "discuss", "research", "bot/notes"]
    private static var history: [String] { UserDefaults.standard.stringArray(forKey: "searchHistory") ?? [] }

    private func remember(_ q: String) {
        UserDefaults.standard.set(Array(([q] + Self.history.filter { $0 != q }).prefix(8)), forKey: "searchHistory")
    }

    private func navRows(_ items: [(String, String)]) -> [SearchRow] {
        items.map { label, path in SearchRow(id: "m:nav", icon: "arrow.right", title: label, group: "前往") { [self] in open("/#/" + path) } }
    }

    /// Nothing typed: what was asked lately, what is next, and where to go (the web bar's 开始 and 前往).
    private var emptyRows: [SearchRow] {
        let again = resumable.map { s in
            SearchRow(id: "m:resume", icon: "bubble.left.and.bubble.right", title: "继续对话：" + (s.turns.first?.q ?? ""), subtitle: "\(s.turns.count) 轮", stays: true, group: "最近") { [self] in resume(s) }
        }
        let recent = Self.history.prefix(4).map { q in
            SearchRow(id: "m:recent", icon: "clock", title: q, stays: true, group: "最近") { [self] in query = q }
        }
        let todos = (jot.status?.next ?? []).prefix(3).map { item in
            SearchRow(id: "m:todo", icon: "circle", title: item.title, subtitle: item.reason, group: "接下来",
                      action: RowAction(label: "完成", id: "m:todo-done") { [self] in jot.complete(item.id) }) { [self] in open("/#/bot/notes") }
        }
        return Array(again.map { [$0] } ?? []) + recent + todos + navRows(Self.nav.filter { Self.homeNav.contains($0.1) }) + [palette(group: "前往", title: "在网页万能栏打开", subtitle: "找论文、交给 Mac、收下文件…")]
    }

    /// Everything the web bar does that this one does not (找论文, 讨论, 交给 Mac, 收下, 开始研究, 速览): it opens with the text in it.
    private func palette(group: String, title: String, subtitle: String? = nil) -> SearchRow {
        SearchRow(id: "m:palette", icon: "macwindow", title: title, subtitle: subtitle, group: group) { [self] in open("/?pal=" + Self.escape(text)) }
    }

    var rows: [SearchRow] {
        guard !inChat else { return [] }
        guard !text.isEmpty else { return emptyRows }
        let intent = live?.route.intent
        let use = "用这段话"
        let jot = SearchRow(id: "m:jot", icon: "leaf", title: isLink ? "收下这个链接" : "记进随手记", group: use) { [self] in
            Task { do { try await self.jot.save(text: text, source: "typed"); self.jot.onSaved?() } catch { self.jot.onWorried?("操作未完成") } }
        }
        let more = palette(group: use, title: "在网页万能栏继续", subtitle: "找论文 · 讨论 · 交给 Mac · 收下 · 开始研究")
        if isLink, let url = URL(string: text) {
            return [SearchRow(id: "m:link", icon: "link", title: "打开链接", subtitle: text, group: use) { NSWorkspace.shared.open(url) }, jot, more]
        }
        let papers = (live?.papers ?? []).prefix(5).map { p in
            SearchRow(id: "m:paper", icon: "doc.text", title: p.title, subtitle: [p.shortName, p.tldr].compactMap { $0 }.joined(separator: " · "), group: "库里") { [self] in
                open("/#/read/" + Self.escape(p.id))
            }
        }
        let ask = SearchRow(id: "m:ask", icon: "sparkles", title: "问：\(text)", subtitle: "联网回答", stays: true, group: "回答") { [self] in self.ask() }
        let askHere = SearchRow(id: ask.id, icon: ask.icon, title: ask.title, subtitle: ask.subtitle, stays: true, group: use, run: ask.run)
        let search = SearchRow(id: "m:search", icon: "books.vertical", title: "在论文库里搜索「\(text)」", group: use) { [self] in open("/#/search/" + Self.escape(text)) }
        let web = SearchRow(id: "m:web", icon: "globe", title: "搜索网页：\(text)", group: use) {
            if let url = URL(string: Self.engine + Self.escape(self.text)) { NSWorkspace.shared.open(url) }
        }
        let go = navRows(Self.nav.filter { $0.0.lowercased().contains(text.lowercased()) })
        let ai = aiRows
        if intent == "jot" { return [jot, askHere, search, web, more] + go }
        if !papers.isEmpty, intent == "library" || intent == "paper" { return ai + papers + [search, askHere, web, jot, more] + go }
        return ai + [ask] + papers + [search, web, jot, more] + go
    }

    private var aiRows: [SearchRow] {
        guard overviewFor == text, let o = overview else { return [] }
        let group = "AI 推荐"
        let lib = o.papers.map { p in
            SearchRow(id: "m:aipaper", icon: "sparkles", title: p.title, subtitle: "库里 · " + [p.shortName, p.tldr].compactMap { $0 }.joined(separator: " · "), group: group) { [self] in
                open("/#/read/" + Self.escape(p.id))
            }
        }
        let web = o.web.compactMap { w -> SearchRow? in
            guard let url = URL(string: w.url) else { return nil }
            let add = w.pid.map { pid in
                RowAction(label: "加入论文库", id: "m:aiadd") { [self] in
                    Task {
                        do { _ = try await Server.shared.post("/api/bot/add-paper", ["pid": pid]); jot.onSaved?(); open("/#/read/" + Self.escape(pid)) } catch { jot.onWorried?("操作未完成") }
                    }
                }
            }
            return SearchRow(id: "m:aiweb", icon: "arrow.up.right.square", title: w.title,
                             subtitle: "网上 · " + [w.published.map { String($0.prefix(7)) }, w.why].compactMap { $0 }.joined(separator: " · "),
                             group: group, action: add) { NSWorkspace.shared.open(url) }
        }
        return lib + web
    }

    /// The first question of a conversation, from the 问 row. Follow-ups come from ask(_:) with the input's text.
    private func ask() { ask(text) }

    private func ask(_ q: String) {
        if case let .done(a, sources) = answer { turns.append(Turn(q: asked, a: a, sources: sources)) }
        let first = turns.isEmpty
        asked = q; query = ""
        if first, overviewFor == q, let said = overview?.answer, !said.isEmpty { answer = .done(said, []); return }  // the overview already has one
        answer = .loading
        let history = turns.suffix(6).map { ["q": $0.q, "a": $0.a] }
        Task {
            do {
                let got = try JSONDecoder().decode(Reply.self, from: try await Server.shared.post("/api/bot/ask", ["q": q, "history": history]))
                if asked == q { answer = .done(got.answer, got.sources) }
            } catch {
                if asked == q { answer = .failed(error.localizedDescription) }
            }
        }
    }

    private struct Reply: Decodable { var answer: String; var sources: [Source] }

    func move(_ by: Int) {
        let n = rows.count
        if n > 0 { selected = (selected + by + n) % n }
    }

    /// secondary (⌘↵, or the button at the row's right): the row's own action, if it has one.
    func submit(secondary: Bool = false) {
        if inChat {
            if text.isEmpty {  // nothing typed: Return takes the answer along
                if case let .done(a, _) = answer { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(a, forType: .string); onClose() }
            } else if answer != .loading {
                let q = text
                Task { _ = try? await Server.shared.post("/api/bot/route", ["q": q, "picked": "m:follow", "src": "mac"]) }
                ask(q)
            }
            return
        }
        let rows = rows
        guard rows.indices.contains(selected) else { return }
        let row = rows[selected], q = text
        if secondary && row.action == nil { return }
        if !q.isEmpty {
            let picked = secondary ? row.action?.id ?? row.id : row.id
            Task { _ = try? await Server.shared.post("/api/bot/route", ["q": q, "picked": picked, "src": "mac"]) }
            if row.id != "m:recent" { remember(q) }
        }
        if secondary { row.action?.run() } else { row.run() }
        if secondary || !row.stays { onClose() }
    }

    private func open(_ path: String) {
        if let base = Server.shared.base, let url = URL(string: base.absoluteString + path) { NSWorkspace.shared.open(url) }
    }

    private static func escape(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: component) ?? s }

    /// Like the web bar: once typing pauses, a model reads the library and searches the web. Only when the router thinks
    /// it may be about papers (or cannot tell): a plain question or a to-do is not worth the calls.
    private func scheduleOverview(_ q: String) {
        guard q.count >= 2 else { return }
        pendingOverview = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, q == text else { return }
            if let live, let intent = live.route.intent, !["library", "paper", "find"].contains(intent) { return }
            overviewLoading = true
            let got = try? await Server.shared.get("/api/bot/overview?q=" + Self.escape(q), as: Overview.self)
            guard !Task.isCancelled, q == text else { return }
            overviewLoading = false
            guard let got, !(got.answer.isEmpty && got.papers.isEmpty && got.web.isEmpty) else { return }
            let held = rows.indices.contains(selected) ? rows[selected].key : nil  // the row under the cursor stays under it
            overview = got; overviewFor = q
            selected = held.flatMap { key in rows.firstIndex { $0.key == key } } ?? 0
        }
    }

    /// Library hits as it is typed (the web bar's 160ms), without a model; a late answer for an old query is dropped.
    private func changed() {
        if inChat {
            guard leavesChat else { return }
            if let kept = session { lastKept = kept }
            turns = []; asked = ""; answer = nil
        }
        selected = 0
        overview = nil; overviewLoading = false
        pending?.cancel(); pendingOverview?.cancel()
        let q = text
        guard !q.isEmpty, !isLink else { found = nil; error = nil; return }
        scheduleOverview(q)
        pending = Task {
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled else { return }
            do {
                let got = try await Server.shared.get("/api/bot/find?q=" + Self.escape(q), as: Found.self)
                guard !Task.isCancelled, q == text else { return }
                found = got; foundFor = q; error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
}

struct SearchView: View {
    @ObservedObject var model: SearchModel
    var resize: () -> Void
    static let debug = UserDefaults.standard.object(forKey: "routeDebug") as? Bool ?? true  // defaults write com.paper2brain.jot routeDebug -bool false

    var body: some View {
        let rows = model.rows
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary)
                SearchField(text: $model.query, placeholder: model.inChat ? "追问…" : "问一句、搜论文、搜网页、记一句", onMove: model.move, onSubmit: { model.submit(secondary: $0) }, onCancel: model.onClose)
                    .frame(height: 30)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            if !rows.isEmpty {
                Divider()
                if model.overviewLoading {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("AI 推荐：正在库里和网上找…") }
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 5)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    if !row.group.isEmpty, i == 0 || rows[i - 1].group != row.group {
                        Text(row.group).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 2)
                    }
                    HStack(spacing: 10) {
                        Image(systemName: row.icon).frame(width: 20).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title).lineLimit(1)
                            if let sub = row.subtitle, !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer(minLength: 8)
                        if let action = row.action {
                            Button(i == model.selected ? action.label + " ⌘↵" : action.label) { model.selected = i; model.submit(secondary: true) }
                                .controlSize(.small)
                        }
                        if i == model.selected { Text("↵").font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(i == model.selected ? Color.accentColor.opacity(0.18) : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { model.selected = i; model.submit() }
                }
            }
            if model.inChat {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(model.turns.suffix(3).enumerated()), id: \.offset) { _, t in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.q).font(.callout.weight(.medium)).lineLimit(1)
                            Text(t.a).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Text(model.asked).font(.callout.weight(.medium))
                    switch model.answer {
                    case .loading, .none: HStack(spacing: 8) { ProgressView().controlSize(.small); Text("联网查一下…").foregroundStyle(.secondary) }
                    case let .done(text, sources)?:
                        VStack(alignment: .leading, spacing: 6) {
                            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            if !sources.isEmpty {
                                HStack(spacing: 8) {
                                    Text("来源").foregroundStyle(.secondary)
                                    ForEach(Array(sources.enumerated()), id: \.offset) { _, s in
                                        if let url = URL(string: s.url) { Link(s.title.isEmpty ? url.host ?? s.url : s.title, destination: url).lineLimit(1) }
                                    }
                                }.font(.caption)
                            }
                        }
                    case let .failed(message)?: Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 12)
                HStack(spacing: 8) {
                    Button("新问题 ⌘N") { model.newChat() }.keyboardShortcut("n", modifiers: .command).buttonStyle(.borderless).font(.caption2)
                    Spacer()
                    Text("直接输入追问，↵ 发送 · 输入为空时 ↵ 复制答案并关闭 · Esc 关闭").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16).padding(.bottom, 6)
            } else if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 6)
            } else if Self.debug, let route = model.live?.route, !rows.isEmpty {
                Text("router（只记录，不影响）：\(route.intent ?? "不确定，交给模型") · \(route.layer)")
                    .font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 16).padding(.vertical, 4)
            }
        }
        .frame(width: 640)
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.08)))
        .onChange(of: rows.count) { _, _ in DispatchQueue.main.async(execute: resize) }
        .onChange(of: model.error) { _, _ in DispatchQueue.main.async(execute: resize) }
        .onChange(of: model.answer) { _, _ in DispatchQueue.main.async(execute: resize) }
        .onChange(of: model.turns.count) { _, _ in DispatchQueue.main.async(execute: resize) }
        .onChange(of: model.asked) { _, _ in DispatchQueue.main.async(execute: resize) }
        .onChange(of: model.overviewLoading) { _, _ in DispatchQueue.main.async(execute: resize) }
    }
}

/// A one-line field: arrows move the selection, Return runs the row, Esc closes. While an input method is composing
/// those keys and the half-typed letters are the input method's, so neither is acted on.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onMove: (Int) -> Void
    var onSubmit: (Bool) -> Void  // true: with ⌘
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if textView.hasMarkedText() { return false }
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit(NSApp.currentEvent?.modifierFlags.contains(.command) == true)
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }
}

/// The bar's window: a new one each time (so it opens empty), top-centre of the screen the mouse is on.
@MainActor
final class SearchController {
    private let jot: Jot
    private var panel: FloatingPanel?
    private var model: SearchModel?
    private var kept: Session?  // the last conversation, offered again for ten minutes

    init(jot: Jot) { self.jot = jot }

    var visible: Bool { panel?.isVisible == true }

    func toggle() { visible ? close() : show() }

    func show() {
        panel?.orderOut(nil)
        let model = SearchModel(jot: jot, resume: kept)
        self.model = model
        model.onClose = { [weak self] in self?.close() }
        let panel = FloatingPanel(SearchView(model: model, resize: { [weak self] in self?.resize() }), takesKeyboard: true)
        panel.onResign = { [weak self] in DispatchQueue.main.async { self?.close() } }
        self.panel = panel
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        panel.fit()
        if let area = screen?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: area.midX - panel.frame.width / 2, y: area.maxY - area.height * 0.22))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        if let s = model?.session ?? model?.lastKept { kept = s }
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }

    /// The list grew or shrank: the top edge stays where it is.
    private func resize() {
        guard let panel, let size = panel.contentView?.fittingSize else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
    }
}
