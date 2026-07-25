import SwiftUI
import UIKit

/// A full-bleed watch remote for the phone's reader. The sender artwork starts as
/// the hero image; as playback reaches inline email images, those replace it and
/// remain visible until the next image, mirroring the iPhone lock screen.
struct WatchNowPlayingView: View {
    @ObservedObject private var bridge = WatchConnectivityBridge.shared
    @Namespace private var metadataAnimation
    @State private var metadataExpanded = false
    @State private var showHighlightConfirmation = false

    private var state: NowPlayingState? {
        guard let state = bridge.nowPlaying, state.hasContent else { return nil }
        return state
    }

    var body: some View {
        Group {
            if let state {
                remote(state)
            } else {
                idle
            }
        }
        .overlay(alignment: .top) {
            if showHighlightConfirmation { highlightToast }
        }
    }

    // MARK: - Remote

    private func remote(_ state: NowPlayingState) -> some View {
        GeometryReader { geometry in
            ZStack {
                WatchHeroArtwork(
                    inlineURL: state.artworkURL,
                    senderAddress: state.senderAddress
                )
                .frame(width: geometry.size.width, height: geometry.size.height)

                LinearGradient(
                    colors: [
                        .black.opacity(0.58),
                        .clear,
                        .black.opacity(0.18),
                        .black.opacity(0.88)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                playerChrome(state)

                if metadataExpanded {
                    expandedMetadata(state)
                        .zIndex(4)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.35), value: state.artworkURL)
    }

    private func playerChrome(_ state: NowPlayingState) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 5) {
                metadataButton(state)
                Spacer(minLength: 2)
                topControl("forward.end.fill", label: "Next email or feed item") {
                    bridge.send(command: .nextItem)
                }
                topControl("highlighter", label: "Highlight") {
                    bridge.send(command: .highlight)
                    flashHighlight()
                }
            }

            Spacer(minLength: 12)

            VStack(spacing: 5) {
                HStack {
                    Text(elapsedLabel(state))
                    Spacer()
                    Text("-\(remainingLabel(state))")
                }
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

                ProgressView(value: state.progress.clampedUnit)
                    .tint(.white)

                HStack(spacing: 18) {
                    transportControl("backward.fill", label: "Previous sentence") {
                        bridge.send(command: .previousSentence)
                    }
                    transportControl(
                        state.isPlaying ? "pause.fill" : "play.fill",
                        label: state.isPlaying ? "Pause" : "Play",
                        prominent: true
                    ) {
                        bridge.send(command: state.isPlaying ? .pause : .play)
                    }
                    transportControl("forward.fill", label: "Next sentence") {
                        bridge.send(command: .nextSentence)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 5)
        }
        .padding(.horizontal, 7)
        .padding(.top, 5)
    }

    private func metadataButton(_ state: NowPlayingState) -> some View {
        Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                metadataExpanded = true
            }
        } label: {
            HStack(spacing: 5) {
                WatchSenderArtwork(address: state.senderAddress)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 0) {
                    Text(state.sender)
                        .font(.system(size: 10, weight: .bold))
                        .lineLimit(1)
                    Text(state.subject)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.white)
            .padding(5)
            .background(.black.opacity(0.42), in: Capsule())
            .matchedGeometryEffect(id: "metadata", in: metadataAnimation)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 105)
        .accessibilityLabel("\(state.sender), \(state.subject). Show full details")
    }

    private func expandedMetadata(_ state: NowPlayingState) -> some View {
        Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                metadataExpanded = false
            }
        } label: {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        WatchSenderArtwork(address: state.senderAddress)
                            .frame(width: 38, height: 38)
                        Text(state.sender)
                            .font(.headline)
                            .multilineTextAlignment(.leading)
                    }

                    Text(state.subject)
                        .font(.title3.weight(.bold))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if let sentence = state.currentSentence, !sentence.isEmpty {
                        Divider().overlay(.white.opacity(0.35))
                        Text(sentence)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.82))
                            .multilineTextAlignment(.leading)
                    }

                    Text("Tap to return to player")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .background(.black.opacity(0.92))
            .matchedGeometryEffect(id: "metadata", in: metadataAnimation)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .accessibilityLabel("Full email details. Tap to return to player")
    }

    private func topControl(_ symbol: String, label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 31, height: 31)
                .background(.black.opacity(0.42), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func transportControl(_ symbol: String, label: String,
                                  prominent: Bool = false,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 20 : 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: prominent ? 43 : 34, height: prominent ? 43 : 34)
                .background(
                    prominent ? Color.white.opacity(0.22) : Color.black.opacity(0.32),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func elapsedLabel(_ state: NowPlayingState) -> String {
        let remaining = max(state.secondsRemaining, 0)
        let total = state.progress > 0
            ? Int(Double(remaining) / max(1 - state.progress, 0.01))
            : remaining
        let elapsed = max(total - remaining, 0)
        return durationLabel(elapsed)
    }

    private func remainingLabel(_ state: NowPlayingState) -> String {
        durationLabel(max(state.secondsRemaining, 0))
    }

    private func durationLabel(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Idle

    private var idle: some View {
        ZStack {
            LinearGradient(
                colors: [Color.orange.opacity(0.35), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 8) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.title2)
                Text("Nothing playing")
                    .font(.headline)
                Text("Start an email or feed on your iPhone.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }

    private var highlightToast: some View {
        Label("Highlighted", systemImage: "highlighter")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.yellow, in: Capsule())
            .foregroundStyle(.black)
            .task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                showHighlightConfirmation = false
            }
    }

    private func flashHighlight() {
        showHighlightConfirmation = true
    }
}

private extension Double {
    var clampedUnit: Double { min(max(self, 0), 1) }
}

/// Full-screen watch artwork. Inline images take priority once playback reaches
/// them; before that, the sender's avatar/logo fills the background.
private struct WatchHeroArtwork: View {
    let inlineURL: URL?
    let senderAddress: String
    @StateObject private var senderLoader = WatchArtworkLoader()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.gray.opacity(0.22)

                if let inlineURL {
                    AsyncImage(url: inlineURL) { phase in
                        if case .success(let image) = phase {
                            image
                                .resizable()
                                .scaledToFill()
                                .transition(.opacity)
                        } else if let senderImage = senderLoader.image {
                            Image(uiImage: senderImage)
                                .resizable()
                                .scaledToFill()
                        } else {
                            fallback
                        }
                    }
                    .id(inlineURL)
                } else if let senderImage = senderLoader.image {
                    Image(uiImage: senderImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    fallback
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .task(id: senderAddress) {
            await senderLoader.load(address: senderAddress)
        }
    }

    private var fallback: some View {
        ZStack {
            LinearGradient(
                colors: [Color.orange.opacity(0.5), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "envelope.fill")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}

private struct WatchSenderArtwork: View {
    let address: String
    @StateObject private var loader = WatchArtworkLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle().fill(.white.opacity(0.18))
                    Image(systemName: "envelope.fill")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .clipShape(Circle())
        .task(id: address) { await loader.load(address: address) }
    }
}

@MainActor
private final class WatchArtworkLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    private var loadedAddress: String?

    func load(address: String) async {
        let key = address.lowercased()
        guard !key.isEmpty, key != loadedAddress else { return }
        loadedAddress = key
        image = nil
        for url in SenderImage.candidateURLs(forAddress: key) {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let candidate = UIImage(data: data) else { continue }
            image = candidate
            return
        }
    }
}
