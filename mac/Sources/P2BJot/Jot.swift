import AppKit
import Vision

/// One file going along with the next capture. Pictures are read on this Mac (Vision) and the text goes along with them;
/// pictures the server cannot open (HEIC, TIFF, BMP) go up as JPEG.
struct Attachment: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var data: Data
    var isImage: Bool
    var text: String?
    var reading = false
}

/// The capture side shared by the pet, the input panel and the menus (Idea2do's WorkspaceViewModel, server-backed).
@MainActor
final class Jot: ObservableObject {
    static let maxFiles = 5, maxBytes = 50 * 1024 * 1024, maxText = 20_000
    static let images: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp"]
    static let others: Set<String> = ["pdf", "txt", "md", "markdown", "csv", "json", "log"]

    @Published var status: Status?
    @Published var offline: String?
    @Published var text = UserDefaults.standard.string(forKey: "draft") ?? "" {
        didSet { UserDefaults.standard.set(text, forKey: "draft") }
    }
    @Published var attachments: [Attachment] = []
    @Published var share = true
    @Published var busy = false
    @Published var error: String?

    /// The pet's reactions: saved, a capture failed to organize, something could not be taken.
    var onSaved: (() -> Void)?
    var onWorried: ((String) -> Void)?
    var onChanged: (() -> Void)?

    var hasDraft: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }

    func refresh() async {
        do {
            let got = try await Server.shared.get("/api/bot/idea2do/status", as: Status.self)
            if let old = status, got.failed > old.failed { onWorried?("整理失败") }
            if got != status { status = got; onChanged?() }
            offline = nil
        } catch {
            offline = error.localizedDescription
        }
    }

    // MARK: Sending

    /// The draft (text and attachments) as one capture. True when it was kept.
    func submit() async -> Bool {
        guard hasDraft, !busy else { return false }
        guard text.count <= Self.maxText else { error = "太长了（2 万字以内）"; return false }
        guard !attachments.contains(where: \.reading) else { error = "图片还在识别文字，稍等"; return false }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await save(text: text, source: "typed", files: attachments, share: share)
            text = ""; attachments = []; share = true
            onSaved?()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func save(text: String, source: String, files: [Attachment] = [], share: Bool = true) async throws {
        var sent: [[String: Any]] = []
        for f in files {
            let id = try await Server.shared.upload(name: f.name, data: f.data)
            sent.append(["id": id, "text": f.text ?? ""])
        }
        var body: [String: Any] = ["text": text, "source": source, "tz": TimeZone.current.identifier]
        if !sent.isEmpty { body["files"] = sent; body["share"] = share }
        try await Server.shared.post("/api/bot/idea2do/captures", body)
        await refresh()
    }

    /// Dropped or clipboard text is material: its "待办：" are not orders.
    func keep(material: String) {
        Task {
            do { try await save(text: material, source: "pasted"); onSaved?() } catch { onWorried?("操作未完成") }
        }
    }

    // MARK: Attachments

    /// Files from a drop, a paste or the open panel. Returns what was refused, to say why.
    @discardableResult
    func add(urls: [URL]) -> String? {
        var refused: String?
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard Self.images.contains(ext) || Self.others.contains(ext) else { refused = "「\(url.lastPathComponent)」：只收图片、PDF 和文本文件"; continue }
            guard let data = try? Data(contentsOf: url), data.count <= Self.maxBytes else { refused = "「\(url.lastPathComponent)」读不了，或超过 50MB"; continue }
            if !add(name: url.lastPathComponent, data: data, isImage: Self.images.contains(ext)) { refused = "一条最多 \(Self.maxFiles) 个附件" }
        }
        if let refused { error = refused }
        return refused
    }

    @discardableResult
    func add(image: NSImage, name: String) -> Bool {
        guard let png = NSBitmapImageRep(data: image.tiffRepresentation ?? Data())?.representation(using: .png, properties: [:]) else { return false }
        return add(name: name, data: png, isImage: true)
    }

    /// The clipboard's files, else its picture; false when it has neither (then it is ordinary text to paste).
    func add(pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            add(urls: urls); return true
        }
        if pasteboard.string(forType: .string) == nil, let image = NSImage(pasteboard: pasteboard) {
            let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium).replacingOccurrences(of: ":", with: ".")
            return add(image: image, name: "粘贴的图片 \(stamp).png".replacingOccurrences(of: "/", with: "-"))
        }
        return false
    }

    private func add(name: String, data: Data, isImage: Bool) -> Bool {
        guard attachments.count < Self.maxFiles else { return false }
        var file = Attachment(name: name, data: data, isImage: isImage)
        if isImage, !["png", "jpg", "jpeg", "gif", "webp"].contains((name as NSString).pathExtension.lowercased()),
           let jpeg = NSBitmapImageRep(data: NSImage(data: data)?.tiffRepresentation ?? Data())?.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            file.data = jpeg
            file.name = (name as NSString).deletingPathExtension + ".jpg"
        }
        file.reading = isImage
        attachments.append(file)
        if isImage {
            let id = file.id, data = file.data
            Task {
                let text = await Self.recognize(data)
                if let i = attachments.firstIndex(where: { $0.id == id }) { attachments[i].text = text; attachments[i].reading = false }
            }
        }
        return true
    }

    func remove(_ id: UUID) { attachments.removeAll { $0.id == id } }

    /// Text in a picture, top to bottom then left to right (Idea2do's LocalContentParser).
    nonisolated static func recognize(_ data: Data) async -> String {
        await Task.detached(priority: .userInitiated) {
            guard let image = NSImage(data: data), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "" }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            try? VNImageRequestHandler(cgImage: cg).perform([request])
            let lines = (request.results ?? []).sorted {
                abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01 ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX
            }
            return String(lines.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n").prefix(50_000))
        }.value
    }

    // MARK: Acting on what is there

    func complete(_ id: String) { act("/api/bot/idea2do/items/\(id)", ["status": "completed"]) }
    func decide(_ id: String, accept: Bool) { act("/api/bot/idea2do/suggestions/\(id)", ["accept": accept]) }

    private func act(_ path: String, _ body: [String: Any]) {
        Task {
            do { try await Server.shared.post(path, body) } catch { onWorried?("操作未完成") }
            await refresh()
        }
    }

    /// The "待办：" style prefix at the start of the last line, replacing one already there.
    func prefix(_ p: String) {
        var lines = text.components(separatedBy: "\n")
        var last = lines.removeLast()
        for old in ["待办：", "想法：", "记住："] where last.hasPrefix(old) { last.removeFirst(old.count) }
        text = (lines + [p + last]).joined(separator: "\n")
    }
}
