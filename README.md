# RM-Clipper

A macOS menu bar app for the reMarkable 2 and Paper Pro.

- **Prints** land in `Incoming` on the reMarkable: print from any app, as a PDF fitted to the screen and clear of the menu.
- **Clips** land in the app, ready to copy on the Mac: the page open on the tablet, cropped to the ink.
- **Snippets** land in `Incoming/Snippets` on the reMarkable, one PDF that grows: mark text anywhere on the Mac, press ⌃⌥⌘S, and it is added with its title and source.
- **Colorize** (RM menu) lands the image on the clipboard in `Images` on the reMarkable: grey, filling the screen, wide images turned, ready to be drawn on.

Prints, snippets and images are sent to the Paper Pro; a reMarkable 2 on the same account gets them through reMarkable's own sync. Clips work with both.

<img src="docs/menu.png" width="380" alt="RM-Clipper menu with a preview of the page open on each tablet">

It talks to the tablet directly over SSH, with nothing installed on it. Early stage, tested only on macOS 27 with tablet software 3.29. Not affiliated with reMarkable.

## You need

- macOS 13 or later with the Xcode Command Line Tools (`xcode-select --install`).
- SSH access to the tablet. The reMarkable 2 has it; the Paper Pro needs developer mode (Settings → General → Paper Tablet → Software → Advanced), which **erases the tablet** and shows a warning at every boot.
- The USB web interface switched on in the tablet's storage settings.
- An SSH key at `~/.ssh/id_ed25519` without a passphrase, or loaded in your SSH agent.

## Set up the tablet

Connect it by USB. The root password is on the tablet, in the Copyrights and Licenses page of the Help settings.

Paper Pro (the alias keeps it apart from a reMarkable 2, which has the same USB address):

```sh
cat ~/.ssh/id_ed25519.pub | ssh -o HostKeyAlias=rmpp root@10.11.99.1 'mkdir -p -m 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
ssh -o HostKeyAlias=rmpp root@10.11.99.1 rm-ssh-over-wlan on
```

reMarkable 2: the same two commands without `-o HostKeyAlias=rmpp`.

For prints and snippets, create a folder named "Incoming" at the top level of the Paper Pro, and for Colorize one named "Images".

## Build and run

```sh
git clone https://github.com/octets-eu/rm-clipper.git
cd rm-clipper
./build.sh run       # build and start; allow Local Network access when asked
./printer.sh add     # optional: adds the printer and makes it your default
```

The app looks for the tablet at its last known address and over USB, and searches your local network if it is not there. To set the address yourself: `defaults write local.rm-clipper rmpp.host <ip>` (`rm2.host` for the reMarkable 2), then restart the app.

## Use

- **Clips:** open the RM menu and click a preview to copy it.
- **Prints:** print from any app to "reMarkable Paper Pro".
- **Snippets:** mark text, press ⌃⌥⌘S and let go. macOS asks for Accessibility (RM menu → Permissions) and, for page titles, for Automation the first time you use it in a browser. Your clipboard stays as it was.
- **Synchronize** (⌘R) refreshes the clips, retries waiting prints and, if they have changed, sends the snippets.

Snippets are collected in `Snippets.md`, with a `Snippets.pdf` next to it, in iCloud Drive/Remarkable (Documents/Remarkable without iCloud; `defaults write local.rm-clipper snippetsFile <path>` to change it). You can edit the file: `## date - title`, `> text` and `- source` are what the PDF shows.

## Good to know

- A sleeping tablet is unreachable. Prints wait and are sent when it wakes up. If the app is not running, macOS holds them.
- The printer listens only on your own Mac.
- In Safari, print articles from Reader view; normal pages may come out cut up or incomplete.
- Grey ink cannot be told apart from grey page templates when cropping.
- Snippets replaces the PDF of a document the app uploaded, only while it is closed on the tablet. reMarkable's sync accepts this but logs a warning and sends a small error report each time. If you have written on the document, it is left alone.

## Remove

Run `./printer.sh remove`, untick Start at Login in the RM menu, quit, and delete the folder and `~/Library/Application Support/RM-Clipper`. Take back Accessibility and Automation under System Settings → Privacy & Security. Your snippets stay in their folder.

## License

MIT, see [LICENSE](LICENSE).
