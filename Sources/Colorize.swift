// Colorize: the image on the clipboard as one grey page in the size of the Paper Pro's
// screen, sent to its "Images" folder as "Colorize 01", "Colorize 02" and so on. It is a
// PDF, so the tablet keeps ink on layers above it.

import AppKit
import ImageIO
import UniformTypeIdentifiers

enum Colorize {
    /// Name on the tablet, before the number.
    static let name = "Colorize"
    /// The Paper Pro's screen, upright.
    static let width = 1620, height = 2160

    private static let types: [NSPasteboard.PasteboardType] =
        [.png, .tiff] + ["public.jpeg", "public.heic", "org.webmproject.webp", "com.compuserve.gif"].map { .init($0) }

    /// An image file copied in Finder.
    private static func copiedFile(_ pb: NSPasteboard) -> URL? {
        (pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL])?.first
    }
    /// Image data. Not looked for next to a copied file, where it may be the file's icon.
    private static func dataType(_ pb: NSPasteboard) -> NSPasteboard.PasteboardType? {
        pb.types?.contains(.fileURL) == true ? nil : pb.availableType(from: types)
    }
    static func hasImage(_ pb: NSPasteboard) -> Bool { copiedFile(pb) != nil || dataType(pb) != nil }

    static func source(_ pb: NSPasteboard) -> CGImageSource? {
        if let f = copiedFile(pb) { return CGImageSourceCreateWithURL(f as CFURL, nil) }
        return dataType(pb).flatMap { pb.data(forType: $0) }.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
    }

    /// The image upright, as its orientation tag says.
    private static func image(_ s: CGImageSource) -> CGImage? {
        guard let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(s, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h)] as [CFString: Any] as CFDictionary)
    }

    /// Grey, scaled to fill the screen and cropped evenly. A wide image is turned, so that
    /// it fills the screen when the tablet is held sideways (its top is at the left edge).
    static func grey(_ img: CGImage) -> CGImage? {
        guard let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        c.setFillColor(gray: 1, alpha: 1)
        c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        c.interpolationQuality = .high
        var area = CGSize(width: width, height: height)
        if img.width > img.height {
            c.translateBy(x: area.width, y: 0)
            c.rotate(by: .pi / 2)
            area = CGSize(width: height, height: width)
        }
        let s = max(area.width / CGFloat(img.width), area.height / CGFloat(img.height))
        let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
        c.draw(img, in: CGRect(x: (area.width - w) / 2, y: (area.height - h) / 2, width: w, height: h))
        return c.makeImage()
    }

    /// One page with the image pixel for pixel on it.
    static func pdf(_ s: CGImageSource) -> Data? {
        guard let img = image(s), let page = grey(img) else { return nil }
        let out = NSMutableData()
        var media = CGRect(origin: .zero, size: screenPage)
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let c = CGContext(consumer: consumer, mediaBox: &media, [kCGPDFContextTitle as String: name] as CFDictionary) else { return nil }
        c.beginPDFPage(nil)
        c.interpolationQuality = .none
        c.draw(page, in: media)
        c.endPDFPage()
        c.closePDF()
        return out as Data
    }

    /// Highest number given so far, so a number is not given twice before the tablet lists it.
    private static var last: Int {
        get { Settings.defaults.integer(forKey: "colorize.last") }
        set { Settings.defaults.set(newValue, forKey: "colorize.last") }
    }
    static func next(after onTablet: Int) -> Int { max(onTablet, last) + 1 }
    static func given(_ n: Int) { last = max(last, n) }
}

extension Tablet {
    /// The number for the next image, or nil if the tablet could not be asked.
    func nextColorize() -> Int? {
        let script = #"""
        cd \#(dataDir) || exit 1
        grep -h -o '"visibleName": *"\#(Colorize.name) [0-9]*"' *.metadata | grep -o '[0-9]*"$' | tr -d '"' | sort -n | tail -n 1
        """#
        guard let out = remote(script, timeout: 8) else { return nil }
        return Colorize.next(after: Int(String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
    }
}
