// The tablets RM-Clipper knows, and everything specific to each of them.

import Foundation

struct Device {
    /// Short name for settings, sockets and `--render`.
    let key: String
    let name: String
    /// Name the tablet's host key is saved under in known_hosts. Both tablets have the
    /// same USB address, so the Paper Pro's is saved under an alias.
    let hostKeyAlias: String
    let sshIdentity: [String]
    let dpi: CGFloat
    let hasColour: Bool
    /// Folder on the tablet that print jobs are sent to, or nil if it takes none.
    let inbox: String?
    /// Folder on the tablet that Colorize sends images to, or nil if it takes none.
    let images: String?

    static let all = [rm2, paperPro]

    static let rm2 = Device(
        key: "rm2", name: "reMarkable 2", hostKeyAlias: "10.11.99.1",
        sshIdentity: [], dpi: 226, hasColour: false, inbox: nil, images: nil)

    static let paperPro = Device(
        key: "rmpp", name: "Paper Pro", hostKeyAlias: "rmpp",
        sshIdentity: ["-o", "IdentityFile=~/.ssh/id_ed25519", "-o", "IdentitiesOnly=yes"],
        dpi: 227 /* a notebook page renders at the screen's 1620 x 2160 */, hasColour: true,
        inbox: "Incoming", images: "Images")
}
