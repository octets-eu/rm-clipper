// Virtual printer for the Paper Pro. The app runs macOS's own IPP printer
// (ippeveprinter, reachable only from this Mac). For each job it starts this binary
// again as `rm-clipper <file>`, which fits the PDF to the screen and leaves it in the
// queue folder; the app sends it to the tablet when that is reachable.

import AppKit
import PDFKit
import ServiceManagement

enum Paths {
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RM-Clipper")
    static let queue = support.appendingPathComponent("Queue")
    static let sent = support.appendingPathComponent("Sent")
    static let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("rm-clipper")
    static let spool = caches.appendingPathComponent("spool")
}

// MARK: - Fitting a job to the screen

/// 180 x 240 mm: the screen's 3:4, within 0.2% of its size. The same paper is in rmpp.conf.
let screenPage = CGSize(width: 180 / 25.4 * 72, height: 240 / 25.4 * 72)
/// Left 40 pt so the tablet's menu covers nothing, 18 pt on the other sides.
let screenArea = CGRect(x: 40, y: 18, width: screenPage.width - 40 - 18, height: screenPage.height - 36)
let maxEnlarge: CGFloat = 1.25

private struct PageSize: Hashable { let w: Int, h: Int }

private func displaySize(_ p: PDFPage) -> CGSize {
    let b = p.bounds(for: .cropBox)
    return p.rotation % 180 != 0 ? CGSize(width: b.height, height: b.width) : b.size
}

/// Box around everything that is not (nearly) white, in points, from a 72 dpi render.
private func inkBox(_ p: PDFPage) -> CGRect? {
    let size = displaySize(p)
    let w = Int(size.width.rounded()), h = Int(size.height.rounded())
    guard w > 0, h > 0,
          let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    c.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    p.draw(with: .cropBox, to: c)
    guard let data = c.data else { return nil }
    let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
    var x0 = w, y0 = h, x1 = -1, y1 = -1
    for y in 0..<h {
        for x in 0..<w {
            let q = px + (y * w + x) * 4
            if Int(q[0]) + Int(q[1]) + Int(q[2]) < 720 {
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
    }
    return x1 < 0 ? nil : CGRect(x: x0, y: h - 1 - y1, width: x1 - x0 + 1, height: y1 - y0 + 1)
}

/// Puts every page's content into the screen area, pages of one size at one scale, text
/// staying text. Returns nil when nothing needs changing or the PDF cannot be read.
func fitToScreen(_ pdf: Data) -> Data? {
    guard let doc = PDFDocument(data: pdf), doc.pageCount > 0 else { return nil }
    let pages = (0..<doc.pageCount).compactMap { doc.page(at: $0) }
    func key(_ p: PDFPage) -> PageSize {
        let s = displaySize(p)
        return PageSize(w: Int(s.width.rounded()), h: Int(s.height.rounded()))
    }
    var ink: [PageSize: CGRect] = [:]
    for p in pages { if let b = inkBox(p) { ink[key(p)] = ink[key(p)]?.union(b) ?? b } }
    if ink.isEmpty { return nil }
    // Printed on the printer's own paper: already laid out for the screen.
    let fits = pages.allSatisfy {
        let s = displaySize($0)
        return abs(s.width - screenPage.width) < 2 && abs(s.height - screenPage.height) < 2
    } && ink.values.allSatisfy { screenArea.insetBy(dx: -2, dy: -2).contains($0) }
    if fits { return nil }

    let out = NSMutableData()
    var media = CGRect(origin: .zero, size: screenPage)
    guard let consumer = CGDataConsumer(data: out as CFMutableData),
          let c = CGContext(consumer: consumer, mediaBox: &media, nil) else { return nil }
    for p in pages {
        c.beginPDFPage(nil)
        if let box = ink[key(p)] {
            let s = min(screenArea.width / box.width, screenArea.height / box.height, maxEnlarge)
            c.translateBy(x: screenArea.midX - box.midX * s, y: screenArea.maxY - box.maxY * s)
            c.scaleBy(x: s, y: s)
            p.draw(with: .cropBox, to: c)
        }
        c.endPDFPage()
    }
    c.closePDF()
    return out as Data
}

// MARK: - Queue of jobs waiting for the tablet

struct Job {
    let dir: URL
    let file: URL
    var title: String { file.deletingPathExtension().lastPathComponent }
}

enum Outbox {
    private static let fm = FileManager.default

    /// The title becomes the file name and the name on the tablet.
    static func cleanTitle(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\\"").union(.controlCharacters).union(.newlines)
        var t = s.components(separatedBy: bad).joined(separator: " ")
        t = t.split(separator: " ").joined(separator: " ")
        if t.lowercased().hasSuffix(".pdf") { t = String(t.dropLast(4)) }
        while t.hasPrefix(".") { t.removeFirst() }
        while t.utf8.count > 180 { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Print" : t
    }

    /// Job name, or if that says nothing the PDF's own title, or the first heading.
    static func title(job name: String?, pdf: Data) -> String {
        let given = cleanTitle(name ?? "")
        if !generic.contains(given.lowercased()) { return given }
        let doc = PDFDocument(data: pdf)
        let own = cleanTitle(doc?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String ?? "")
        if !generic.contains(own.lowercased()) { return own }
        if let h = doc?.page(at: 0).flatMap(heading) {
            let t = cleanTitle(h)
            if !generic.contains(t.lowercased()) { return t }
        }
        return given
    }
    private static let generic: Set<String> = ["print", "untitled", "ohne titel", "unbenannt"]

    /// The first line or lines in the largest type on the page. Uses line heights, not
    /// PDFPage.attributedString, which logs a warning for every run in a system font.
    private static func heading(_ page: PDFPage) -> String? {
        guard let all = page.selection(for: page.bounds(for: .cropBox)) else { return nil }
        let lines = all.selectionsByLine().compactMap { l -> (text: String, height: CGFloat)? in
            guard let s = l.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  s.filter(\.isLetter).count >= 3 else { return nil }
            return (s, l.bounds(for: page).height)
        }
        guard let top = lines.map(\.height).max(),
              let first = lines.firstIndex(where: { $0.height > top * 0.9 }) else { return nil }
        // Many lines this large means there is no heading: the first line has to do.
        let large = lines[first...].prefix(while: { $0.height > top * 0.9 })
        return String(large.prefix(large.count > 3 ? 1 : 3).map(\.text).joined(separator: " ").prefix(100))
    }

    static func add(_ pdf: Data, title: String) throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let id = f.string(from: Date()) + "-" + UUID().uuidString.prefix(8)
        // Written under a dot name first, so a half-written job is never sent.
        let tmp = Paths.queue.appendingPathComponent(".\(id)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try pdf.write(to: tmp.appendingPathComponent(title + ".pdf"))
        try fm.moveItem(at: tmp, to: Paths.queue.appendingPathComponent(id))
    }

    /// Oldest first.
    static func waiting() -> [Job] { list(Paths.queue) }

    private static func list(_ root: URL) -> [Job] {
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return dirs.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { d in
            let files = (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []
            return files.first { $0.pathExtension == "pdf" }.map { Job(dir: d, file: $0) }
        }
    }

    /// Keeps the 20 newest sent jobs, in case one has to be looked at again.
    static func markSent(_ job: Job) {
        try? fm.createDirectory(at: Paths.sent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.moveItem(at: job.dir, to: Paths.sent.appendingPathComponent(job.dir.lastPathComponent))
        for old in list(Paths.sent).dropLast(20) { try? fm.removeItem(at: old.dir) }
    }

    /// multipart/form-data body with the PDF as `file`.
    static func multipart(_ job: Job, boundary: String) -> Data? {
        guard let pdf = try? Data(contentsOf: job.file) else { return nil }
        var body = Data()
        body.append(Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; "
            + "filename=\"\(cleanTitle(job.title)).pdf\"\r\nContent-Type: application/pdf\r\n\r\n").utf8))
        body.append(pdf)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}

/// When ippeveprinter started this process for a job: queue the job and return the exit
/// status. Otherwise nil.
func acceptPrintJob() -> Int32? {
    let env = ProcessInfo.processInfo.environment
    guard CommandLine.arguments.count == 2, let type = env["CONTENT_TYPE"], env["IPP_JOB_ID"] != nil else { return nil }
    func fail(_ why: String) -> Int32 {
        FileHandle.standardError.write(Data("ERROR: \(why)\n".utf8))
        return 1
    }
    guard type == "application/pdf", let pdf = FileManager.default.contents(atPath: CommandLine.arguments[1]),
          pdf.starts(with: Array("%PDF".utf8)) else { return fail("only PDF jobs are supported") }
    do {
        try Outbox.add(fitToScreen(pdf) ?? pdf, title: Outbox.title(job: env["IPP_JOB_NAME"], pdf: pdf))
        return 0
    } catch { return fail("\(error)") }
}

// MARK: - The printer itself

/// Runs ippeveprinter while the app is open. When it is not running, macOS holds jobs.
final class PrintServer {
    private var process: Process?
    private var stopping = false
    var running: Bool { process?.isRunning ?? false }

    func start() {
        guard !stopping, let conf = Bundle.main.path(forResource: "rmpp", ofType: "conf"),
              let me = Bundle.main.executablePath else { return }
        let keys = Paths.caches.appendingPathComponent("keys")
        for d in [Paths.spool, keys] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        // One left over from an app that was killed would keep the port.
        run("/usr/bin/pkill", ["-f", "ippeveprinter .*\(Paths.spool.path)"], timeout: 3, capture: false)
        // Documents ippeveprinter left behind; they are in the queue or with macOS already.
        for f in (try? FileManager.default.contentsOfDirectory(at: Paths.spool, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: f)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ippeveprinter")
        p.arguments = ["-r", "off", "-n", "localhost", "-p", "8631", "-a", conf, "-c", me,
                       "-d", Paths.spool.path, "-K", keys.path, "reMarkable Paper Pro"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self?.start() }
        }
        do { try p.run(); process = p } catch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.start() }
        }
    }

    func stop() {
        stopping = true
        process?.terminate()
    }
}

// MARK: - Login item

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) -> String {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { return "failed: \(error.localizedDescription)" }
        switch SMAppService.mainApp.status {
        case .enabled: return "on"
        case .requiresApproval: return "needs approval in System Settings > General > Login Items"
        default: return "off"
        }
    }
}
