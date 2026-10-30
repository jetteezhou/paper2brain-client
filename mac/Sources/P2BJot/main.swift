import AppKit

/// p2b 随手记：menu bar leaf, the floating pet, ⌃⌥空格, and to-dos in Reminders. No Dock icon (LSUIElement).
@MainActor
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let jot = Jot()
    private lazy var pet = PetController(jot: jot)
    private let reminders = RemindersSync()
    private var hotKey: GlobalHotKey?
    private var status: NSStatusItem?
    private var problem: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotKey = GlobalHotKey { [weak self] in self?.pet.showQuickCapture() }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status?.button?.image = NSImage(systemSymbolName: "leaf", accessibilityDescription: "p2b 随手记")
        let menu = NSMenu()
        menu.delegate = self
        status?.menu = menu
        pet.openPage = { [weak self] in self?.openPage() }
        pet.menu = { [weak self] in self?.petMenu() ?? NSMenu() }
        jot.onSaved = { [weak self] in self?.pet.react(.happy, for: 1.8) }
        jot.onWorried = { [weak self] text in self?.pet.react(.worried(text), for: 2.8) }
        jot.onChanged = { [weak self] in self?.pet.update(); self?.reminders.soon() }
        reminders.onProblem = { [weak self] text in self?.problem = text }
        if !UserDefaults.standard.bool(forKey: "petHidden") { pet.show() }
        reminders.start()
        Task { await jot.refresh() }
        Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pet.update()
                Task { await self.jot.refresh() }
            }
        }
        if !Server.shared.configured { pet.react(.worried("还没连上服务器"), for: 6) }
    }

    func applicationWillTerminate(_ notification: Notification) { hotKey?.unregister() }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add(menu, "记录一下", key: hotKey == nil ? "" : GlobalHotKey.displayName) { [weak self] in self?.pet.showQuickCapture() }
        add(menu, "收下剪贴板内容") { [weak self] in self?.keepClipboard() }
        add(menu, "打开随手记") { [weak self] in self?.openPage() }
        menu.addItem(.separator())
        add(menu, pet.visible ? "隐藏小宠物" : "显示小宠物") { [weak self] in
            guard let self else { return }
            self.pet.visible ? self.pet.hide() : self.pet.show()
        }
        let sync = add(menu, "同步待办到提醒事项（列表「\(RemindersSync.listName)」）") { [weak self] in
            guard let self else { return }
            if self.reminders.enabled { self.reminders.disable() } else { Task { _ = await self.reminders.enable() } }
        }
        sync.state = reminders.enabled ? .on : .off
        menu.addItem(.separator())
        let note = [hotKey == nil ? "全局快捷键 \(GlobalHotKey.displayName) 被占用，未启用" : "任意位置按 \(GlobalHotKey.displayName) 记录",
                    jot.offline ?? Server.shared.base.map { "已连上 \($0.host ?? "")" }, problem].compactMap { $0 }
        for line in note { menu.addItem(NSMenuItem(title: line, action: nil, keyEquivalent: "")) }
        menu.addItem(.separator())
        add(menu, "退出") { NSApp.terminate(nil) }
    }

    /// The pet's right-click menu (Idea2do's PetController.menu).
    private func petMenu() -> NSMenu {
        let menu = NSMenu()
        add(menu, "记录一下") { [weak self] in self?.pet.showQuickCapture() }
        add(menu, "收下剪贴板内容") { [weak self] in self?.keepClipboard() }
        let next = jot.status?.next ?? []
        if !next.isEmpty {
            let sub = NSMenu()
            for item in next.prefix(8) { add(sub, "完成：" + String(item.title.prefix(40))) { [weak self] in self?.jot.complete(item.id) } }
            menu.setSubmenu(sub, for: menu.addItem(withTitle: "接下来（\(next.count)）", action: nil, keyEquivalent: ""))
        }
        let pending = jot.status?.suggestions ?? []
        if !pending.isEmpty {
            let sub = NSMenu()
            for s in pending {
                add(sub, "好：" + String(s.text.prefix(40))) { [weak self] in self?.jot.decide(s.id, accept: true) }
                add(sub, "    不用") { [weak self] in self?.jot.decide(s.id, accept: false) }
            }
            menu.setSubmenu(sub, for: menu.addItem(withTitle: "待确认（\(jot.status?.pending ?? pending.count)）", action: nil, keyEquivalent: ""))
        }
        add(menu, "打开随手记") { [weak self] in self?.openPage() }
        if let failed = jot.status?.failed, failed > 0 {
            add(menu, "\(failed) 条没整理成（原文都在），去网页上重新整理") { [weak self] in self?.openPage() }
        }
        menu.addItem(.separator())
        add(menu, "隐藏小宠物（菜单栏的叶子可以再打开）") { [weak self] in self?.pet.hide() }
        return menu
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, key: String = "", _ action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: key.isEmpty ? title : "\(title)    \(key)", action: #selector(Action.run), keyEquivalent: "")
        let target = Action(action)
        item.target = target
        item.representedObject = target  // the menu item keeps its target alive
        menu.addItem(item)
        return item
    }

    private func keepClipboard() {
        let board = NSPasteboard.general
        if jot.add(pasteboard: board) { pet.showQuickCapture(); return }
        guard let text = board.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pet.react(.reject, for: 1.6); return
        }
        jot.keep(material: text)
    }

    private func openPage() {
        if let url = Server.shared.page { NSWorkspace.shared.open(url) }
    }
}

final class Action: NSObject {
    let run_: () -> Void
    init(_ run: @escaping () -> Void) { run_ = run }
    @objc func run() { run_() }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { App() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
