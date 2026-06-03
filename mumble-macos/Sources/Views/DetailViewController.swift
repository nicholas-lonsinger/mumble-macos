import AppKit

/// Detail pane of the main window: the status banner on top, then either
/// the server welcome text or a state-dependent placeholder.
///
/// This controller's tracker deliberately never reads `client.channels`,
/// `client.users`, or `client.speakingSessions` — channel-tree churn and
/// per-voice-packet speaking updates re-render only the sidebar. The two
/// panes are independent by construction.
@MainActor
final class DetailViewController: NSViewController {
    private let client: MumbleClient
    private var tracker: ObservationTracker?

    private let banner: StatusBannerView
    private var welcomeScroll: NSScrollView!
    private var welcomeTextView: NSTextView!
    private let placeholderLabel = NSTextField(wrappingLabelWithString: "")

    /// Cache key for the welcome parse. The HTML/libtidy pipeline is
    /// expensive; re-run it only when the server text actually changes
    /// (ports the SwiftUI WelcomeTextView's @State cache).
    private var lastWelcomeInput: String?

    init(client: MumbleClient) {
        self.client = client
        self.banner = StatusBannerView(
            onToggleMute: { Task { await client.toggleSelfMute() } },
            onToggleDeafen: { Task { await client.toggleSelfDeaf() } }
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DetailViewController does not support NSCoding")
    }

    // MARK: - View construction

    override func loadView() {
        let root = NSView()

        welcomeTextView = NSTextView()
        welcomeTextView.isEditable = false
        welcomeTextView.isSelectable = true
        welcomeTextView.drawsBackground = false
        welcomeTextView.textContainerInset = NSSize(width: 4, height: 4)
        welcomeTextView.autoresizingMask = [.width]
        welcomeTextView.isVerticallyResizable = true
        welcomeTextView.textContainer?.widthTracksTextView = true

        welcomeScroll = NSScrollView()
        welcomeScroll.documentView = welcomeTextView
        welcomeScroll.hasVerticalScroller = true
        welcomeScroll.drawsBackground = false

        placeholderLabel.font = NSFont.preferredFont(forTextStyle: .body)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center

        // Placeholder floats centered in the content region; the welcome
        // scroll view fills it. Visibility toggles per render.
        let content = NSView()
        welcomeScroll.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(welcomeScroll)
        content.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            welcomeScroll.topAnchor.constraint(equalTo: content.topAnchor),
            welcomeScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            welcomeScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            welcomeScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            placeholderLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            placeholderLabel.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor),
        ])

        let stack = NSStackView(views: [banner, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            banner.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            content.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        content.setContentHuggingPriority(.init(1), for: .vertical)

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tracker = ObservationTracker { [weak self] in
            guard let self else { return }
            self.render()
        }
        tracker?.start()
    }

    // MARK: - Render

    private func render() {
        let state = client.state
        banner.configure(
            state: state,
            serverVersion: client.serverVersion,
            isTransmitting: client.isTransmitting,
            voiceAvailable: client.voiceAvailable,
            isSelfMuted: client.isSelfMuted,
            isSelfDeafened: client.isSelfDeafened
        )

        let welcome = client.serverWelcomeText
        if welcome.isEmpty {
            welcomeScroll.isHidden = true
            placeholderLabel.isHidden = false
            placeholderLabel.stringValue = Self.placeholderText(for: state)
            lastWelcomeInput = nil
        } else {
            welcomeScroll.isHidden = false
            placeholderLabel.isHidden = true
            if welcome != lastWelcomeInput {
                lastWelcomeInput = welcome
                welcomeTextView.textStorage?.setAttributedString(
                    WelcomeHTML.attributedString(from: welcome)
                )
            }
        }
    }

    private static func placeholderText(for state: MumbleClient.ConnectionState) -> String {
        switch state {
        case .disconnected: "Not connected. File ▸ Connect to Server… (⌘K)"
        case .connecting: "Opening TLS connection…"
        case .handshaking: "Negotiating Mumble protocol…"
        case .connected: "Connected."
        case .failed(let reason): "Failed: \(reason)"
        }
    }
}

// MARK: - Status banner

/// Horizontal status bar: connection indicator dot, state label, server
/// version, voice status, and the mute / deafen buttons. `configure`
/// mutates labels/images/visibility in place — no view recreation.
@MainActor
final class StatusBannerView: NSView {
    private let indicatorDot = NSView()
    private let stateLabel = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let connectedCluster = NSStackView()
    private let voiceIcon = NSImageView()
    private let voiceLabel = NSTextField(labelWithString: "")
    private let muteButton = NSButton()
    private let deafenButton = NSButton()

    private let onToggleMute: () -> Void
    private let onToggleDeafen: () -> Void

    init(onToggleMute: @escaping () -> Void, onToggleDeafen: @escaping () -> Void) {
        self.onToggleMute = onToggleMute
        self.onToggleDeafen = onToggleDeafen
        super.init(frame: .zero)

        indicatorDot.wantsLayer = true
        indicatorDot.layer?.cornerRadius = 5
        indicatorDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            indicatorDot.widthAnchor.constraint(equalToConstant: 10),
            indicatorDot.heightAnchor.constraint(equalToConstant: 10),
        ])

        stateLabel.font = NSFont.preferredFont(forTextStyle: .callout)
        versionLabel.font = NSFont.preferredFont(forTextStyle: .callout)
        versionLabel.textColor = .secondaryLabelColor

        voiceLabel.font = NSFont.preferredFont(forTextStyle: .caption1)
        voiceLabel.textColor = .secondaryLabelColor

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 14).isActive = true

        muteButton.isBordered = false
        muteButton.imagePosition = .imageOnly
        muteButton.target = self
        muteButton.action = #selector(toggleMute(_:))
        // Pin icon width so the slash variant (wider) doesn't shove the
        // deafen button sideways on toggle.
        muteButton.widthAnchor.constraint(equalToConstant: 18).isActive = true

        deafenButton.isBordered = false
        deafenButton.imagePosition = .imageOnly
        deafenButton.target = self
        deafenButton.action = #selector(toggleDeafen(_:))
        deafenButton.widthAnchor.constraint(equalToConstant: 22).isActive = true

        connectedCluster.orientation = .horizontal
        connectedCluster.spacing = 8
        connectedCluster.addArrangedSubview(voiceIcon)
        connectedCluster.addArrangedSubview(voiceLabel)
        connectedCluster.addArrangedSubview(divider)
        connectedCluster.addArrangedSubview(muteButton)
        connectedCluster.addArrangedSubview(deafenButton)
        connectedCluster.setCustomSpacing(4, after: voiceIcon)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 12).isActive = true

        let stack = NSStackView(views: [indicatorDot, stateLabel, versionLabel,
                                        spacer, connectedCluster])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StatusBannerView does not support NSCoding")
    }

    func configure(state: MumbleClient.ConnectionState,
                   serverVersion: String?,
                   isTransmitting: Bool,
                   voiceAvailable: Bool,
                   isSelfMuted: Bool,
                   isSelfDeafened: Bool) {
        indicatorDot.layer?.backgroundColor = Self.indicatorColor(for: state).cgColor
        stateLabel.stringValue = Self.label(for: state)

        let connected = (state == .connected)
        versionLabel.isHidden = !(connected && serverVersion != nil)
        if let serverVersion {
            versionLabel.stringValue = "· server \(serverVersion)"
        }

        connectedCluster.isHidden = !connected
        guard connected else { return }

        if voiceAvailable {
            voiceIcon.image = NSImage(systemSymbolName: isTransmitting ? "mic.fill" : "mic",
                                      accessibilityDescription: nil)
            voiceIcon.contentTintColor = isTransmitting ? .systemGreen : .secondaryLabelColor
            voiceLabel.stringValue = isTransmitting ? "Transmitting" : "Hold 🌐+⌃ to talk"
            voiceLabel.textColor = .secondaryLabelColor
        } else {
            voiceIcon.image = NSImage(systemSymbolName: "mic.slash",
                                      accessibilityDescription: nil)
            voiceIcon.contentTintColor = .systemOrange
            voiceLabel.stringValue = "Voice unavailable"
            voiceLabel.textColor = .systemOrange
        }

        muteButton.image = NSImage(systemSymbolName: isSelfMuted ? "mic.slash.fill" : "mic.fill",
                                   accessibilityDescription: nil)
        muteButton.contentTintColor = isSelfMuted ? .systemOrange : .secondaryLabelColor
        muteButton.toolTip = isSelfMuted ? "Unmute" : "Mute"
        muteButton.setAccessibilityLabel(isSelfMuted ? "Unmute self" : "Mute self")

        deafenButton.image = NSImage(systemSymbolName: isSelfDeafened ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                     accessibilityDescription: nil)
        deafenButton.contentTintColor = isSelfDeafened ? .systemOrange : .secondaryLabelColor
        deafenButton.toolTip = isSelfDeafened ? "Undeafen" : "Deafen"
        deafenButton.setAccessibilityLabel(isSelfDeafened ? "Undeafen self" : "Deafen self")
    }

    @objc private func toggleMute(_ sender: Any?) { onToggleMute() }
    @objc private func toggleDeafen(_ sender: Any?) { onToggleDeafen() }

    private static func indicatorColor(for state: MumbleClient.ConnectionState) -> NSColor {
        switch state {
        case .disconnected: .systemGray
        case .connecting, .handshaking: .systemYellow
        case .connected: .systemGreen
        case .failed: .systemRed
        }
    }

    private static func label(for state: MumbleClient.ConnectionState) -> String {
        switch state {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .handshaking: "Handshaking"
        case .connected: "Connected"
        case .failed(let reason): "Failed: \(reason)"
        }
    }
}
