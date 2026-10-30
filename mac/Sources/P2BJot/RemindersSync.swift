import EventKit
import Foundation

/// 待办 → "提醒事项"里的一个列表（Idea2do 的 AppleSyncService，只做提醒事项，不做日历）。以服务器为准、单向推送：每 30 秒
/// 拿一次全部待办，变过的（revision 或状态不同）写过去；不做了、移除了、删了的从列表里删掉。勾选完成会读回来：只读回之后
/// 这边没再改过的（带着 revision，服务器那边变过就拒绝，下一轮把提醒改回去）。对应关系存在本机 Application Support。
@MainActor
final class RemindersSync {
    static let listName = "p2b 随手记"
    private let store = EKEventStore()
    private var links: [String: Link] = [:]
    private var timer: Timer?
    private var running = false
    var onProblem: ((String?) -> Void)?

    struct Link: Codable { var item: String; var revision: Int; var status: String }

    private var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("p2b-jot")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("reminders.json")
    }

    var enabled: Bool { UserDefaults.standard.bool(forKey: "remindersSync") }

    init() {
        links = (try? JSONDecoder().decode([String: Link].self, from: Data(contentsOf: file))) ?? [:]
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.soon() }
        }
    }

    /// Asks for access the first time; false when the user said no.
    func enable() async -> Bool {
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        UserDefaults.standard.set(granted, forKey: "remindersSync")
        if granted { start() } else { onProblem?("没有提醒事项的权限：在 系统设置 › 隐私与安全性 › 提醒事项 里打开") }
        return granted
    }

    func disable() {
        UserDefaults.standard.set(false, forKey: "remindersSync")
        timer?.invalidate(); timer = nil
    }

    func start() {
        guard enabled else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.soon() } }
        soon()
    }

    func soon() {
        guard enabled, !running else { return }
        Task { await round() }
    }

    private func round() async {
        running = true
        defer { running = false }
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            disable(); onProblem?("提醒事项的权限被关掉了，同步已停"); return
        }
        do {
            let doc = try await Server.shared.get("/api/bot/idea2do/sync", as: SyncDoc.self)
            let list = try calendar()
            var changed = try await readBack(doc.tasks)
            if changed { return soon() }  // the server moved on: push from what it says now
            let zone = TimeZone(identifier: doc.tz) ?? .current
            var seen = Set<String>()
            for task in doc.tasks {
                seen.insert(task.id)
                changed = try push(task, into: list, zone: zone) || changed
            }
            for (id, link) in links where !seen.contains(id) {  // deleted on the server
                if let item = store.calendarItem(withIdentifier: link.item) as? EKReminder { try store.remove(item, commit: false) }
                links[id] = nil; changed = true
            }
            if changed { try store.commit(); save() }
            onProblem?(nil)
        } catch {
            onProblem?("同步到提醒事项没成：\(error.localizedDescription)")
        }
    }

    /// Ticks made in Reminders on items this side has not changed since: completed → 完成, unticked → 恢复.
    private func readBack(_ tasks: [SyncTask]) async throws -> Bool {
        var asked = false
        for task in tasks {
            guard let link = links[task.id], link.revision == task.revision, link.status == task.status,
                  let item = store.calendarItem(withIdentifier: link.item) as? EKReminder else { continue }
            let active = ["open", "waiting", "deferred"].contains(task.status)
            let want = item.isCompleted && active ? "completed" : !item.isCompleted && task.status == "completed" ? "open" : nil
            guard let want else { continue }
            _ = try? await Server.shared.post("/api/bot/idea2do/items/\(task.id)", ["status": want, "revision": task.revision])
            asked = true
        }
        return asked
    }

    /// Writes one task; true when something changed in the store.
    private func push(_ task: SyncTask, into list: EKCalendar, zone: TimeZone) throws -> Bool {
        let existing = links[task.id].flatMap { store.calendarItem(withIdentifier: $0.item) as? EKReminder }
        guard ["open", "waiting", "deferred", "completed"].contains(task.status) else {
            if let existing { try store.remove(existing, commit: false) }
            let had = links[task.id] != nil
            links[task.id] = nil
            return had || existing != nil
        }
        if let existing, let link = links[task.id], link.revision == task.revision, link.status == task.status { _ = existing; return false }
        let item = existing ?? EKReminder(eventStore: store)
        if existing == nil { item.calendar = list }
        let rough = [task.due, task.remind].contains { $0?.certainty == "approximate" }
        item.title = (rough ? "约 " : "") + task.title
        item.notes = task.quote.map { "来自 p2b 随手记 · 原文：" + String($0.prefix(200)) }
        item.url = URL(string: "p2b://task/\(task.id)")
        item.dueDateComponents = components(task.due, zone: zone)
        item.alarms?.forEach { item.removeAlarm($0) }
        if let parts = components(task.remind, zone: zone), let at = Calendar.current.date(from: parts.hour == nil ? with9am(parts) : parts) {
            item.addAlarm(EKAlarm(absoluteDate: at))
        }
        item.priority = ["high": 1, "medium": 5, "low": 9][task.priority ?? ""] ?? 0
        item.isCompleted = task.status == "completed"
        try store.save(item, commit: false)
        links[task.id] = Link(item: item.calendarItemIdentifier, revision: task.revision, status: task.status)
        return true
    }

    /// "2026-10-01" → a day; "2026-10-01T15:00" → a time in the user's zone. Unresolved times are no time.
    private func components(_ spec: DateSpec?, zone: TimeZone) -> DateComponents? {
        guard let spec, spec.certainty != "unresolved", let date = spec.date else { return nil }
        let n = date.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard n.count >= 3 else { return nil }
        var parts = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: zone, year: n[0], month: n[1], day: n[2])
        if n.count >= 5 { parts.hour = n[3]; parts.minute = n[4] }
        return parts
    }

    private func with9am(_ parts: DateComponents) -> DateComponents { var p = parts; p.hour = 9; p.minute = 0; return p }

    /// Our list in Reminders, made the first time in the default account.
    private func calendar() throws -> EKCalendar {
        if let found = store.calendars(for: .reminder).first(where: { $0.title == Self.listName }) { return found }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = Self.listName
        guard let source = store.defaultCalendarForNewReminders()?.source ?? store.sources.first(where: { $0.sourceType == .local }) else {
            throw NSError(domain: "p2b", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到可以放提醒事项列表的账户"])
        }
        list.source = source
        try store.saveCalendar(list, commit: true)
        return list
    }

    private func save() {
        try? JSONEncoder().encode(links).write(to: file, options: .atomic)
    }
}
