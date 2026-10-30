import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A panel that floats over everything without activating this app (Idea2do's FloatingPanel). Only the input bubble takes
/// the keyboard: it becomes key while the app the user is in stays active.
final class FloatingPanel: NSPanel {
    var takesKeyboard = false
    var onResign: (() -> Void)?

    init<V: View>(_ view: V, takesKeyboard: Bool) {
        self.takesKeyboard = takesKeyboard
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        contentView = NSHostingView(rootView: view)
    }

    override var canBecomeKey: Bool { takesKeyboard }
    override var canBecomeMain: Bool { false }
    override func resignKey() { super.resignKey(); onResign?() }

    func fit() { setContentSize(contentView?.fittingSize ?? .zero) }
}

// MARK: The input bubble

struct QuickCaptureView: View {
    @ObservedObject var jot: Jot
    var onClose: () -> Void
    var onOpenPage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = jot.error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "leaf.fill").foregroundStyle(Color(red: 0.24, green: 0.62, blue: 0.56)).padding(.top, 4)
                InputView(jot: jot, onSubmit: submit, onCancel: onClose)
                    .frame(height: 76)
            }
            if !jot.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(jot.attachments) { f in
                            HStack(spacing: 4) {
                                Image(systemName: f.isImage ? "photo" : "doc.text")
                                Text(f.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 140)
                                if f.reading { ProgressView().controlSize(.mini) }
                                Button { jot.remove(f.id) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                                    .help("去掉")
                            }
                            .font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                        }
                    }
                }
                Toggle("附件可以发给模型（图片本身与识别出的文字，仅本条）", isOn: $jot.share).font(.caption).toggleStyle(.checkbox)
            }
            HStack(spacing: 6) {
                ForEach(["待办：", "想法：", "记住："], id: \.self) { p in
                    Button(p) { jot.prefix(p) }.buttonStyle(.borderless).font(.caption)
                }
                Button { pickFiles() } label: { Image(systemName: "paperclip") }.buttonStyle(.borderless).help("图片、PDF、文本文件，最多 5 个；也可以粘贴或拖进来")
                Spacer()
                if jot.busy { ProgressView().controlSize(.small) }
                Text("回车收下 · ⇧回车换行").font(.caption2).foregroundStyle(.secondary)
                Button { onOpenPage() } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless).help("打开网页上的随手记")
            }
        }
        .padding(12)
        .frame(width: 400)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in drop(providers) }
    }

    private func submit() {
        Task { if await jot.submit() { onClose() } }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .pdf, .plainText, .commaSeparatedText, .json] + [UTType(filenameExtension: "md")].compactMap { $0 }
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { jot.add(urls: panel.urls) }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in jot.add(urls: [url]) } }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { image, _ in
                    if let image = image as? NSImage { Task { @MainActor in jot.add(image: image, name: "拖入的图片.png") } }
                }
            }
        }
        return true
    }
}

/// An NSTextView: Return sends, Shift-Return breaks the line, Esc closes; while an input method is composing, Return and
/// Esc are the input method's. Pasting a picture or files makes attachments.
struct InputView: NSViewRepresentable {
    @ObservedObject var jot: Jot
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let text = JotTextView()
        text.delegate = context.coordinator
        text.jot = jot
        text.isRichText = false
        text.allowsUndo = true
        text.font = .systemFont(ofSize: 14)
        text.drawsBackground = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.textContainerInset = NSSize(width: 0, height: 4)
        text.string = jot.text
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        context.coordinator.view = text
        DispatchQueue.main.async { text.window?.makeFirstResponder(text) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let text = scroll.documentView as? NSTextView, text.string != jot.text, !text.hasMarkedText() {
            text.string = jot.text
            text.setSelectedRange(NSRange(location: (jot.text as NSString).length, length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InputView
        weak var view: NSTextView?
        init(_ parent: InputView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView else { return }
            MainActor.assumeIsolated { parent.jot.text = text.string }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if textView.hasMarkedText() { return false }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { textView.insertNewlineIgnoringFieldEditor(nil); return true }
                parent.onSubmit(); return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) { parent.onCancel(); return true }
            return false
        }
    }
}

final class JotTextView: NSTextView {
    weak var jot: Jot?

    override func paste(_ sender: Any?) {
        if let jot, MainActor.assumeIsolated({ jot.add(pasteboard: .general) }) { return }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let jot, MainActor.assumeIsolated({ jot.add(pasteboard: sender.draggingPasteboard) }) { return true }
        return super.performDragOperation(sender)
    }
}

// MARK: The card when hovering the pet (Idea2do's PeekCard)

struct PeekCard: View {
    @ObservedObject var jot: Jot
    var onCapture: () -> Void
    var onOpenPage: () -> Void
    var onHover: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let offline = jot.offline {
                Text(offline).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            let next = Array((jot.status?.next ?? []).prefix(5))
            Text(next.isEmpty ? "接下来没有要做的" : "接下来").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(next) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Button { jot.complete(item.id) } label: { Image(systemName: "circle") }.buttonStyle(.borderless).help("完成")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).lineLimit(2)
                        if let reason = item.reason, !reason.isEmpty { Text(reason).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                .font(.callout)
            }
            let pending = Array((jot.status?.suggestions ?? []).prefix(3))
            if !pending.isEmpty {
                Divider()
                Text("待确认").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(pending) { s in
                    HStack(spacing: 6) {
                        Text(s.text).lineLimit(2).font(.callout)
                        Spacer(minLength: 4)
                        Button("好") { jot.decide(s.id, accept: true) }.controlSize(.small)
                        Button("不用") { jot.decide(s.id, accept: false) }.controlSize(.small)
                    }
                }
            }
            if let status = jot.status, status.organizing > 0 {
                Text("\(status.organizing) 条在整理…").font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("记录一下", action: onCapture)
                Spacer()
                Button("打开随手记", action: onOpenPage)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))
        .onHover(perform: onHover)
    }
}
