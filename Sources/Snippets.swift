// Snippets: a global hotkey (Ctrl-Opt-Cmd-S) collects the marked text of any app, with its
// source, in Snippets.md. "Synchronize" renders the file as one PDF, if it has changed, and
// replaces the "Snippets" document on the Paper Pro with it.

import AppKit
import Carbon.HIToolbox
import CryptoKit

// MARK: - The file

struct Snippet { var date = "", title = "", lines: [String] = [], source = "" }

enum Snippets {
    /// `defaults write local.rm-clipper snippetsFile <path>`, else iCloud Drive/Remarkable.
    static var file: URL {
        if let p = Settings.defaults.string(forKey: "snippetsFile"), !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        let base = FileManager.default.fileExists(atPath: cloud.path) ? cloud : home.appendingPathComponent("Documents")
        return base.appendingPathComponent("Remarkable/Snippets.md")
    }

    static func add(_ markdown: String) throws {
        let f = file
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = (try? Data(contentsOf: f)) ?? Data()
        if old.isEmpty, FileManager.default.fileExists(atPath: f.path), (try? Data(contentsOf: f)) == nil {
            throw CocoaError(.fileReadUnknown)   // there, but not readable: do not overwrite it
        }
        if old.isEmpty { try Data(("# Snippets\n\n" + markdown).utf8).write(to: f); return }
        let h = try FileHandle(forWritingTo: f)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data(((old.last == 10 ? "" : "\n") + markdown).utf8))
    }

    /// The snippets and a fingerprint of the file they were read from.
    static func load() -> (all: [Snippet], digest: String) {
        guard let d = try? Data(contentsOf: file) else { return ([], "") }
        let hex = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
        return (parse(String(decoding: d, as: UTF8.self)), hex)
    }

    static func parse(_ md: String) -> [Snippet] {
        var out: [Snippet] = []
        for raw in md.components(separatedBy: "\n") {
            if raw.hasPrefix("## ") {
                let head = String(raw.dropFirst(3))
                var s = Snippet()
                if let r = head.range(of: " - ") { s.date = String(head[..<r.lowerBound]); s.title = String(head[r.upperBound...]) }
                else { s.title = head }
                out.append(s)
            } else if !out.isEmpty, raw.hasPrefix(">") {
                let t = raw.dropFirst().trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out[out.count - 1].lines.append(t) }
            } else if !out.isEmpty, raw.hasPrefix("- ") { out[out.count - 1].source = String(raw.dropFirst(2)) }
        }
        return out
    }

    // Tablet side: what is there, and whether an update is wanted.
    static var pending: Bool {
        get { Settings.defaults.bool(forKey: "snippets.pending") }
        set { Settings.defaults.set(newValue, forKey: "snippets.pending") }
    }
    static var sent: Int {
        get { Settings.defaults.integer(forKey: "snippets.sent") }
        set { Settings.defaults.set(newValue, forKey: "snippets.sent") }
    }
    static var document: String {
        get {
            let s = Settings.defaults.string(forKey: "snippets.document") ?? ""
            return s.allSatisfy { $0.isHexDigit || $0 == "-" } ? s : ""
        }
        set { Settings.defaults.set(newValue, forKey: "snippets.document") }
    }
    private static var sentDigest: String { Settings.defaults.string(forKey: "snippets.sentDigest") ?? "" }
    static func markSent(_ count: Int, _ digest: String) {
        sent = count
        Settings.defaults.set(digest, forKey: "snippets.sentDigest")
    }
    /// What the tablet does not have yet: nil if it is up to date or there are no snippets.
    static var news: String? {
        let f = load()
        guard !f.all.isEmpty, f.digest != sentDigest else { return nil }
        let n = f.all.count - sent
        return n == 1 ? "1 new snippet" : n > 1 ? "\(n) new snippets" : "snippets changed"
    }
}

// MARK: - Rendering for the tablet

enum SnippetPDF {
    private static let indent: CGFloat = 14
    private static let grey = NSColor(white: 0.25, alpha: 1)
    private static let accent = NSColor(red: 0.05, green: 0.25, blue: 0.65, alpha: 1)

    private static func font(_ name: String, _ size: CGFloat) -> NSFont { NSFont(name: name, size: size) ?? .systemFont(ofSize: size) }
    private static func style(_ lineHeight: CGFloat, after: CGFloat = 0) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = lineHeight
        p.paragraphSpacing = after
        return p
    }
    private static func text(_ s: String, _ f: NSFont, _ c: NSColor, _ p: NSParagraphStyle,
                             _ extra: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
        NSAttributedString(string: s, attributes: extra.merging([.font: f, .foregroundColor: c, .paragraphStyle: p]) { a, _ in a })
    }
    @discardableResult
    private static func draw(_ s: NSAttributedString, in r: CGRect, _ c: CGContext, from start: Int = 0) -> Int {
        let fs = CTFramesetterCreateWithAttributedString(s)
        let f = CTFramesetterCreateFrame(fs, CFRange(location: start, length: 0), CGPath(rect: r, transform: nil), nil)
        CTFrameDraw(f, c)
        return CTFrameGetVisibleStringRange(f).length
    }
    private static func height(_ s: NSAttributedString, _ width: CGFloat, from start: Int = 0) -> CGFloat {
        let fs = CTFramesetterCreateWithAttributedString(s)
        return ceil(CTFramesetterSuggestFrameSizeWithConstraints(
            fs, CFRange(location: start, length: 0), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil).height) + 1
    }

    /// Newest first, as many pages as needed. nil when there is nothing to show.
    static func render(_ snippets: [Snippet]) -> (pdf: Data, pages: Int)? {
        guard !snippets.isEmpty else { return nil }
        let out = NSMutableData()
        var media = CGRect(origin: .zero, size: screenPage)
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let c = CGContext(consumer: consumer, mediaBox: &media, [kCGPDFContextTitle as String: "Snippets"] as CFDictionary) else { return nil }
        let area = screenArea, floorY = area.minY + 16
        var y: CGFloat = 0, pages = 0
        func newPage() {
            if pages > 0 { c.endPDFPage() }
            c.beginPDFPage(nil)
            pages += 1
            y = area.maxY
            draw(text("\(pages)", font("Helvetica Neue", 9), grey, style(1)),
                 in: CGRect(x: area.maxX - 30, y: area.minY - 4, width: 30, height: 14), c)
        }
        newPage()
        let head = text("Snippets", font("Charter-Bold", 26), .black, style(1))
        let hh = height(head, area.width)
        draw(head, in: CGRect(x: area.minX, y: y - hh, width: area.width, height: hh), c)
        y -= hh + 10

        for s in snippets.reversed() {
            let date = text(s.date, font("Helvetica Neue", 9.5), grey, style(1))
            let title = text(s.title, font("Charter-Bold", 15), .black, style(1.08))
            let para = text(s.lines.joined(separator: "\n"), font("Charter-Roman", 12.5), .black, style(1.18, after: 6))
            let parts = s.source.components(separatedBy: " · ")
            let url = parts.first.flatMap { $0.hasPrefix("http") ? URL(string: $0) : nil }
            var place = parts.first ?? ""
            if let u = url { place = (u.host ?? "") + (u.path == "/" ? "" : u.path) + (u.query.map { "?" + $0 } ?? "") }
            if place.count > 78 { place = String(place.prefix(60)) + "…" + String(place.suffix(16)) }
            let src = NSMutableAttributedString(attributedString: text(
                place, font("Helvetica Neue", 9.5), url == nil ? grey : accent, style(1.1),
                url == nil ? [:] : [.underlineStyle: NSUnderlineStyle.single.rawValue]))
            if parts.count > 1 { src.append(text("  ·  " + parts[1], font("Helvetica Neue", 9.5), grey, style(1.1))) }

            let inner = area.width - indent, lineH: CGFloat = 18
            let hd = height(date, area.width), ht = height(title, area.width), hs = height(src, inner)
            let total = hd + ht + 6 + height(para, inner) + 4 + hs
            // Heading and two lines stay together; a snippet that fits on a page is not split.
            if y - (hd + ht + 4 + 2 * lineH) < floorY { newPage() }
            else if y - total < floorY, total < (area.height - 16) * 0.6 { newPage() }
            draw(date, in: CGRect(x: area.minX, y: y - hd, width: area.width, height: hd), c); y -= hd + 1
            draw(title, in: CGRect(x: area.minX, y: y - ht, width: area.width, height: ht), c); y -= ht + 5
            var pos = 0
            while pos < para.length {
                let h = min(height(para, inner, from: pos), y - floorY)
                if h < lineH { newPage(); continue }
                let n = draw(para, in: CGRect(x: area.minX + indent, y: y - h, width: inner, height: h), c, from: pos)
                if n == 0 { newPage(); continue }
                pos += n
                c.setFillColor(accent.cgColor)
                c.fill(CGRect(x: area.minX + 2, y: y - h + 3, width: 2.5, height: h - 6))
                y -= h
                if pos < para.length { newPage() }
            }
            y -= 4
            if y - hs < floorY { newPage() }
            let r = CGRect(x: area.minX + indent, y: y - hs, width: inner, height: hs)
            draw(src, in: r, c)
            if let u = url { c.setURL(u as CFURL, for: r) }
            y -= hs + 26
        }
        c.endPDFPage()
        c.closePDF()
        return (out as Data, pages)
    }

    /// Snippets.pdf next to Snippets.md, for other devices.
    @discardableResult
    static func writeFile(_ pdf: Data) -> Bool {
        (try? pdf.write(to: Snippets.file.deletingPathExtension().appendingPathExtension("pdf"), options: .atomic)) != nil
    }
    private static let queue = DispatchQueue(label: "rm-clipper.snippets-pdf")
    static func refreshFile() {
        queue.async { if let r = render(Snippets.load().all) { writeFile(r.pdf) } }
    }
}

// MARK: - On the tablet

extension Tablet {
    private enum There { case missing, open, closed(String), annotated }

    /// Puts the snippets on the tablet when that was asked for. Runs on the tablet's queue.
    func sendSnippets() {
        guard let inbox = device.inbox, host != nil, Snippets.pending, Date() >= nextSnippets else { return }
        nextSnippets = Date().addingTimeInterval(15)
        func report(_ s: String) { DispatchQueue.main.async { self.onPrint?(s) } }
        let (all, digest) = Snippets.load()
        guard let r = SnippetPDF.render(all) else { Snippets.pending = false; report("No snippets yet"); return }
        SnippetPDF.writeFile(r.pdf)
        guard let there = snippetDocument() else { return }
        switch there {
        case .open: report("Snippets is open on the \(device.name): close it there to update"); return
        case .annotated:
            Snippets.pending = false
            report("Snippets has notes on the \(device.name): delete it there, then synchronize")
            return
        case .closed(let u): guard replaceSnippets(u, with: r.pdf, pages: r.pages) else { report("Snippets: update failed, will try again"); return }
        case .missing:
            guard let u = uploadSnippets(r.pdf, inbox: inbox) else { report("Snippets: upload failed, USB web interface off?"); return }
            Snippets.document = u
        }
        Snippets.pending = false
        Snippets.markSent(all.count, digest)
        report("Snippets updated on the \(device.name) (\(all.count))")
    }

    /// The document of earlier updates, if it is still there and in the simple format it was
    /// uploaded in. The tablet changes the format when it is written on.
    private func snippetDocument() -> There? {
        let u = Snippets.document
        if u.isEmpty { return .missing }
        let script = #"""
        cd \#(dataDir) || exit 1
        f="\#(u).metadata"; k="\#(u).content"
        if [ ! -f "$f" ] || [ ! -f "\#(u).pdf" ] || grep -q '"parent": *"trash"' "$f" || grep -q '"deleted": *true' "$f"; then echo missing
        elif ! grep -q '"formatVersion": *1' "$k" || ls "\#(u)"/*.rm >/dev/null 2>&1; then echo annotated
        elif grep -q '^LastOpen=@ByteArray(\#(u))' \#(confFile); then echo open
        else echo closed; fi
        """#
        guard let out = remote(script, timeout: 8) else { return nil }
        switch String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) {
        case "open": return .open
        case "closed": return .closed(u)
        case "annotated": return .annotated
        case "missing": return .missing
        default: return nil
        }
    }

    /// Swaps the PDF, the page list and the page templates together, while the document is
    /// closed. The tablet reads them when it opens the document, even with another number
    /// of pages. Page IDs that stay keep their place.
    private func replaceSnippets(_ u: String, with pdf: Data, pages n: Int) -> Bool {
        guard let old = remote("cat \(dataDir)/\(u).content", timeout: 8),
              var content = try? JSONSerialization.jsonObject(with: old) as? [String: Any],
              content["formatVersion"] as? Int == 1, var ids = content["pages"] as? [String] else { return false }
        ids = Array(ids.prefix(n))
        while ids.count < n { ids.append(UUID().uuidString.lowercased()) }
        content["pages"] = ids
        content["redirectionPageMap"] = Array(0..<n)
        content["pageCount"] = n
        content["originalPageCount"] = n
        guard let json = try? JSONSerialization.data(withJSONObject: content, options: [.prettyPrinted, .sortedKeys]) else { return false }
        let list = json + Data("\n".utf8), templates = Data(String(repeating: "\n", count: n).utf8)

        let dir = "/home/root/.rm-clipper-snippets"
        guard remote("mkdir -p \(dir)", timeout: 8) != nil,
              put(pdf, at: "\(dir)/pdf"), put(list, at: "\(dir)/content"), put(templates, at: "\(dir)/pagedata") else { return false }
        let cmd = #"""
        grep -q '^LastOpen=@ByteArray(\#(u))' \#(confFile) && exit 3
        cd \#(dir) && [ "$(wc -c < pdf)" -eq \#(pdf.count) ] && [ "$(wc -c < content)" -eq \#(list.count) ] || exit 4
        chmod 600 pdf && chmod 644 content pagedata && mv pdf \#(dataDir)/\#(u).pdf && mv pagedata \#(dataDir)/\#(u).pagedata && mv content \#(dataDir)/\#(u).content
        """#
        return remote(cmd, timeout: 15) != nil
    }

    private func put(_ data: Data, at path: String) -> Bool {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rm-clipper-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? data.write(to: tmp)) != nil, let input = try? FileHandle(forReadingFrom: tmp), let h = host else { return false }
        return run(ssh, base + ["root@\(h)", "cat > \(path)"], timeout: 60, capture: false, input: input).status == 0
    }

    /// First time, or after the document was deleted: upload it like a print.
    private func uploadSnippets(_ pdf: Data, inbox: String) -> String? {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rm-clipper-" + UUID().uuidString)
        let file = dir.appendingPathComponent("Snippets.pdf")
        defer { try? FileManager.default.removeItem(at: dir) }
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
              (try? pdf.write(to: file)) != nil else { return nil }
        let folder = folderID(inbox)
        var ok = false
        withWebInterface { ok = upload(Job(dir: dir, file: file), folder: folder) }
        guard ok else { return nil }
        Thread.sleep(forTimeInterval: 2)
        let script = #"""
        cd \#(dataDir) || exit 1
        for f in $(ls -t *.metadata | head -n 10); do u=${f%.metadata}
          grep -q '"visibleName": *"Snippets"' "$f" && grep -q '"parent": *"\#(folder ?? "")"' "$f" && grep -q '"fileType": *"pdf"' "$u.content" && echo "$u" && break
        done
        """#
        guard let out = remote(script, timeout: 8) else { return nil }
        let u = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return !u.isEmpty && u.allSatisfy({ $0.isHexDigit || $0 == "-" }) ? u : nil
    }
}

// MARK: - Reading the marked text and its source

struct Grab {
    var app = "", bundle = "", text = ""
    var concealed = false
    var clipURL: String?, tabTitle: String?, tabURL: String?, axTitle: String?, axDocument: String?, axSelected: String?

    /// The tab's title only counts if the tab shows the page the text was copied from.
    var title: String? {
        guard let t = tabURL else { return nil }
        guard let c = clipURL else { return tabTitle }
        func norm(_ s: String) -> String {
            var u = s.components(separatedBy: "#")[0]
            while u.hasSuffix("/") { u.removeLast() }
            return u
        }
        return norm(t) == norm(c) ? tabTitle : nil
    }
    var url: String? { clipURL ?? tabURL }

    /// Page title, else the site, else the window title, else the app.
    var heading: String {
        let t = title ?? url.flatMap { URL(string: $0)?.host } ?? axTitle ?? ""
        let words = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Window titles may begin with a status symbol.
        let clean = words.drop { !($0.isLetter || $0.isNumber || "\"'“„«([<#@/~.$€".contains($0)) }
        return clean.isEmpty ? app : String(clean)
    }
    var source: String {
        [url ?? axDocument.map { URL(string: $0)?.path ?? $0 }, app].compactMap { $0 }.joined(separator: " · ")
    }
    /// Every line is its own quoted paragraph.
    func markdown(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return "## \(f.string(from: date)) - \(heading)\n\n" + lines.map { "> " + $0 }.joined(separator: "\n>\n") + "\n\n- \(source)\n\n"
    }
}

enum Reader {
    static let safariLike: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    static let chromeLike: Set<String> = ["com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium",
                                          "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi",
                                          "company.thebrowser.Browser", "com.operasoftware.Opera"]

    static func clipboard(_ pb: NSPasteboard, into g: inout Grab) {
        let types = (pb.types ?? []).map(\.rawValue)
        g.concealed = types.contains { ["org.nspasteboard.ConcealedType", "com.agilebits.onepassword"].contains($0) }
        if g.concealed { return }
        g.text = pb.string(forType: .string) ?? ""
        if let s = pb.string(forType: .init("org.chromium.source-url")), !s.isEmpty { g.clipURL = s }
        else if let d = pb.data(forType: .init("com.apple.webarchive")),
                let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
                let main = p["WebMainResource"] as? [String: Any], let s = main["WebResourceURL"] as? String,
                s.hasPrefix("http") || s.hasPrefix("file") { g.clipURL = s }
    }

    /// Title and address of the current tab, if a browser is in front.
    static func tab(into g: inout Grab) {
        let props: String
        if safariLike.contains(g.bundle) { props = "{name, URL} of current tab of front window" }
        else if chromeLike.contains(g.bundle) { props = "{title, URL} of active tab of front window" }
        else { return }
        var err: NSDictionary?
        // 60 seconds, because macOS may ask for permission first.
        let s = NSAppleScript(source: "with timeout of 60 seconds\ntell application id \"\(g.bundle)\" to get \(props)\nend timeout")
        guard let r = s?.executeAndReturnError(&err), err == nil, r.numberOfItems == 2 else { return }
        g.tabTitle = r.atIndex(1)?.stringValue
        g.tabURL = r.atIndex(2)?.stringValue
    }

    static func window(_ pid: pid_t, into g: inout Grab) {
        guard AXIsProcessTrusted() else { return }
        func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
        }
        let app = AXUIElementCreateApplication(pid)
        if let w = attr(app, kAXFocusedWindowAttribute) {
            g.axTitle = attr(w as! AXUIElement, kAXTitleAttribute) as? String
            g.axDocument = attr(w as! AXUIElement, kAXDocumentAttribute) as? String
        }
        if let f = attr(app, kAXFocusedUIElementAttribute) {
            g.axSelected = attr(f as! AXUIElement, kAXSelectedTextAttribute) as? String
        }
    }

    typealias Saved = [[(type: NSPasteboard.PasteboardType, data: Data)]]
    static func save(_ pb: NSPasteboard) -> Saved {
        (pb.pasteboardItems ?? []).map { i in i.types.compactMap { t in i.data(forType: t).map { (t, $0) } } }
    }
    static func restore(_ saved: Saved, to pb: NSPasteboard) {
        pb.clearContents()
        let items = saved.filter { !$0.isEmpty }.map { parts -> NSPasteboardItem in
            let i = NSPasteboardItem()
            for p in parts { i.setData(p.data, forType: p.type) }
            return i
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }

    /// Sends Cmd-C to the app in front once the hotkey's own modifiers are released, and
    /// reports on the main queue whether something was copied.
    static func copyMarked(_ pb: NSPasteboard, then done: @escaping (Bool) -> Void) {
        let before = pb.changeCount
        func send() {
            let src = CGEventSource(stateID: .privateState)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: down)
                e?.flags = .maskCommand
                e?.post(tap: .cghidEventTap)
            }
        }
        func waitForCopy(_ left: Int) {
            if pb.changeCount != before { DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { done(true) }; return }
            if left == 0 { done(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { waitForCopy(left - 1) }
        }
        func waitForKeys(_ left: Int) {
            let held = CGEventSource.flagsState(.combinedSessionState)
                .intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
            if held.isEmpty { send(); waitForCopy(30); return }
            if left == 0 { done(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { waitForKeys(left - 1) }
        }
        waitForKeys(70)
    }
}

// MARK: - Hotkey and confirmation

/// A short note in the top right corner of the space in use.
final class Note {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 70),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let label = NSTextField(wrappingLabelWithString: "")
    private var hide: DispatchWorkItem?

    init() {
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let back = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 360, height: 70))
        back.material = .hudWindow
        back.state = .active
        back.wantsLayer = true
        back.layer?.cornerRadius = 12
        label.frame = back.bounds.insetBy(dx: 14, dy: 10)
        label.autoresizingMask = [.width, .height]
        label.maximumNumberOfLines = 3
        back.addSubview(label)
        panel.contentView = back
    }

    func show(_ title: String, _ text: String = "", seconds: Double = 2) {
        let s = NSMutableAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        if !text.isEmpty {
            s.append(NSAttributedString(string: "\n" + text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        label.attributedStringValue = s
        label.lineBreakMode = .byTruncatingTail
        if let f = NSScreen.main?.visibleFrame { panel.setFrameTopLeftPoint(NSPoint(x: f.maxX - 374, y: f.maxY - 12)) }
        panel.orderOut(nil)   // an open note would stay in the space it was shown in
        panel.orderFrontRegardless()
        hide?.cancel()
        let w = DispatchWorkItem { [panel] in panel.orderOut(nil) }
        hide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }
}

final class SnippetCapture {
    var onSaved: (() -> Void)?
    private let note = Note()
    private var busy = false
    private var last = ""

    /// Ctrl-Opt-Cmd-S. Returns false if the hotkey is taken.
    func install() -> Bool {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, me in
            guard let me else { return noErr }
            let capture = Unmanaged<SnippetCapture>.fromOpaque(me).takeUnretainedValue()
            DispatchQueue.main.async { capture.grab() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        var ref: EventHotKeyRef?
        return RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey | cmdKey),
                                   EventHotKeyID(signature: 0x524D_534E, id: 1), GetApplicationEventTarget(), 0, &ref) == noErr
    }

    func grab() {
        guard AXIsProcessTrusted() else {
            note.show("Snippets need Accessibility", "RM menu → Permissions → Accessibility", seconds: 4)
            return
        }
        guard !busy else { return }
        busy = true
        let front = NSWorkspace.shared.frontmostApplication   // when the key was pressed
        let pb = NSPasteboard.general
        let saved = Reader.save(pb)
        Reader.copyMarked(pb) { copied in
            self.busy = false
            var g = Grab()
            g.app = front?.localizedName ?? "?"
            g.bundle = front?.bundleIdentifier ?? "?"
            if copied {
                Reader.clipboard(pb, into: &g)
                Reader.restore(saved, to: pb)
            }
            if g.concealed { self.note.show("Not saved", "The app marked this as secret."); return }
            if let f = front { Reader.window(f.processIdentifier, into: &g) }
            // Some apps do not copy on Cmd-C but tell Accessibility what is marked.
            if g.text.isEmpty { g.text = g.axSelected ?? "" }
            if g.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.note.show("Nothing marked", "in \(g.app)")
                return
            }
            if g.text == self.last { self.note.show("Already in Snippets"); return }
            Reader.tab(into: &g)
            do {
                try Snippets.add(g.markdown(Date()))
                self.last = g.text
                SnippetPDF.refreshFile()
                self.note.show("Snippet saved", g.heading)
                self.onSaved?()
            } catch { self.note.show("Snippet not saved", error.localizedDescription, seconds: 5) }
        }
    }
}

// MARK: - Permissions

enum Permission {
    static func settings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
    static func accessibility() {
        if AXIsProcessTrusted() { settings("Privacy_Accessibility"); return }
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    /// true or false for a running browser that was asked for; nil if not known yet.
    static func automation(_ bundle: String) -> Bool? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty else { return nil }
        let d = NSAppleEventDescriptor(bundleIdentifier: bundle)
        guard let p = d.aeDesc else { return nil }
        switch AEDeterminePermissionToAutomateTarget(p, typeWildCard, typeWildCard, false) {
        case noErr: return true
        case OSStatus(errAEEventNotPermitted): return false
        default: return nil
        }
    }
}
