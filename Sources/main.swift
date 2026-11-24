// RM-Clipper: menu bar app that shows the page open on each reMarkable tablet,
// cropped to the ink, and copies it to the clipboard on click. The tablets and
// everything specific to them are in Devices.swift.
//
// Pipeline (see HANDOVER.md): one persistent SSH connection -> cheap change
// signature every few seconds -> PDF export through the tablet's own web
// interface (fetched with wget on the tablet, streamed over SSH) -> PDFKit
// render -> Core Graphics crop -> pasteboard. No Homebrew tools needed.

import AppKit
import PDFKit

// MARK: - Settings (no UI; change with `defaults write local.rm-clipper <key> <value>`)

enum Settings {
    static let defaults = UserDefaults.standard
    /// Seconds between polls.
    static var pollSeconds: Double {
        let v = defaults.double(forKey: "pollSeconds")
        return v >= 1 ? v : 3
    }
    /// Last address a tablet was found at, e.g. key "rmpp.host".
    static func host(_ d: Device) -> String? { defaults.string(forKey: "\(d.key).host") }
    static func setHost(_ h: String, _ d: Device) { defaults.set(h, forKey: "\(d.key).host") }
    /// Last document seen open on a tablet, so it stays current on the home screen.
    static func lastDocument(_ d: Device) -> String {
        let s = defaults.string(forKey: "\(d.key).lastDocument") ?? ""
        return s.allSatisfy { $0.isHexDigit || $0 == "-" } ? s : ""
    }
    static func setLastDocument(_ u: String, _ d: Device) { defaults.set(u, forKey: "\(d.key).lastDocument") }
}

let usbHost = "10.11.99.1"
let confFile = "/home/root/.config/remarkable/xochitl.conf"
let dataDir = "/home/root/.local/share/remarkable/xochitl"
let inkThreshold = 89 * 3     // 35% luminance, summed over r+g+b
let inkChroma = 40            // coloured ink: max - min of r, g, b; page templates are grey (0)
let cropMargin = 24           // px around the ink

// MARK: - Subprocess helper

/// Runs a tool and returns its exit status and stdout. stdin and stderr go to
/// /dev/null so a backgrounded ssh can never hold a pipe open.
@discardableResult
func run(_ exe: String, _ args: [String], timeout: Double, capture: Bool = true, input: FileHandle? = nil) -> (status: Int32, out: Data) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.standardInput = input ?? FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    let pipe = Pipe()
    p.standardOutput = capture ? pipe : FileHandle.nullDevice
    do { try p.run() } catch { return (-1, Data()) }
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let out = capture ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
    p.waitUntilExit()
    killer.cancel()
    return (p.terminationStatus, out)
}

// MARK: - Network probing

/// Returns the hosts that accept a TCP connection on `port` within `timeout`.
func openHosts(_ hosts: [String], port: UInt16 = 22, timeout: Double) -> [String] {
    var fds: [pollfd] = []
    var names: [String] = []
    for h in hosts {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, h, &addr.sin_addr) == 1 else { continue }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { continue }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 || errno == EINPROGRESS {
            fds.append(pollfd(fd: fd, events: Int16(POLLOUT), revents: 0))
            names.append(h)
        } else {
            close(fd)
        }
    }
    var open: [String] = []
    var done = Set<Int>()
    let deadline = Date().addingTimeInterval(timeout)
    while done.count < fds.count {
        let left = deadline.timeIntervalSinceNow
        if left <= 0 { break }
        var pending = fds.enumerated().filter { !done.contains($0.offset) }.map { $0.element }
        let idx = fds.indices.filter { !done.contains($0) }
        let n = poll(&pending, nfds_t(pending.count), Int32(left * 1000))
        if n <= 0 { break }
        for (k, pf) in pending.enumerated() where pf.revents != 0 {
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(pf.fd, SOL_SOCKET, SO_ERROR, &err, &len)
            if err == 0 && pf.revents & Int16(POLLOUT) != 0 { open.append(names[idx[k]]) }
            done.insert(idx[k])
        }
    }
    for pf in fds { close(pf.fd) }
    return open
}

/// All addresses of the /24 networks this Mac is on (Wi-Fi/Ethernet), minus its own.
func localSubnetHosts() -> [String] {
    var result: [String] = []
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0 else { return [] }
    defer { freeifaddrs(ifap) }
    var cur = ifap
    while let i = cur {
        defer { cur = i.pointee.ifa_next }
        let flags = Int32(i.pointee.ifa_flags)
        guard let sa = i.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
              flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
              String(cString: i.pointee.ifa_name).hasPrefix("en") else { continue }
        var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
        let own = String(cString: buf)
        let parts = own.split(separator: ".")
        guard parts.count == 4, !own.hasPrefix("10.11.99."), !own.hasPrefix("169.254.") else { continue }
        let prefix = parts[0...2].joined(separator: ".")
        for n in 1...254 where "\(prefix).\(n)" != own { result.append("\(prefix).\(n)") }
    }
    return result
}

// MARK: - Image work

struct Clip {
    let image: NSImage
    let png: Data
    let pixels: CGSize
    let cropped: Bool
}

@inline(__always)
func isInk(_ r: Int, _ g: Int, _ b: Int, colour: Bool) -> Bool {
    r + g + b < inkThreshold || (colour && max(r, g, b) - min(r, g, b) > inkChroma)
}

/// Renders one page of the exported PDF at native resolution and crops it to the ink.
func makeClip(pdf: Data, pageIndex: Int, device: Device) -> Clip? {
    guard let doc = PDFDocument(data: pdf), doc.pageCount > 0,
          let page = doc.page(at: min(max(pageIndex, 0), doc.pageCount - 1)) else { return nil }
    let box = page.bounds(for: .mediaBox)
    let scale = device.dpi / 72
    let rotated = page.rotation % 180 != 0
    let w = Int(((rotated ? box.height : box.width) * scale).rounded())
    let h = Int(((rotated ? box.width : box.height) * scale).rounded())
    guard w > 0, h > 0,
          let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: ctx)
    guard let data = ctx.data, let full = ctx.makeImage() else { return nil }

    // Ink is near-black (or coloured, on a colour tablet) and page templates are
    // grey: bounding box of the ink pixels.
    let colour = device.hasColour
    let bpr = ctx.bytesPerRow
    let px = data.bindMemory(to: UInt8.self, capacity: bpr * h)
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h {
        let row = px + y * bpr
        var first = -1, last = -1
        for x in 0..<w {
            let p = row + x * 4
            if isInk(Int(p[0]), Int(p[1]), Int(p[2]), colour: colour) {
                if first < 0 { first = x }
                last = x
            }
        }
        if first >= 0 {
            if first < minX { minX = first }
            if last > maxX { maxX = last }
            if y < minY { minY = y }
            maxY = y
        }
    }

    var out = full
    var cropped = false
    if maxX > minX && maxY > minY {
        let x0 = max(minX - cropMargin, 0), y0 = max(minY - cropMargin, 0)
        let x1 = min(maxX + cropMargin, w - 1), y1 = min(maxY + cropMargin, h - 1)
        if let c = full.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)) {
            out = c
            cropped = true
        }
    }
    let rep = NSBitmapImageRep(cgImage: out)
    guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
    let size = CGSize(width: out.width, height: out.height)
    return Clip(image: NSImage(cgImage: out, size: size), png: png, pixels: size, cropped: cropped)
}

// MARK: - Tablet connection and polling (runs on its own serial queue)

struct Signature: Equatable {
    var uuid = ""
    var page = 0
    var name = ""
    var mtimes = ""
}

final class Tablet {
    let device: Device
    let queue: DispatchQueue
    let ssh = "/usr/bin/ssh"
    private let sock: String
    var host: String?
    private var timer: DispatchSourceTimer?
    private var exported: Signature?
    private var pending: Signature?
    private var misses = 0

    /// Called on the main queue.
    var onFound: ((Bool, String?) -> Void)?
    var onClip: ((Clip, Signature) -> Void)?
    var onBusy: ((Bool) -> Void)?
    var onPrint: ((String) -> Void)?
    private var nextSend = Date.distantPast
    var nextSnippets = Date.distantPast
    private let webSock: String

    init(_ device: Device) {
        self.device = device
        queue = DispatchQueue(label: "rm-clipper.\(device.key)")
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("rm-clipper")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sock = dir.appendingPathComponent("\(device.key).sock").path
        webSock = dir.appendingPathComponent("\(device.key)-web.sock").path
    }

    func start() {
        queue.async {
            self.stopMaster()   // clear a master left over from a previous run
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: Settings.pollSeconds, leeway: .milliseconds(300))
            t.setEventHandler { self.poll(force: false) }
            t.resume()
            self.timer = t
        }
    }

    /// Reads the open page again and sends what is waiting, without delay.
    func synchronize() {
        queue.async {
            self.nextSend = .distantPast
            self.nextSnippets = .distantPast
            self.poll(force: true)
        }
    }

    func shutdown() { queue.sync { self.stopMaster() } }

    // The saved host key identifies the tablet at any address, so a changed DHCP
    // lease is still verified and other machines (or the other tablet) are rejected.
    var base: [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=4", "-o", "StrictHostKeyChecking=yes",
         "-o", "HostKeyAlias=\(device.hostKeyAlias)"] + device.sshIdentity + ["-S", sock]
    }

    private func masterAlive(_ h: String) -> Bool {
        run(ssh, base + ["-O", "check", "root@\(h)"], timeout: 3, capture: false).status == 0
    }

    private func startMaster(_ h: String) -> Bool {
        let args = base + ["-M", "-N", "-f", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
                           "root@\(h)"]
        return run(ssh, args, timeout: 8, capture: false).status == 0
    }

    private func stopMaster() {
        if FileManager.default.fileExists(atPath: sock) {
            run(ssh, base + ["-O", "exit", "root@\(host ?? usbHost)"], timeout: 3, capture: false)
            try? FileManager.default.removeItem(atPath: sock)
        }
    }

    func remote(_ cmd: String, timeout: Double) -> Data? {
        guard let h = host else { return nil }
        let r = run(ssh, base + ["root@\(h)", cmd], timeout: timeout)
        return r.status == 0 ? r.out : nil
    }

    // MARK: Print jobs

    /// Sends waiting jobs, prints to the inbox folder, images to theirs. Runs on the tablet's queue.
    private func sendWaiting() {
        guard let inbox = device.inbox, host != nil, Date() >= nextSend else { return }
        let jobs = Outbox.waiting()
        guard !jobs.isEmpty else { return }
        func report(_ s: String) { DispatchQueue.main.async { self.onPrint?(s) } }
        let ok = withWebInterface {
            var ids: [String: String?] = [:]
            for var job in jobs {
                let name = job.folder ?? inbox
                let id = ids[name] ?? folderID(name)
                ids[name] = .some(id)
                // Images get their number when they are sent.
                var number: Int?
                if job.folder != nil {
                    number = nextColorize()
                    guard let n = number, let j = try? job.renamed(String(format: "\(Colorize.name) %02d", n)) else {
                        report("Image waiting: no answer from the \(device.name)")
                        nextSend = Date().addingTimeInterval(30)
                        return
                    }
                    job = j
                }
                guard upload(job, folder: id) else {
                    report("\(number == nil ? "Print" : "Image") waiting: upload failed, USB web interface off?")
                    nextSend = Date().addingTimeInterval(30)
                    return
                }
                if let n = number { Colorize.given(n) }
                Outbox.markSent(job)
                report("Sent \"\(job.title)\" to \(id == nil ? "My files (no \(name) folder)" : name)")
            }
        }
        if !ok { nextSend = Date().addingTimeInterval(30) }
    }

    /// The web interface listens only on the tablet itself; reach it over our connection.
    @discardableResult
    func withWebInterface(_ body: () -> Void) -> Bool {
        guard let h = host else { return false }
        try? FileManager.default.removeItem(atPath: webSock)
        let forward = ["-L", "\(webSock):\(usbHost):80", "root@\(h)"]
        guard run(ssh, base + ["-O", "forward"] + forward, timeout: 5, capture: false).status == 0 else { return false }
        defer {
            run(ssh, base + ["-O", "cancel"] + forward, timeout: 5, capture: false)
            try? FileManager.default.removeItem(atPath: webSock)
        }
        body()
        return true
    }

    /// The tablet stores an upload in the folder that was listed last.
    func upload(_ job: Job, folder: String?) -> Bool {
        func curl(_ args: [String], timeout: Int) -> String {
            let r = run("/usr/bin/curl", ["-s", "-m", String(timeout), "--unix-socket", webSock, "-o", "/dev/null",
                                          "-w", "%{http_code}"] + args, timeout: Double(timeout) + 5)
            return r.status == 0 ? String(decoding: r.out, as: UTF8.self) : ""
        }
        let boundary = "rm-clipper-" + UUID().uuidString
        let body = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(boundary)
        defer { try? FileManager.default.removeItem(at: body) }
        guard let data = Outbox.multipart(job, boundary: boundary), (try? data.write(to: body)) != nil,
              curl(["http://\(usbHost)/documents/\(folder ?? "")"], timeout: 30) == "200" else { return false }
        return curl(["-H", "Content-Type: multipart/form-data; boundary=\(boundary)", "--data-binary",
                     "@\(body.path)", "http://\(usbHost)/upload"], timeout: 180) == "201"
    }

    /// UUID of a top-level folder, or nil if the tablet has none of that name.
    func folderID(_ name: String) -> String? {
        let script = #"""
        cd \#(dataDir) || exit 1
        for f in $(grep -l '"type": *"CollectionType"' *.metadata); do
          grep -q '"visibleName": *"\#(name)"' "$f" && grep -q '"parent": *""' "$f" && ! grep -q '"deleted": *true' "$f" && echo "${f%.metadata}" && break
        done
        """#
        guard let out = remote(script, timeout: 8) else { return nil }
        let id = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return !id.isEmpty && id.allSatisfy({ $0.isHexDigit || $0 == "-" }) ? id : nil
    }

    /// Known addresses first; every tenth miss, scan the local subnet for the tablet's host key.
    private func discover() -> String? {
        var candidates: [String] = []
        for h in [Settings.host(device), usbHost] {
            if let h, !candidates.contains(h) { candidates.append(h) }
        }
        let up = openHosts(candidates, timeout: 1.5)
        for h in candidates where up.contains(h) {
            if startMaster(h) { return h }
        }
        defer { misses += 1 }
        guard misses % 10 == 0 else { return nil }
        let others = localSubnetHosts().filter { !candidates.contains($0) }
        for h in openHosts(others, timeout: 1.5) {
            if startMaster(h) {
                Settings.setHost(h, device)
                return h
            }
            stopMaster()
        }
        return nil
    }

    private func lost() {
        stopMaster()
        host = nil
        pending = nil
        DispatchQueue.main.async { self.onFound?(false, nil) }
    }

    /// What is open on the tablet; an empty uuid means no document is known to be open.
    /// `LastOpen` in xochitl.conf names the open document and is empty on the home screen.
    /// It is local to the tablet. The .metadata files are not: cloud sync rewrites those of
    /// documents changed elsewhere, so the newest one is only used if there is no LastOpen.
    private func signature() -> Signature? {
        let script = #"""
        cd \#(dataDir) || exit 1
        if grep -q '^LastOpen=' \#(confFile) 2>/dev/null; then
          u=$(sed -n 's/^LastOpen=@ByteArray(\([0-9a-f-]*\)).*/\1/p' \#(confFile) | head -n 1)
          [ -n "$u" ] && [ -f "$u.metadata" ] || u='\#(Settings.lastDocument(device))'
          [ -n "$u" ] && [ -f "$u.metadata" ] || { echo "U="; exit 0; }
        else
          f=$(ls -t *.metadata | head -n 1); u=${f%.metadata}
          [ -n "$u" ] || exit 1
        fi
        f="$u.metadata"
        echo "U=$u"
        echo "P=$(grep -o '"lastOpenedPage": *[-0-9]*' "$f" | grep -o '[-0-9]*$')"
        echo "N=$(grep -o '"visibleName": *"[^"]*"' "$f" | sed 's/.*: *"//; s/"$//')"
        r=$(ls -t "$u"/*.rm 2>/dev/null | head -n 1)
        echo "M=$(stat -c %Y "$f" "$u.content" $r 2>/dev/null | tr '\n' ' ')"
        """#
        guard let out = remote(script, timeout: 8), let text = String(data: out, encoding: .utf8) else { return nil }
        var s = Signature()
        for line in text.split(separator: "\n") {
            let v = String(line.dropFirst(2))
            if line.hasPrefix("U=") { s.uuid = v }
            else if line.hasPrefix("P=") { s.page = max(Int(v) ?? 0, 0) }
            else if line.hasPrefix("N=") { s.name = v }
            else if line.hasPrefix("M=") { s.mtimes = v }
        }
        guard s.uuid.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        if !s.uuid.isEmpty { Settings.setLastDocument(s.uuid, device) }
        return s
    }

    func poll(force: Bool) {
        if let h = host, !masterAlive(h) { stopMaster(); host = nil }
        if host == nil {
            host = discover()
            guard host != nil else { lost(); return }
            misses = 0
        }
        guard let sig = signature() else { lost(); return }
        let h = host
        DispatchQueue.main.async { self.onFound?(true, h) }
        sendWaiting()
        sendSnippets()
        if sig.uuid.isEmpty { pending = nil; return }

        if !force, sig == exported { pending = nil; return }
        // While the pen is moving the .rm file changes every few seconds: wait until
        // it has been the same for two polls. Page or document changes go at once.
        let samePage = exported.map { $0.uuid == sig.uuid && $0.page == sig.page } ?? false
        if !force, samePage, sig != pending { pending = sig; return }
        pending = nil

        DispatchQueue.main.async { self.onBusy?(true) }
        defer { DispatchQueue.main.async { self.onBusy?(false) } }
        guard let pdf = remote("wget -q -O - http://\(usbHost)/download/\(sig.uuid)/pdf", timeout: 180),
              pdf.starts(with: Array("%PDF".utf8)),
              let clip = makeClip(pdf: pdf, pageIndex: sig.page, device: device) else { return }
        exported = sig
        DispatchQueue.main.async { self.onClip?(clip, sig) }
    }
}

// MARK: - Preview shown inside the menu

final class PreviewView: NSView {
    static let width: CGFloat = 320
    static let pad: CGFloat = 12
    static let maxImageHeight: CGFloat = 420

    var image: NSImage? { didSet { layoutForImage() } }
    var placeholder = "Looking for the tablet…" { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var hover = false { didSet { needsDisplay = true } }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 64))
    }
    required init?(coder: NSCoder) { fatalError() }

    private func imageSize() -> NSSize? {
        guard let i = image, i.size.width > 0, i.size.height > 0 else { return nil }
        // Cap at 0.5 so small crops stay crisp on a Retina display instead of being blown up.
        let s = min((bounds.width - 2 * Self.pad) / i.size.width, Self.maxImageHeight / i.size.height, 0.5)
        return NSSize(width: (i.size.width * s).rounded(), height: (i.size.height * s).rounded())
    }

    private func layoutForImage() { fit(width: bounds.width) }

    /// Sizes the view for a menu of the given width, so the image fills it edge to edge.
    func fit(width: CGFloat) {
        setFrameSize(NSSize(width: width, height: bounds.height))
        let h = imageSize().map { $0.height + 2 * Self.pad } ?? 64
        setFrameSize(NSSize(width: width, height: h))
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func viewDidMoveToWindow() { hover = false }

    override func mouseUp(with event: NSEvent) {
        guard image != nil else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let i = image, let size = imageSize() else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.menuFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]
            let s = NSAttributedString(string: placeholder, attributes: attrs)
            let sz = s.size()
            s.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2))
            return
        }
        let r = NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: Self.pad,
                       width: size.width, height: size.height)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        NSColor.white.setFill()
        path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        i.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let border = NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: -1), xRadius: 7, yRadius: 7)
        border.lineWidth = hover ? 3 : 1
        (hover ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        border.stroke()
    }
}

// MARK: - App

/// One tablet's part of the menu: name, preview and status line.
final class Section {
    let tablet: Tablet
    let preview = PreviewView()
    let previewItem = NSMenuItem()
    let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let info = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var clip: Clip?
    var caption = ""
    var found = false
    var busy = false
    var onChange: (() -> Void)?

    init(_ device: Device) {
        tablet = Tablet(device)
        header.title = device.name
        header.isEnabled = false
        info.isEnabled = false
        previewItem.view = preview
        tablet.onFound = { [weak self] found, _ in self?.found = found; self?.refresh() }
        tablet.onBusy = { [weak self] busy in self?.busy = busy; self?.refresh() }
        tablet.onClip = { [weak self] clip, sig in
            guard let self else { return }
            self.clip = clip
            self.caption = "\(sig.name), page \(sig.page + 1) · \(Int(clip.pixels.width))×\(Int(clip.pixels.height))"
                + (clip.cropped ? "" : " (no ink, full page)")
            self.preview.image = clip.image
            self.refresh()
        }
        refresh()
    }

    func refresh() {
        var parts: [String] = []
        if clip != nil { parts.append(caption) }
        if busy { parts.append("updating…") }
        else if !found { parts.append(clip == nil ? "not connected" : "tablet asleep, last page kept") }
        else { parts.append(clip == nil ? "open a document on the tablet" : "click image to copy") }
        info.title = parts.joined(separator: " — ")
        previewItem.isHidden = clip == nil
        onChange?()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let sections = Device.all.map { Section($0) }
    private let printer = PrintServer()
    private let capture = SnippetCapture()
    private let snippetHeader = NSMenuItem(title: "Snippets: mark text, press ⌃⌥⌘S", action: nil, keyEquivalent: "")
    private let colorize = NSMenuItem(title: "Colorize", action: #selector(colorizeClipboard), keyEquivalent: "")
    private let sync = NSMenuItem(title: "Synchronize", action: #selector(synchronize), keyEquivalent: "r")
    private let permissions = NSMenu()
    private let printInfo = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private var lastPrint = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        item.button?.title = "RM"
        let menu = NSMenu()
        menu.autoenablesItems = false
        for s in sections {
            menu.addItem(s.header)
            menu.addItem(s.previewItem)
            menu.addItem(s.info)
            menu.addItem(.separator())
            s.preview.onClick = { [weak self, weak s] in if let c = s?.clip { self?.copy(c) } }
            s.onChange = { [weak self] in self?.refreshTitle() }
            s.tablet.onPrint = { [weak self] text in self?.lastPrint = text; self?.refreshPrint() }
        }
        snippetHeader.isEnabled = false
        menu.addItem(snippetHeader)
        let show = NSMenuItem(title: "Show snippets.md in finder", action: #selector(showSnippets), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        colorize.target = self
        menu.addItem(colorize)
        menu.addItem(.separator())
        printInfo.isEnabled = false
        menu.addItem(printInfo)
        menu.addItem(.separator())
        sync.target = self
        menu.addItem(sync)
        login.target = self
        menu.addItem(login)
        let perm = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
        perm.submenu = permissions
        permissions.autoenablesItems = false
        menu.addItem(perm)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        item.menu = menu
        refreshTitle()
        refreshPrint()
        capture.onSaved = { [weak self] in self?.flash("RM +1") }
        if !capture.install() { snippetHeader.title = "Snippets: ⌃⌥⌘S is taken by another app" }
        printer.start()
        sections.forEach { $0.tablet.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        printer.stop()
        sections.forEach { $0.tablet.shutdown() }
    }

    private func refreshPrint() {
        let jobs = Outbox.waiting(), n = jobs.count
        let images = jobs.filter { $0.folder != nil }.count
        let kind = images == 0 ? "print" : images == n ? "image" : "document"
        if n > 0, !lastPrint.hasPrefix("Print waiting"), !lastPrint.hasPrefix("Image waiting") { printInfo.title = "\(n) \(kind)\(n == 1 ? "" : "s") waiting for the Paper Pro" }
        else if !lastPrint.isEmpty { printInfo.title = lastPrint }
        else { printInfo.title = printer.running ? "Printer ready" : "Printer starting…" }
    }

    @objc private func toggleLogin() {
        let result = LoginItem.set(!LoginItem.enabled)
        if result.hasPrefix("failed") || result.hasPrefix("needs") { lastPrint = "Start at Login: \(result)"; refreshPrint() }
    }

    /// White when any tablet is found, grey when none.
    private func refreshTitle() { item.button?.appearsDisabled = !sections.contains { $0.found } }

    /// The text items can make the menu wider than the previews; widen them to match.
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshPrint()
        refreshSnippets()
        colorize.isEnabled = Colorize.hasImage(.general)
        login.state = LoginItem.enabled ? .on : .off
        sections.forEach { $0.preview.fit(width: PreviewView.width) }
        let w = max(PreviewView.width, menu.size.width)
        sections.forEach { $0.preview.fit(width: w) }
    }

    /// Previews of all tablets, waiting prints, and the snippets if they have changed.
    @objc private func synchronize() {
        if Snippets.news != nil, sections.contains(where: { $0.tablet.device.inbox != nil }) {
            Snippets.pending = true
            lastPrint = "Snippets: sending when the Paper Pro is reachable"
            refreshPrint()
        }
        sections.forEach { $0.tablet.synchronize() }
    }

    private func copy(_ clip: Clip) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(clip.png, forType: .png)
        if let tiff = clip.image.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        flash("RM ✓")
    }

    /// The image on the clipboard, grey and in screen size, into the Paper Pro's image folder.
    @objc private func colorizeClipboard() {
        guard let folder = Device.all.lazy.compactMap(\.images).first else { return }
        func say(_ s: String) { lastPrint = s; refreshPrint() }
        guard let src = Colorize.source(.general) else { say("Colorize: no image on the clipboard"); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let pdf = Colorize.pdf(src)
            let ok = pdf.map { (try? Outbox.add($0, title: Colorize.name, folder: folder)) != nil }
            DispatchQueue.main.async {
                if ok == nil { say("Colorize: the image could not be read") }
                else if ok == false { say("Colorize: the image could not be queued") }
                else { self.lastPrint = ""; self.refreshPrint(); self.flash("RM ✓") }
            }
        }
    }

    private func flash(_ title: String) {
        item.button?.title = title
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.item.button?.title = "RM" }
    }

    // MARK: Snippets and permissions

    private func refreshSnippets() {
        sync.title = Snippets.pending ? "Synchronize (snippets waiting)" : Snippets.news.map { "Synchronize (\($0))" } ?? "Synchronize"
        permissions.removeAllItems()
        func add(_ title: String, _ ok: Bool?, _ action: Selector) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.state = ok == true ? .on : .off
            permissions.addItem(i)
        }
        add(AXIsProcessTrusted() ? "Accessibility" : "Accessibility: allow, to read marked text…", AXIsProcessTrusted(), #selector(openAccessibility))
        let browsers = NSWorkspace.shared.runningApplications.compactMap { a -> (String, String)? in
            guard let b = a.bundleIdentifier, Reader.safariLike.contains(b) || Reader.chromeLike.contains(b) else { return nil }
            return (b, a.localizedName ?? b)
        }
        for (b, name) in browsers {
            let ok = Permission.automation(b)
            add("Automation, \(name)" + (ok == true ? "" : ok == false ? ": not allowed, for page titles…" : ": asked at the first snippet"), ok, #selector(openAutomation))
        }
        if browsers.isEmpty { add("Automation: asked at the first snippet in a browser", nil, #selector(openAutomation)) }
        let network = sections.contains { $0.found }
        add(network ? "Local Network" : "Local Network: no tablet reached yet…", network, #selector(openLocalNetwork))
    }

    @objc private func openAccessibility() { Permission.accessibility() }
    @objc private func openAutomation() { Permission.settings("Privacy_Automation") }
    @objc private func openLocalNetwork() { Permission.settings("Privacy_LocalNetwork") }

    @objc private func showSnippets() {
        let f = Snippets.file
        let target = FileManager.default.fileExists(atPath: f.path) ? f : f.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}

// `--render rm2|rmpp in.pdf pageIndex out.png` runs only the render and crop step (for testing).
if CommandLine.arguments.count == 6, CommandLine.arguments[1] == "--render" {
    let a = CommandLine.arguments
    guard let device = Device.all.first(where: { $0.key == a[2] }),
          let pdf = FileManager.default.contents(atPath: a[3]),
          let clip = makeClip(pdf: pdf, pageIndex: Int(a[4]) ?? 0, device: device) else { exit(1) }
    try? clip.png.write(to: URL(fileURLWithPath: a[5]))
    print("\(Int(clip.pixels.width))x\(Int(clip.pixels.height)) cropped=\(clip.cropped)")
    exit(0)
}

if let status = acceptPrintJob() { exit(status) }

// `--fit in.pdf out.pdf` runs only the page fitting, `--login on|off` sets the login item.
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--fit" {
    guard let pdf = FileManager.default.contents(atPath: CommandLine.arguments[2]) else { exit(1) }
    let out = fitToScreen(pdf)
    print(out == nil ? "unchanged" : "fitted", "- title:", Outbox.title(job: nil, pdf: pdf))
    try? (out ?? pdf).write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
    exit(0)
}
// `--snippets in.md out.pdf` runs only the rendering of the snippets.
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--snippets" {
    guard let md = try? String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8),
          let r = SnippetPDF.render(Snippets.parse(md)) else { exit(1) }
    try? r.pdf.write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
    print("\(r.pages) pages")
    exit(0)
}
// `--colorize in.png out.pdf` runs only the conversion for Colorize.
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--colorize" {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL, nil),
          let pdf = Colorize.pdf(src) else { exit(1) }
    try? pdf.write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
    exit(0)
}
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--login" {
    print(LoginItem.set(CommandLine.arguments[2] == "on"))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
// Quit cleanly on `pkill` too, so the SSH connection is closed.
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler { app.terminate(nil) }
sigterm.resume()
app.run()
