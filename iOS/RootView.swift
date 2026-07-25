import SwiftUI
import Combine

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    // The single, app-wide player. Lives here so playback survives navigating
    // between tabs and emails; the mini-player, Now Playing view, and the iPad
    // detail pane all drive it.
    @StateObject private var player = EmailPlayerViewModel(mailService: MockMailService())
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage("hasCompletedWelcome") private var hasCompletedWelcome = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        phaseContent
            // Light / dark / follow-the-system, chosen in Settings.
            .preferredColorScheme(settings.appearance.colorScheme)
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch appState.phase {
        case .launching:
            SplashView()
        case .onboarding:
            // First-run tour only. Finishing (or skipping) drops into the app with
            // no mailbox — no sign-in wall; the Inbox tab offers to connect email.
            WelcomeView {
                hasCompletedWelcome = true
                appState.enterWithoutMail()
            }
        case .ready:
            readyLayout
                .environmentObject(player)
                .task(id: appState.activeAccountID) {
                    // Rebind the player to the active account's mailbox on switch.
                    player.configure(appState.mailService)
                    player.bindRemoteCommands()
                }
                // Keep the Apple Watch remote in sync: push a snapshot whenever
                // playback state changes, and re-push when the watch reconnects.
                .onAppear { connectWatchRemote() }
                .onChange(of: player.isPlaying) { _, _ in pushNowPlaying() }
                .onChange(of: player.currentBlockIndex) { _, _ in pushNowPlaying() }
                .onChange(of: player.parsed?.email.id) { _, _ in pushNowPlaying() }
                .onChange(of: settings.speed) { _, _ in pushNowPlaying() }
                .onReceive(WatchConnectivityBridge.shared.$isReachable) { reachable in
                    if reachable { pushNowPlaying() }
                }
                // Tapping a feed notification opens that article directly.
                .onReceive(NotificationRouter.shared.$openFeedItemID.compactMap { $0 }) { id in
                    openFeedItem(id)
                }
        }
    }

    /// Wire the watch as a remote: run its transport commands against the shared
    /// player, and apply speed changes it sends.
    private func connectWatchRemote() {
        let bridge = WatchConnectivityBridge.shared
        bridge.onCommand = { command in
            switch command {
            case .play:             if !player.isPlaying { player.togglePlayPause() }
            case .pause:            if player.isPlaying { player.togglePlayPause() }
            case .nextSentence:     player.nextSentence()
            case .previousSentence: player.previousSentence()
            case .highlight:        _ = player.captureHighlight()
            case .nextItem:         player.skipToNextItem()
            }
        }
        bridge.onSpeed = { newValue in AppSettings.shared.speed = newValue }
        pushNowPlaying()
    }

    /// Open the feed item a tapped notification points to, then clear the route.
    /// Best-effort: if the item isn't in the store yet, a refresh will bring it in
    /// and the user can tap again.
    private func openFeedItem(_ id: String) {
        let store = FeedStore.shared
        if let item = store.items.first(where: { $0.id == id }) {
            FeedPlayback.open(item, player: player, store: store)
        }
        NotificationRouter.shared.openFeedItemID = nil
    }

    /// Send the current player snapshot to the watch remote.
    private func pushNowPlaying() {
        let state: NowPlayingState
        if let email = player.parsed?.email {
            state = NowPlayingState(
                sender: email.from.displayName,
                subject: email.subjectOrFallback,
                senderAddress: email.from.address,
                artworkURL: watchArtworkURL,
                currentSentence: player.currentBlock?.spokenText,
                isPlaying: player.isPlaying,
                progress: player.progress,
                secondsRemaining: Int((player.duration * (1 - player.progress)).rounded()),
                speed: settings.speed
            )
        } else {
            state = .empty
        }
        WatchConnectivityBridge.shared.send(nowPlaying: state)
    }

    /// Keep the most recently encountered inline image on the watch until playback
    /// reaches another one, exactly like the lock-screen artwork.
    private var watchArtworkURL: URL? {
        guard !player.blocks.isEmpty else { return nil }
        let upperBound = min(player.currentBlockIndex, player.blocks.count - 1)
        guard upperBound >= 0 else { return nil }
        for index in stride(from: upperBound, through: 0, by: -1) {
            if case .image(let image) = player.blocks[index],
               let url = image.remoteURL {
                return url
            }
        }
        return nil
    }

    /// iPad (regular width) gets a two-column split — the email list on the left,
    /// the reading view + player permanently on the right. iPhone (compact) keeps
    /// the tab bar, floating mini-player, and full-screen Now Playing.
    @ViewBuilder
    private var readyLayout: some View {
        if horizontalSizeClass == .regular {
            // iPad split view keeps a live detail pane, so previewing a newly
            // tapped email beside what's playing makes sense.
            SplitLayout().onAppear { player.usesInlineDetail = true }
        } else {
            // iPhone's reader is a full-screen cover — a tap must switch straight
            // to that email, not stage a preview behind the playing one.
            CompactLayout().onAppear { player.usesInlineDetail = false }
        }
    }
}

/// iPhone layout: Inbox/Saved tabs with a floating mini-player that expands into
/// the full-screen Now Playing view.
private struct CompactLayout: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: EmailPlayerViewModel
    @State private var section: LibrarySection = .inbox
    @State private var didChooseInitialTab = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $section) {
                InboxView()
                    .tabItem { Label("Inbox", systemImage: "tray.full") }
                    .tag(LibrarySection.inbox)

                FeedsView()
                    .tabItem { Label("Feeds", systemImage: "dot.radiowaves.up.forward") }
                    .tag(LibrarySection.feeds)

                SavedArticlesView()
                    .tabItem { Label("Saved", systemImage: "safari") }
                    .tag(LibrarySection.saved)
            }

            if player.parsed != nil {
                MiniPlayerBar()
                    // Float just above the standard tab bar (≈49pt) with a gap.
                    .padding(.bottom, 53)
            }
        }
        .onAppear(perform: chooseInitialTab)
        .animation(.easeInOut(duration: 0.2), value: player.parsed != nil)
        .fullScreenCover(isPresented: $player.isExpanded) {
            NowPlayingView()
                .environmentObject(player)
                .environmentObject(appState)
        }
    }

    /// Pick the tab to open on first launch. With no mailbox connected, the Inbox
    /// is just a "connect email" prompt — so if the user already follows feeds,
    /// start on Feeds where there's something to listen to right away. Runs once;
    /// after that the user's tab choice stands.
    private func chooseInitialTab() {
        guard !didChooseInitialTab else { return }
        didChooseInitialTab = true
        if appState.account == nil, !FeedStore.shared.feeds.isEmpty {
            section = .feeds
        }
    }
}

/// The libraries the iPad source sidebar switches between.
private enum LibrarySection: Hashable, CaseIterable, Identifiable {
    case inbox, feeds, saved
    var id: Self { self }

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .saved: "Saved"
        case .feeds: "Feeds"
        }
    }

    var icon: String {
        switch self {
        case .inbox: "tray.full"
        case .saved: "safari"
        case .feeds: "dot.radiowaves.up.forward"
        }
    }
}

/// iPad layout: a three-column split view, like Mail. A narrow source sidebar
/// (Inbox / Saved) on the far left, the selected list in the middle, and the
/// reading view + player permanently on the right — so there's no mini-player or
/// full-screen cover; the email or article you tap simply appears on the right.
private struct SplitLayout: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: EmailPlayerViewModel
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var section: LibrarySection? = .inbox
    @State private var didChooseInitialTab = false
    @State private var showSettings = false
    @State private var showHighlights = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Source sidebar. (Utility actions live on the middle column's toolbar,
            // which is always visible — the sidebar collapses in portrait.)
            // Drive selection from a ForEach (not static tagged rows) — on iPadOS
            // single-selection taps on static `Label().tag()` rows frequently don't
            // register, which left the whole sidebar feeling unresponsive.
            List(selection: $section) {
                ForEach(LibrarySection.allCases) { sec in
                    Label(sec.title, systemImage: sec.icon).tag(sec)
                }
            }
            .navigationTitle("HearIt")
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
        } content: {
            Group {
                switch section ?? .inbox {
                case .inbox: InboxList(showsUtilityToolbar: false)
                case .saved: SavedArticlesList(showsHighlightsButton: false)
                case .feeds: FeedsList(showsHighlightsButton: false)
                }
            }
            // Highlights (bookmark) sits leftmost — it's the one control every
            // screen shares. Analytics now lives inside Settings.
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showHighlights = true } label: { Image(systemName: "bookmark") }
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
        } detail: {
            NavigationStack {
                if player.parsed != nil || player.staged != nil {
                    PlayerDetailContent()
                } else {
                    ContentUnavailableView(
                        "No email selected",
                        systemImage: "envelope.open",
                        description: Text("Pick a message on the left to read and listen along.")
                    )
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            // See CompactLayout.chooseInitialTab: start on Feeds when there's no
            // mailbox but feeds to listen to. Runs once.
            guard !didChooseInitialTab else { return }
            didChooseInitialTab = true
            if appState.account == nil, !FeedStore.shared.feeds.isEmpty {
                section = .feeds
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
        }
        .sheet(isPresented: $showHighlights) {
            NavigationStack { HighlightsListView() }
                .environmentObject(player)
                .environmentObject(appState)
        }
    }
}
