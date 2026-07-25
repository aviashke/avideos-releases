import SwiftUI
import UIKit

/// The reading + player surface: an optional voice warning, the live-highlighted
/// transcript, and the transport controls. It drives the single, app-wide
/// `EmailPlayerViewModel` from the environment so playback continues no matter
/// where you navigate.
///
/// This view carries *no* presentation chrome of its own (no `NavigationStack`,
/// no collapse button), so it can be reused two ways: wrapped by `NowPlayingView`
/// as the iPhone full-screen sheet, and dropped straight into the iPad split
/// view's detail column. Callers supply the surrounding navigation.
///
/// If you open an email while a *different* one is still playing, this shows the
/// new one as a preview (the old keeps playing) with a "Play this email" button.
struct PlayerDetailContent: View {
    @EnvironmentObject private var player: EmailPlayerViewModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var highlightStore = HighlightStore.shared
    // Observed so a line struck-through/un-struck (skip rule added/removed) updates
    // the transcript live.
    @ObservedObject private var skipRules = SkipRuleStore.shared

    /// A struck-through line the listener tapped, offering to read it again.
    @State private var unskipText: String?

    /// The article being opened in the in-app browser (nil = closed).
    @State private var browserLink: BrowserLink?
    /// True while the browser occupies the upper pane and the real reader remains
    /// visible in the lower peek, matching X's in-app browser transition.
    @State private var browserOpen = false
    /// Whether playback was running when the browser opened, so closing it can
    /// resume — the item is held (paused) while you're reading in-app.
    @State private var wasPlayingBeforeBrowser = false

    private struct BrowserLink: Identifiable {
        let id = UUID()
        let url: URL
    }

    @State private var highlightToAnnotate: Highlight?
    @State private var showCompletion = false
    @State private var dismissedVoiceWarning = false
    @State private var showLinks = false
    /// Measured height of the floating transport panel, used as the transcript's
    /// bottom inset so the last sentence clears it.
    @State private var controlsHeight: CGFloat = 140

    /// The transport panel shrinks to a compact pill (highlight + play/pause with
    /// a progress ring) when you leave it alone while listening, freeing the screen
    /// for text — like Safari's toolbar. It re-expands on tap, on pause, and when a
    /// new item opens, then collapses again after a few idle seconds.
    @State private var controlsCollapsed = false
    @State private var collapseTask: Task<Void, Never>?

    /// While you long-press a line to decide whether to mute it, freeze the
    /// follow-along auto-scroll so the text you're deciding on stays put (instead
    /// of sliding away under the menu). Auto-resumes shortly after.
    @State private var holdAutoScroll = false
    @State private var holdScrollTask: Task<Void, Never>?
    /// The sentence selected by the dedicated reader-mode hold gesture. Its
    /// confirmation dialog is attached directly to that sentence row so the
    /// popover arrow appears beside the text that was actually pressed.
    @State private var pendingSkip: PendingSkip?

    private struct PendingSkip {
        let blockIndex: Int
        let text: String
        let senderAddress: String
        let senderLabel: String
        let isSkipped: Bool
    }
    /// Live carousel drag: the transcript pane's current horizontal offset. Driven
    /// 1:1 by the finger while dragging, then eased to 0/±paneWidth to complete or
    /// cancel a swipe, and to 0 whenever a new item lands (see the item-change
    /// carousel reveal below).
    @State private var dragTranslation: CGFloat = 0
    /// True for as long as a finger is down on the transcript.
    @State private var isDragging = false
    /// True once a swipe is committed and we're waiting for the real content to
    /// finish loading before snapping the offset back to 0.
    @State private var isSettling = false
    /// +1 = moving to the next item (dragging left), -1 = previous.
    @State private var swipeDirection = 1
    @State private var paneWidth: CGFloat = UIScreen.main.bounds.width
    private static let collapseAnimation: Animation = .spring(response: 0.38, dampingFraction: 0.85)

    /// Links from whatever's on screen (a staged preview takes precedence).
    private var currentLinks: [EmailLink] {
        player.staged?.links ?? player.parsed?.links ?? []
    }

    /// The feed item's own web page, so the reader can offer "open the full
    /// article in the browser". Feed emails stash the item's link in the sender
    /// address; nil for regular mail (no web page to open).
    private var articleURL: URL? {
        guard let email = player.staged?.email ?? player.parsed?.email,
              email.id.hasPrefix("rss-"),
              let url = URL(string: email.from.address),
              url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }

    /// This email's own "read it on the web" link (e.g. a Substack post whose
    /// headline links to the web version) — only meaningful for regular mail;
    /// feed items already have their own dedicated button via `articleURL`.
    private var emailCanonicalURL: URL? {
        guard articleURL == nil else { return nil }
        return player.staged?.canonicalURL ?? player.parsed?.canonicalURL
    }

    // The iPad reading pane is much wider than an iPhone, so the same point size
    // looks small there. Scale the reading text up on iPad (every size, including
    // Extra Large) while leaving the iPhone sizes untouched.
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var readingScale: CGFloat { isPad ? 1.4 : 1 }
    private var bodyFontSize: CGFloat { settings.readingTextSize.bodyPointSize * readingScale }
    private var titleFontSize: CGFloat { settings.readingTextSize.titlePointSize * readingScale }

    /// X leaves roughly the lower quarter of the source post visible. Clamp that
    /// fraction so it remains useful on both compact iPhones and large iPads.
    private func browserPeekHeight(in availableHeight: CGFloat) -> CGFloat {
        min(max(availableHeight * 0.24, 150), 220)
    }

    // Split into a base view plus two generic modifier helpers: one big modifier
    // chain overwhelmed the SwiftUI type-checker ("unable to type-check in
    // reasonable time"), so each piece is type-checked independently.
    var body: some View {
        GeometryReader { geometry in
            let peekHeight = browserPeekHeight(in: geometry.size.height)
            let browserHeight = max(0, geometry.size.height - peekHeight)

            ZStack(alignment: .top) {
                // This is the actual reader, not a substitute header. Moving the
                // whole surface down keeps spatial continuity with the source just
                // like the reference: browser above, original content below.
                readerLayer
                    .offset(y: browserOpen ? browserHeight : 0)
                    .allowsHitTesting(!browserOpen)

                if let link = browserLink {
                    InAppBrowserView(url: link.url, onClose: closeBrowser)
                        .id(link.id)
                        .background(Color(.systemBackground))
                        .frame(maxWidth: .infinity)
                        .frame(height: browserOpen ? browserHeight : 0, alignment: .top)
                        .clipped()
                        .clipShape(
                            UnevenRoundedRectangle(
                                bottomLeadingRadius: browserOpen ? 22 : 0,
                                bottomTrailingRadius: browserOpen ? 22 : 0,
                                style: .continuous
                            )
                        )
                        .shadow(color: .black.opacity(browserOpen ? 0.22 : 0),
                                radius: 14, y: 5)
                        .allowsHitTesting(browserOpen)
                }

                // The exposed reader strip behaves as the return target. The
                // browser's own X button remains available as a second route.
                if browserOpen {
                    Button(action: closeBrowser) {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .frame(height: peekHeight)
                    .offset(y: browserHeight)
                    .accessibilityLabel("Return to reader")
                }
            }
            .clipped()
            .background(Color(.systemBackground))
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.94), value: browserOpen)
    }

    private var readerLayer: some View {
        withLifecycle(withPresentations(baseContent))
    }

    /// Open immediately, as in the reference. The page's progress line handles a
    /// slow network response; delaying the motion behind a haptic count-in made
    /// the tap feel disconnected from the transition.
    private func startBrowser(_ url: URL) {
        // Hold on this item while you're reading in-app — otherwise playback
        // could finish and auto-advance to another article underneath you while
        // you're still looking at this one's page.
        if player.isPlaying {
            wasPlayingBeforeBrowser = true
            player.pause()
        }
        if let existing = browserLink, existing.url == url {
            browserOpen = true   // same page already loaded — just show it
            return
        }
        browserOpen = false
        browserLink = BrowserLink(url: url)
        // Give SwiftUI one update to mount the zero-height browser, then animate
        // its bottom edge down while the reader moves by the exact same amount.
        Task { @MainActor in
            await Task.yield()
            guard browserLink != nil else { return }
            browserOpen = true
        }
    }

    private func closeBrowser() {
        browserOpen = false
        // Keep `browserLink` (the web view stays mounted, hidden) so reopening the
        // same article is instant. It's cleared when the reader moves to a new item.
        if wasPlayingBeforeBrowser {
            player.play()
            wasPlayingBeforeBrowser = false
        }
    }

    private var baseContent: some View {
        VStack(spacing: 0) {
            voiceBanner
            modeContent
        }
        .background(PiPHostView().frame(width: 2, height: 2).opacity(0.02).allowsHitTesting(false))
        .navigationTitle(player.staged?.email.from.displayName
                         ?? player.parsed?.email.from.displayName ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { readerToolbar }
        // While the browser is revealed the reader slides down; hide the nav bar
        // so its chrome doesn't stay stuck at the top over the web page.
        .toolbar(browserOpen ? .hidden : .visible, for: .navigationBar)
    }

    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
        if let articleURL {
            ToolbarItem(placement: .topBarTrailing) {
                Button { startBrowser(articleURL) } label: {
                    Image(systemName: "safari")
                }
                .accessibilityLabel("Open the full article in the browser")
            }
        }
        if let emailCanonicalURL {
            // This email's headline links to the post itself (Substack-style) —
            // open that directly rather than making the listener dig through
            // every link in the body for the one that's actually the article.
            ToolbarItem(placement: .topBarTrailing) {
                Button { startBrowser(emailCanonicalURL) } label: {
                    Image(systemName: "link")
                }
                .accessibilityLabel("Open this email's post in the browser")
                .contextMenu {
                    if !currentLinks.isEmpty {
                        Button {
                            showLinks = true
                        } label: {
                            Label("See all links in this email", systemImage: "list.bullet")
                        }
                    }
                }
            }
        } else if !currentLinks.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showLinks = true } label: {
                    Image(systemName: "link")
                }
                .accessibilityLabel("Links in this email")
            }
        }
        if settings.pictureInPicture && ReaderPiPController.shared.isSupported {
            ToolbarItem(placement: .topBarTrailing) {
                Button { ReaderPiPController.shared.start() } label: {
                    Image(systemName: "pip.enter")
                }
            }
        }
    }

    /// Sheets, dialogs, and the error alert.
    private func withPresentations<Content: View>(_ content: Content) -> some View {
        content
            .sheet(isPresented: $showLinks) {
                NavigationStack { LinksListView(links: currentLinks) }
            }
            .sheet(item: $highlightToAnnotate) { highlight in
                NavigationStack { HighlightComposerView(highlight: highlight) }
            }
            .confirmationDialog(
                "Read this line again?",
                isPresented: Binding(get: { unskipText != nil }, set: { if !$0 { unskipText = nil } }),
                titleVisibility: .visible,
                presenting: unskipText
            ) { text in
                Button("Read it again") { unskipMatching(text) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Un-mutes it everywhere it was muted.")
            }
            .alert("Playback problem", isPresented: .constant(player.errorMessage != nil)) {
                Button("OK") { player.errorMessage = nil }
            } message: {
                Text(player.errorMessage ?? "")
            }
    }

    /// Lifecycle hooks and the completion / celebration overlays.
    private func withLifecycle<Content: View>(_ content: Content) -> some View {
        content
            .onChange(of: player.parsed?.email.id) { _, _ in
                endScrollHold()
                dismissedVoiceWarning = false
                renderPiP()
                // A new item: open the full controls, then let them settle back down.
                expandControls()
                // Drop the cached browser — it belonged to the previous article.
                browserOpen = false
                browserLink = nil
                wasPlayingBeforeBrowser = false
            }
            .onAppear {
                player.onHighlightCaptured = { highlight in highlightToAnnotate = highlight }
                updateIdleTimer()
                configurePiP()
                if player.isPlaying { scheduleCollapse() }
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
                ReaderPiPController.shared.teardown()
                collapseTask?.cancel()
            }
            .onChange(of: player.isPlaying) { _, playing in
                updateIdleTimer()
                ReaderPiPController.shared.playbackStateChanged()
                // Collapse only while playing; pausing brings the full controls back.
                if playing { scheduleCollapse() } else { expandControls() }
            }
            .onChange(of: player.currentBlockIndex) { _, _ in renderPiP() }
            .onChange(of: settings.keepScreenAwake) { _, _ in updateIdleTimer() }
            .onChange(of: settings.pictureInPicture) { _, _ in updatePiPEnabled() }
            .onChange(of: player.isComplete) { _, complete in
                if complete { showCompletion = true }
            }
            .onChange(of: player.celebrateFeedFinish) { _, celebrating in
                guard celebrating else { return }
                // The per-item "Finished" banner would double up with the celebration.
                showCompletion = false
                Task {
                    try? await Task.sleep(nanoseconds: 2_800_000_000)
                    player.celebrateFeedFinish = false
                    // Drop back to the feed list (collapses the reader on iPhone;
                    // clears the iPad detail pane) so all items are in view again.
                    player.clear()
                }
            }
            .overlay(alignment: .bottom) {
                // Above the player, so it never covers the last lines you're reading.
                if showCompletion && !player.celebrateFeedFinish {
                    completionBanner.padding(.bottom, controlsHeight + 16)
                }
            }
            .overlay {
                if player.celebrateFeedFinish { feedFinishedCelebration }
            }
    }

    /// The dismissible voice-quality banners, kept out of `body` so the
    /// type-checker handles each conditional branch separately.
    @ViewBuilder
    private var voiceBanner: some View {
        if let language = player.missingVoiceLanguage, !dismissedVoiceWarning {
            voiceWarning(language)
        }
    }

    /// Preview / loading / active, split out of `body` for the same reason.
    @ViewBuilder
    private var modeContent: some View {
        if let staged = player.staged {
            previewMode(staged)
        } else if player.parsed == nil {
            Spacer()
            ProgressView("Opening…")
            Spacer()
        } else {
            activeMode
        }
    }

    /// Hold the screen on while you're watching it read (like a video), per the
    /// "Keep screen awake" setting. Released when paused or the view goes away.
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake && player.isPlaying
    }

    // MARK: - Picture in Picture

    /// Point PiP's transport at the shared player and enable it per the setting.
    private func configurePiP() {
        let pip = ReaderPiPController.shared
        pip.isPlayingProvider = { [weak player] in player?.isPlaying ?? false }
        pip.onTogglePlay = { [weak player] in player?.togglePlayPause() }
        pip.onSkip = { [weak player] forward in
            forward ? player?.nextSentence() : player?.previousSentence()
        }
        updatePiPEnabled()
    }

    private func updatePiPEnabled() {
        let pip = ReaderPiPController.shared
        if settings.pictureInPicture {
            pip.setAutoStart(true)
            renderPiP()
        } else {
            pip.teardown()
        }
    }

    /// Push a fresh PiP frame showing what's being read right now.
    private func renderPiP() {
        guard settings.pictureInPicture else { return }
        let header = player.parsed?.email.from.displayName ?? ""
        let sentence: String
        switch player.currentBlock {
        case .sentence(let s)?: sentence = s.text
        case .image?:           sentence = "🖼 Image"
        case nil:               sentence = player.parsed?.email.subjectOrFallback ?? ""
        }
        ReaderPiPController.shared.render(header: header, sentence: sentence, progress: player.progress)
    }

    // MARK: - Active (playing) mode

    /// Live, finger-tracking drag between items: the transcript follows your
    /// finger 1:1 (like a real carousel/pager) and a lightweight preview of the
    /// neighbor's header slides in from the edge as you go — released past the
    /// threshold commits the swipe, otherwise it springs back. Pure navigation:
    /// it never marks anything read.
    private var itemDragGesture: some Gesture {
        // 24pt, not the ~12pt used while first building this: a smaller threshold
        // let the natural tremor of holding a finger still for a long-press (to
        // mute a line) get misread as the start of a swipe, which fought with —
        // and could suppress — the system's long-press-to-context-menu gesture.
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard player.canMoveBetweenItems, !isSettling else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                // Only capture once it's clearly horizontal, so vertical scrolling
                // of the transcript still works; once captured, stay captured for
                // the rest of this gesture even if the ratio changes.
                guard isDragging || abs(dx) > abs(dy) * 1.2 else { return }
                if !isDragging {
                    isDragging = true
                    swipeDirection = dx < 0 ? 1 : -1
                } else if abs(dx) > 18 {
                    // Don't let tiny reversals around the resting point alternate
                    // the neighbor pane between opposite sides every frame.
                    swipeDirection = dx < 0 ? 1 : -1
                }
                let bounded = min(max(dx, -paneWidth), paneWidth)
                // A live drag must never inherit an animation from playback,
                // auto-scroll, or another surrounding SwiftUI transaction.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    dragTranslation = bounded
                }
            }
            .onEnded { value in
                guard isDragging else { return }
                let dx = value.translation.width
                let direction = dx < 0 ? 1 : -1
                let flungFast = abs(value.predictedEndTranslation.width) > paneWidth * 0.6
                let wantsCommit = abs(dx) > paneWidth * 0.22 || flungFast
                // Don't commit into a direction with nothing there (list boundary)
                // — that would fling the content off-screen waiting on a fetch that
                // can never land. If there's no preview provider at all, trust the
                // async siblingProvider to sort it out, same as before.
                let hasSibling = player.siblingPreviewProvider == nil
                    || player.parsed.flatMap { player.siblingPreviewProvider?($0.email.id, direction) } != nil
                guard wantsCommit, hasSibling else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { dragTranslation = 0 }
                    isDragging = false
                    return
                }
                commitSwipe(direction: direction)
            }
    }

    /// Finish an in-progress swipe: ease the current pane the rest of the way off
    /// screen (the preview pane is already tracking into place behind it), kick
    /// off the real content load, and wait for it to land — see the item-change
    /// handler on `activeMode`, which snaps the offset back to 0 the instant the
    /// new content is ready (so there's no held blank/mismatched frame).
    private func commitSwipe(direction: Int) {
        swipeDirection = direction
        isSettling = true
        endScrollHold()
        withAnimation(.easeOut(duration: 0.22)) {
            dragTranslation = direction == 1 ? -paneWidth : paneWidth
        }
        player.moveToSibling(direction)
        let expectedID = player.parsed?.email.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            // Safety valve: the sibling fetch failed or is hung — settle back
            // rather than leaving the transcript stuck off-screen forever.
            guard isSettling, player.parsed?.email.id == expectedID else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { dragTranslation = 0 }
            isDragging = false
            isSettling = false
        }
    }

    /// Freeze the follow-along scroll while the listener decides on a line, with a
    /// safety timeout so it always resumes even if the menu is dismissed silently.
    private func beginScrollHold() {
        holdAutoScroll = true
        holdScrollTask?.cancel()
        holdScrollTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled else { return }
            holdAutoScroll = false
        }
    }

    private func endScrollHold() {
        holdScrollTask?.cancel()
        holdAutoScroll = false
        pendingSkip = nil
    }

    private var activeMode: some View {
        // Transcript and controls are siblings: the transcript carousel carries
        // the live drag / slide, while the transport panel stays put on top.
        ZStack(alignment: .bottom) {
            transcriptCarousel
            controlsOverlay
        }
        .onPreferenceChange(ControlsHeightKey.self) { controlsHeight = max($0, 64) }
        .onChange(of: player.parsed?.email.id) { oldValue, _ in
            guard oldValue != nil else { return }   // skip the very first appearance
            if isDragging || isSettling {
                // Our own swipe already eased the old content off-screen; the new
                // content just landed already positioned — swap with no animation
                // so there's no double-motion.
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    dragTranslation = 0
                    isDragging = false
                    isSettling = false
                }
            } else {
                // A programmatic advance (Next Item button, auto-advance) — slide
                // it in from the same edge a forward swipe would use.
                dragTranslation = paneWidth
                withAnimation(.easeOut(duration: 0.32)) { dragTranslation = 0 }
            }
        }
    }

    /// A lightweight, no-fetch preview of the item you're dragging toward — just
    /// its title and sender/feed name — shown while a finger is down or a swipe
    /// is settling, before the real content has finished loading.
    private var livePreviewText: (title: String, subtitle: String)? {
        guard isDragging || isSettling, let id = player.parsed?.email.id else { return nil }
        return player.siblingPreviewProvider?(id, swipeDirection)
    }

    private func siblingPreviewPane(_ preview: (title: String, subtitle: String)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(preview.subtitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(preview.title)
                .font(.system(size: titleFontSize, weight: .bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.systemBackground))
    }

    /// The transcript plus (while dragging/settling) a preview of the neighbor,
    /// both riding the same live `dragTranslation` so they move together as one
    /// real-time carousel instead of a swap-then-animate.
    private var transcriptCarousel: some View {
        ZStack {
            if let preview = livePreviewText {
                siblingPreviewPane(preview)
                    .allowsHitTesting(false)
                    .offset(x: dragTranslation + CGFloat(swipeDirection) * paneWidth)
            }
            transcriptPane
                .offset(x: dragTranslation)
        }
        .clipped()
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { if geo.size.width > 0 { paneWidth = geo.size.width } }
                .onChange(of: geo.size.width) { _, w in if w > 0 { paneWidth = w } }
        })
    }

    /// The scrolling transcript for the current item.
    private var transcriptPane: some View {
        let email = player.parsed?.email
        return ScrollViewReader { proxy in
            ScrollView {
                transcriptBody(subject: email?.subjectOrFallback ?? "",
                               date: email?.receivedAt,
                               emailID: email?.id ?? "",
                               blocks: player.blocks,
                               currentIndex: player.currentBlockIndex,
                               isActive: true)
                    // Clear the floating transport panel by its *measured* height
                    // (+ a margin), so the last sentence is never hidden behind it.
                    .padding(.bottom, controlsHeight + 24)
            }
            .onChange(of: player.currentBlockIndex) { _, index in
                // Held while a long-press decision menu is up, so the text doesn't
                // scroll out from under the menu. Also freeze vertical follow-along
                // while paging horizontally so sentence changes cannot tug the
                // ScrollView in a second direction beneath the finger.
                guard !holdAutoScroll, !isDragging, !isSettling else { return }
                withAnimation(.easeInOut) { proxy.scrollTo(index, anchor: .center) }
            }
            // Once a drag has clearly locked horizontally, stop the ScrollView from
            // simultaneously following the small vertical tremor of the same finger.
            .scrollDisabled(isDragging || isSettling)
            // Swipe left → next item, right → previous — pure navigation that
            // doesn't mark anything read. Simultaneous so vertical scrolling still
            // works; we only act on clearly-horizontal drags. This is the only
            // extra gesture recognizer on the whole scroll surface — the
            // scroll-hold long-press below is scoped to individual sentences
            // instead of the whole view, so a plain tap on any untouched
            // paragraph doesn't have to arbitrate against it.
            .simultaneousGesture(itemDragGesture)
        }
    }

    /// The floating transport panel (full controls or the collapsed pill).
    private var controlsOverlay: some View {
        Group {
            if controlsCollapsed {
                collapsedControls
                    .transition(.opacity)
            } else {
                PlayerControlsView(viewModel: player) {
                    _ = player.captureHighlight()
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, controlsCollapsed ? 10 : 12)
        .padding(.vertical, controlsCollapsed ? 8 : 12)
        .floatingGlass()
        .padding(.horizontal, controlsCollapsed ? 0 : 10)
        .padding(.bottom, 8)
        .background(GeometryReader { geo in
            Color.clear.preference(key: ControlsHeightKey.self, value: geo.size.height)
        })
    }

    /// The shrunken transport: just Highlight and Play/Pause (the pause ringed by a
    /// progress stroke showing how far to the end). Tapping the pill itself brings
    /// the full controls back.
    private var collapsedControls: some View {
        HStack(spacing: 18) {
            Button {
                _ = player.captureHighlight()
                scheduleCollapse()
            } label: {
                Image(systemName: "highlighter").font(.title3)
            }
            .tint(.primary)

            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0, min(1, player.progress)))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Button {
                    player.togglePlayPause()   // pausing re-expands via onChange
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.headline)
                }
                .tint(.primary)
            }
            .frame(width: 38, height: 38)
        }
        // Tap anywhere on the pill (outside the two buttons) to expand.
        .contentShape(Rectangle())
        .onTapGesture { expandControls() }
    }

    /// Collapse to the pill after a short idle period — but only while playing, so
    /// paused controls stay fully available.
    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, player.isPlaying else { return }
            withAnimation(Self.collapseAnimation) { controlsCollapsed = true }
        }
    }

    /// Bring the full controls back, then (if still playing) queue the next
    /// idle-collapse.
    private func expandControls() {
        collapseTask?.cancel()
        withAnimation(Self.collapseAnimation) { controlsCollapsed = false }
        if player.isPlaying { scheduleCollapse() }
    }

    // MARK: - Preview (staged) mode

    private func previewMode(_ staged: ParsedEmail) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                transcriptBody(subject: staged.email.subjectOrFallback,
                               date: staged.email.receivedAt,
                               emailID: staged.email.id,
                               blocks: staged.blocks,
                               currentIndex: nil,
                               isActive: false)
            }
            Divider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Still playing")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(player.parsed?.email.from.displayName ?? "")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
                Spacer()
                Button { player.playStaged() } label: {
                    Label("Play this email", systemImage: "play.fill")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    // MARK: - Transcript

    private func transcriptBody(subject: String, date: Date?, emailID: String, blocks: [ContentBlock],
                                currentIndex: Int?, isActive: Bool) -> some View {
        let layout = notedLayout(emailID: emailID, blocks: blocks)
        // Titles-only feed items carry a single body sentence that *is* the
        // headline (so it can be spoken). The subject heading already shows it,
        // so don't render it twice — just show the heading.
        let hideBody = blocks.count == 1
            && !blocks[0].isImage
            && blocks[0].spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(subject.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        let isRTLHeader = LanguageTools.isRightToLeft(subject)
        // Feed items show when they're from, under the headline — display only,
        // never spoken (it isn't part of the body blocks the engine reads).
        let dateLine: String? = {
            guard emailID.hasPrefix("rss-"), let date else { return nil }
            return date.formatted(date: .abbreviated, time: .shortened)
        }()
        // In titles-only mode the headline *is* what's read, so highlight the
        // spoken word right in the header (the body block is hidden).
        let headerIsReading = hideBody && currentIndex == 0
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: isRTLHeader ? .trailing : .leading, spacing: 4) {
                headerText(subject, highlightingWordWhen: headerIsReading)
                    .font(.system(size: titleFontSize, weight: .bold))
                    .multilineTextAlignment(isRTLHeader ? .trailing : .leading)
                if let dateLine {
                    Text(dateLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                // Titles-only shows just the headline — offer to pull in the rest
                // of the article (and read it) for this one item, on demand, plus a
                // quick way to copy its link to share.
                if isActive && hideBody {
                    HStack(spacing: 10) {
                        if player.expandProvider != nil {
                            Button {
                                player.expandCurrentItem()
                            } label: {
                                Label("Read full article", systemImage: "text.append")
                                    .font(.subheadline.weight(.medium))
                            }
                        }
                        if let articleURL {
                            Button {
                                UIPasteboard.general.url = articleURL
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                            } label: {
                                Label("Copy Link", systemImage: "doc.on.doc")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: isRTLHeader ? .trailing : .leading)
            .padding(.bottom, 4)

            if !hideBody {
                ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                    blockView(block, index: index, currentIndex: currentIndex, isActive: isActive,
                              noted: layout[index] ?? NotedInfo())
                        .id(index)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The header, optionally colouring the word currently being spoken (used in
    /// titles-only mode, where the headline is the thing being read).
    private func headerText(_ subject: String, highlightingWordWhen reading: Bool) -> Text {
        guard reading,
              let range = player.spokenWordRange,
              let swiftRange = Range(range, in: subject) else {
            return Text(subject)
        }
        var attributed = AttributedString(subject)
        if let attrRange = Range(swiftRange, in: attributed) {
            attributed[attrRange].foregroundColor = .accentColor
        }
        return Text(attributed)
    }

    /// Maps each sentence block to how it should render its saved-highlight state.
    /// A block counts as "noted" when its spoken text appears in a highlight's
    /// captured passage, or it is the highlight's anchor block. Consecutive noted
    /// blocks are then grouped into runs so a passage spanning several sentences
    /// reads as one continuous highlight with a single marker — not several boxes.
    private func notedLayout(emailID: String, blocks: [ContentBlock]) -> [Int: NotedInfo] {
        guard !emailID.isEmpty else { return [:] }
        let saved = highlightStore.highlights(forEmail: emailID)
        guard !saved.isEmpty else { return [:] }

        var highlighted = Set<Int>(), withNote = Set<Int>()
        for (index, block) in blocks.enumerated() {
            guard case .sentence = block else { continue }
            let text = block.spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 4 else { continue }
            for h in saved where (index == h.blockIndex && h.blockIndex > 0) || h.capturedText.contains(text) {
                highlighted.insert(index)
                if !h.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    withNote.insert(index)
                }
            }
        }
        guard !highlighted.isEmpty else { return [:] }

        var layout = [Int: NotedInfo]()
        let sorted = highlighted.sorted()
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count && sorted[j + 1] == sorted[j] + 1 { j += 1 }
            let run = Array(sorted[i...j])
            let runHasNote = run.contains { withNote.contains($0) }
            for (k, idx) in run.enumerated() {
                var info = NotedInfo()
                if run.count == 1 { info.position = .single }
                else if k == 0 { info.position = .first }
                else if k == run.count - 1 { info.position = .last }
                else { info.position = .middle }
                // One marker per run, on its first sentence.
                if info.position == .single || info.position == .first {
                    info.showMarker = true
                    info.markerIsNote = runHasNote
                }
                layout[idx] = info
            }
            i = j + 1
        }
        return layout
    }

    @ViewBuilder
    private func blockView(_ block: ContentBlock, index: Int,
                           currentIndex: Int?, isActive: Bool,
                           noted: NotedInfo) -> some View {
        let isCurrent = currentIndex == index
        switch block {
        case .sentence(let sentence):
            let skipped = isSkipped(sentence.text)
            SentenceText(text: sentence.text,
                         isCurrent: isCurrent,
                         notedPosition: noted.position,
                         showMarker: noted.showMarker,
                         markerIsNote: noted.markerIsNote,
                         wordRange: (isCurrent && !skipped) ? player.spokenWordRange : nil,
                         fontSize: bodyFontSize,
                         listDepth: sentence.listDepth,
                         bulletMarker: sentence.bulletMarker,
                         isSkipped: skipped,
                         isPendingSkip: pendingSkip?.blockIndex == index)
                .contentShape(Rectangle())
                .onTapGesture {
                    // A struck-through line: tap to offer reading it again.
                    // Otherwise tap jumps playback here.
                    endScrollHold()
                    if skipped { unskipText = sentence.text }
                    else if isActive { player.jump(toBlock: index) }
                }
                // A short, high-priority hold with more movement tolerance than
                // the system context menu. It either completes as a hold or fails
                // quickly into normal scrolling/swiping; there is no second
                // context-menu recognizer competing for the same touch.
                .highPriorityGesture(
                    LongPressGesture(minimumDuration: 0.32, maximumDistance: 24)
                        .onEnded { _ in
                            presentSkipChoices(for: sentence,
                                               blockIndex: index,
                                               isSkipped: skipped)
                        }
                )
                .confirmationDialog(
                    "",
                    isPresented: skipChoicesPresented(for: index),
                    titleVisibility: .hidden,
                    presenting: pendingSkip
                ) { selection in
                    if selection.isSkipped {
                        Button("Read it again") {
                            unskipMatching(selection.text)
                            endScrollHold()
                        }
                    } else {
                        Button("Skip from this sender") {
                            skipRules.add(phrase: selection.text,
                                          sender: selection.senderAddress,
                                          label: selection.senderLabel)
                            endScrollHold()
                        }
                        Button("Skip from everyone") {
                            skipRules.add(phrase: selection.text,
                                          sender: "",
                                          label: selection.senderLabel)
                            endScrollHold()
                        }
                    }
                }
        case .image(let image):
            ImageBlockView(image: image, isCurrent: isCurrent) {
                player.skipImage()
            }
            .onTapGesture { if isActive { player.jump(toBlock: index) } }
        }
    }

    private func presentSkipChoices(for sentence: Sentence,
                                    blockIndex: Int,
                                    isSkipped: Bool) {
        guard let from = player.parsed?.email.from ?? player.staged?.email.from else { return }
        beginScrollHold()
        pendingSkip = PendingSkip(blockIndex: blockIndex,
                                  text: sentence.text,
                                  senderAddress: from.address,
                                  senderLabel: from.displayName,
                                  isSkipped: isSkipped)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Only the selected row presents the dialog. Keeping this binding on the row
    /// gives SwiftUI the correct source rectangle for its popover placement.
    private func skipChoicesPresented(for blockIndex: Int) -> Binding<Bool> {
        Binding(
            get: { pendingSkip?.blockIndex == blockIndex },
            set: { isPresented in
                if !isPresented, pendingSkip?.blockIndex == blockIndex {
                    endScrollHold()
                }
            }
        )
    }

    /// The sender address of what's on screen, for matching skip rules.
    private var currentFromAddress: String? {
        (player.parsed ?? player.staged)?.email.from.address
    }

    /// Whether a line is currently muted by a skip rule for this sender.
    private func isSkipped(_ text: String) -> Bool {
        guard let addr = currentFromAddress else { return false }
        return skipRules.shouldSkip(text, fromAddress: addr)
    }

    /// Un-skip: remove every rule that was muting this line (for this sender or
    /// for everyone), so it reads again from now on.
    private func unskipMatching(_ text: String) {
        guard let addr = currentFromAddress else { return }
        for rule in skipRules.rules where rule.matches(text, fromAddress: addr) {
            skipRules.remove(rule.id)
        }
    }

    private func voiceWarning(_ language: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "speaker.slash.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("No \(language) voice installed")
                    .font(.subheadline.weight(.semibold))
                Text("This email looks like it's in \(language), but there's no \(language) voice on this device, so it may not read correctly. Add one in Settings → Accessibility → Spoken Content → Voices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    Button("Dismiss") { dismissedVoiceWarning = true }
                        .foregroundStyle(.secondary)
                }
                .font(.caption.weight(.medium))
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
    }

    /// Celebration when the listener finishes every unread feed item: confetti
    /// plus a compact "caught up" card at the bottom (above the player), so it
    /// never covers the text you were reading. Shown briefly before dropping back.
    private var feedFinishedCelebration: some View {
        ZStack(alignment: .bottom) {
            ConfettiView()   // transient particles; doesn't block reading
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You're all caught up").font(.headline)
                    Text("You've heard everything in your feeds.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            .padding(.horizontal, 20)
            .padding(.bottom, controlsHeight + 16)
        }
        .transition(.opacity)
    }

    private var completionBanner: some View {
        Text("Finished — marked as read")
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.green.opacity(0.9), in: Capsule())
            .foregroundStyle(.white)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                withAnimation { showCompletion = false }
            }
    }
}

/// iPhone full-screen "Now Playing": the shared reading/player surface plus a
/// collapse button that hides it back down to the mini-player. Presented over the
/// app, so playback continues underneath when collapsed. (On iPad the same
/// `PlayerDetailContent` lives permanently in the split view's detail column, so
/// there's nothing to collapse and this wrapper isn't used.)
struct NowPlayingView: View {
    @EnvironmentObject private var player: EmailPlayerViewModel

    var body: some View {
        NavigationStack {
            PlayerDetailContent()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            // Abandoning a preview returns focus to what's playing.
                            if player.staged != nil { player.discardStaged() }
                            player.isExpanded = false
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                    }
                }
        }
    }
}

/// Reports the floating transport panel's height up to the transcript so it can
/// reserve exactly that much bottom space.
private struct ControlsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 140
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Sentence

/// Where a sentence sits within a run of consecutive saved-highlight sentences,
/// so the run can be drawn as one continuous block instead of separate boxes.
private enum HighlightRunPosition { case none, single, first, middle, last }

/// Per-block highlight rendering info derived from saved highlights.
private struct NotedInfo {
    var position: HighlightRunPosition = .none
    var showMarker = false
    var markerIsNote = false
}

private struct SentenceText: View {
    let text: String
    let isCurrent: Bool
    var notedPosition: HighlightRunPosition = .none
    var showMarker: Bool = false
    var markerIsNote: Bool = false
    let wordRange: NSRange?
    var fontSize: CGFloat = 22
    var listDepth: Int = 0
    var bulletMarker: String = ""
    /// A line the listener muted with a skip rule: shown struck-through and dimmed
    /// so it's clearly not read, but still visible and tappable to un-skip.
    var isSkipped: Bool = false
    /// True while the skip choices for this exact sentence are visible.
    var isPendingSkip: Bool = false

    private var isRTL: Bool { LanguageTools.isRightToLeft(text) }
    private var isNoted: Bool { notedPosition != .none }

    /// Extra leading inset per nesting level so nested bullets sit in from their
    /// parent. Level 1 isn't indented; each deeper level adds a step.
    private var listIndent: CGFloat { CGFloat(max(listDepth - 1, 0)) * 20 }

    var body: some View {
        sentenceRow
            .lineSpacing(5)
            .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .padding(isRTL ? .trailing : .leading, listIndent)
            .frame(maxWidth: .infinity, alignment: isRTL ? .trailing : .leading)
            // One marker for the whole highlight (on its first sentence), so a
            // passage spanning several sentences doesn't look like several notes.
            .overlay(alignment: isRTL ? .topLeading : .topTrailing) {
                if isPendingSkip {
                    Image(systemName: "speaker.slash.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(5)
                } else if showMarker {
                    Image(systemName: markerIsNote ? "note.text" : "highlighter")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(5)
                }
            }
            .foregroundStyle(isSkipped ? .secondary : (isCurrent || isNoted ? .primary : .secondary))
            .opacity(isSkipped ? 0.55 : 1)
    }

    /// The sentence text, with a bullet/number in front when it's the start of a
    /// list item. The marker is its own `Text` so it never shifts the word-range
    /// underline, which indexes into the spoken `text`.
    @ViewBuilder
    private var sentenceRow: some View {
        if bulletMarker.isEmpty {
            Text(attributed)
                .font(.system(size: fontSize))
                .strikethrough(isSkipped, color: .secondary)
                .multilineTextAlignment(isRTL ? .trailing : .leading)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(bulletMarker)
                    .font(.system(size: fontSize))
                    .foregroundStyle(.secondary)
                Text(attributed)
                    .font(.system(size: fontSize))
                    .strikethrough(isSkipped, color: .secondary)
                    .multilineTextAlignment(isRTL ? .trailing : .leading)
                    .frame(maxWidth: .infinity, alignment: isRTL ? .trailing : .leading)
            }
        }
    }

    private var attributed: AttributedString {
        var string = AttributedString(text)
        // Put the highlight on the glyph run itself rather than the sentence
        // container. SwiftUI then paints each wrapped line only as far as its text,
        // leaving trailing whitespace and gaps between paragraphs untouched.
        if isPendingSkip {
            string.backgroundColor = Color.orange.opacity(0.18)
        } else if isNoted {
            string.backgroundColor = Color.yellow.opacity(0.30)
        }
        guard isCurrent, let wordRange,
              let swiftRange = Range(wordRange, in: text),
              let attrRange = Range(swiftRange, in: string) else {
            return string
        }
        // Just recolor the word being read — no bold (which would nudge the layout
        // as each word thickens and thins).
        string[attrRange].foregroundColor = .accentColor
        return string
    }
}

// MARK: - Image block

private struct ImageBlockView: View {
    let image: InlineImage
    let isCurrent: Bool
    let onSkip: () -> Void

    var body: some View {
        // Show the image whenever there's a URL we can try to load. We intentionally
        // do NOT keep a "failed" flag: the old code latched failure from inside the
        // AsyncImage builder (mutating state during a view update), and on iPad the
        // split-view's extra layout passes cancel the in-flight load — that
        // cancellation counted as a failure and permanently collapsed *every* image.
        if let url = image.remoteURL {
            imageContent(url: url)
        }
    }

    private func imageContent(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFit()
                    case .failure:
                        // Genuine fetch failure (rare — decorative images and tracking
                        // pixels are filtered out upstream). Keep this minimal and
                        // retryable rather than turning it into another image card.
                        failurePlaceholder
                    case .empty:
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                    @unknown default:
                        failurePlaceholder
                    }
                }

                if isCurrent {
                    Button(action: onSkip) {
                        Label("Skip", systemImage: "forward.end.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(8)
                    .accessibilityLabel("Skip image")
                }
            }

            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var caption: String? {
        guard let alt = image.altText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !alt.isEmpty else { return nil }
        let genericLabels = ["image", "photo", "graphic"]
        return genericLabels.contains(alt.lowercased()) ? nil : alt
    }

    private var failurePlaceholder: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
            Text((image.altText?.isEmpty == false ? image.altText : nil) ?? "Image unavailable")
                .lineLimit(2)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 80)
    }
}
