import AppKit

final class ScratchpadWindowController: NSWindowController, NSTextViewDelegate, NSTextFieldDelegate {
    private let store: PadKeyStore
    private let titleField = NSTextField()
    private let textView = NSTextView()
    private let sidebar = NSStackView()
    private let saveLabel = NSTextField(labelWithString: "Saved")
    private var activeNoteID: UUID?
    private var saveWorkItem: DispatchWorkItem?

    init(store: PadKeyStore = .shared) {
        self.store = store

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PadKey Scratchpad"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false

        super.init(window: window)
        configure()
        selectInitialNote()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(with text: String? = nil) {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let title = text.split(separator: "\n").first.map(String.init) ?? "Dictation"
            let note = store.createNote(title: String(title.prefix(72)), body: text)
            select(note)
        } else if activeNoteID == nil {
            selectInitialNote()
        }

        refreshSidebar()
        NSApp.setActivationPolicy(.regular)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        textView.window?.makeFirstResponder(textView)
    }

    @objc private func newNote() {
        let note = store.createNote(title: "Untitled", body: "")
        select(note)
        refreshSidebar()
    }

    private func configure() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = PadKeyTheme.panelBackground.cgColor

        let root = NSStackView()
        root.orientation = .horizontal
        root.spacing = 0
        contentView.addSubview(root)
        root.fillSuperview()

        let sidebarContainer = RoundedView(fillColor: PadKeyTheme.softSurface.withAlphaComponent(0.72), radius: 0)
        sidebarContainer.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.widthAnchor.constraint(equalToConstant: 220).isActive = true

        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 6
        sidebar.edgeInsets = NSEdgeInsets(top: 22, left: 16, bottom: 16, right: 16)
        sidebarContainer.addSubview(sidebar)
        sidebar.fillSuperview()

        let editor = NSStackView()
        editor.orientation = .vertical
        editor.spacing = 12
        editor.edgeInsets = NSEdgeInsets(top: 46, left: 28, bottom: 22, right: 28)

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 10

        titleField.isBordered = false
        titleField.isBezeled = false
        titleField.drawsBackground = false
        titleField.font = .systemFont(ofSize: 22, weight: .bold)
        titleField.textColor = PadKeyTheme.ink
        titleField.delegate = self

        let newButton = HoverButton()
        newButton.title = "New"
        newButton.target = self
        newButton.action = #selector(newNote)
        newButton.normalColor = PadKeyTheme.ink
        newButton.hoverColor = PadKeyTheme.teal
        newButton.contentTintColor = .white
        newButton.translatesAutoresizingMaskIntoConstraints = false
        newButton.widthAnchor.constraint(equalToConstant: 64).isActive = true
        newButton.heightAnchor.constraint(equalToConstant: 30).isActive = true

        saveLabel.font = .systemFont(ofSize: 11, weight: .medium)
        saveLabel.textColor = PadKeyTheme.secondaryInk

        toolbar.addArrangedSubview(titleField)
        toolbar.addArrangedSubview(saveLabel)
        toolbar.addArrangedSubview(NSView())
        toolbar.addArrangedSubview(newButton)

        let textScroll = NSScrollView()
        textScroll.hasVerticalScroller = true
        textScroll.drawsBackground = false
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = PadKeyTheme.ink
        textView.backgroundColor = .clear
        textView.insertionPointColor = PadKeyTheme.amber
        textView.isRichText = false
        textView.allowsUndo = true
        textView.delegate = self
        textView.textContainerInset = NSSize(width: 4, height: 10)
        textScroll.documentView = textView

        editor.addArrangedSubview(toolbar)
        editor.addArrangedSubview(textScroll)
        textScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true

        root.addArrangedSubview(sidebarContainer)
        root.addArrangedSubview(editor)
        sidebarContainer.heightAnchor.constraint(equalTo: root.heightAnchor).isActive = true
    }

    private func selectInitialNote() {
        let note = store.snapshot.notes.first ?? store.createNote()
        select(note)
        refreshSidebar()
    }

    private func select(_ note: ScratchNote) {
        activeNoteID = note.id
        titleField.stringValue = note.title
        textView.string = note.body
        saveLabel.stringValue = "Saved"
    }

    private func refreshSidebar() {
        sidebar.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let heading = NSTextField(labelWithString: "RECENTS")
        heading.font = .systemFont(ofSize: 11, weight: .bold)
        heading.textColor = PadKeyTheme.secondaryInk
        sidebar.addArrangedSubview(heading)

        if store.snapshot.notes.isEmpty {
            let empty = NSTextField(labelWithString: "No notes yet")
            empty.font = .systemFont(ofSize: 13)
            empty.textColor = PadKeyTheme.secondaryInk
            sidebar.addArrangedSubview(empty)
            return
        }

        for note in store.snapshot.notes {
            let button = HoverButton()
            button.title = note.title
            button.alignment = .left
            button.font = .systemFont(ofSize: 13, weight: activeNoteID == note.id ? .semibold : .regular)
            button.normalColor = activeNoteID == note.id ? NSColor.white.withAlphaComponent(0.58) : .clear
            button.hoverColor = NSColor.white.withAlphaComponent(0.42)
            button.target = self
            button.action = #selector(selectNoteFromButton(_:))
            button.identifier = NSUserInterfaceItemIdentifier(note.id.uuidString)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 188).isActive = true
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            sidebar.addArrangedSubview(button)
        }
    }

    @objc private func selectNoteFromButton(_ sender: NSButton) {
        guard
            let rawID = sender.identifier?.rawValue,
            let id = UUID(uuidString: rawID),
            let note = store.snapshot.notes.first(where: { $0.id == id })
        else {
            return
        }

        persistCurrent()
        select(note)
        refreshSidebar()
    }

    func textDidChange(_ notification: Notification) {
        saveLabel.stringValue = "Saving..."
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                self?.persistCurrent()
                self?.saveLabel.stringValue = "Saved"
                self?.refreshSidebar()
            }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }

    func controlTextDidChange(_ obj: Notification) {
        textDidChange(obj)
    }

    private func persistCurrent() {
        guard let activeNoteID else { return }
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeTitle = title.isEmpty ? "Untitled" : title
        store.updateNote(id: activeNoteID, title: safeTitle, body: textView.string)
    }
}
