import SwiftUI

/// Full-screen player sheet with transport, favorite and download controls.
struct PlayerView: View {
    @EnvironmentObject var player: PlayerManager
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var favorites: FavoritesStore
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var study: StudyPanel
    @EnvironmentObject var ai: AIContentStore
    @Environment(\.dismiss) private var dismiss
    /// A compact vertical size class means a phone in landscape: the sheet is then
    /// too short for the cover + header, so they (and the caption toggle) are dropped
    /// so the transport and action rows still fit. Portrait and iPad are unchanged.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// The scrubber needs the high-frequency playback position; observe the clock
    /// directly so only this sheet re-renders on each tick.
    @ObservedObject private var clock = PlayerManager.shared.clock

    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0
    @State private var showAttachment = false

    /// Caption mode: when on, the transcript takes over the cover/title area as a
    /// follow-along. Available only when the playing episode has a transcript with
    /// timestamp cues; reset per-episode so each starts on the cover.
    @State private var captionMode = false
    @State private var captionCues: [TranscriptCue]?

    /// Whether the caption toggle should appear: a cued transcript exists.
    private var captionsAvailable: Bool { !(captionCues?.isEmpty ?? true) }

    /// Cheap per-tick signal that flips when the playing episode or its transcript
    /// existence changes, so the (decoding) cue refresh runs only on real changes —
    /// not on every clock tick that re-renders this sheet.
    private var transcriptToken: String {
        guard let id = player.current?.id else { return "" }
        return "\(id)|\(ai.hasTranscript(id))"
    }

    private func refreshCaptionCues() {
        guard let id = player.current?.id, ai.hasTranscript(id) else { captionCues = nil; return }
        captionCues = ai.transcriptCues(id)
    }

    var body: some View {
        VStack(spacing: 24) {
            Capsule()
                .fill(Color(.systemGray4))
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            let compactHeight = verticalSizeClass == .compact
            // Caption mode swaps the cover area for the synced transcript; with the
            // header hidden in phone landscape there's nowhere for it to live, so
            // disable it (and hide its toggle below) when compact.
            let showCaptions = captionMode && captionsAvailable && !compactHeight
            if showCaptions, let record = player.current {
                // Take over the cover/title/program/language area with the synced
                // transcript; its 關閉 button (or the 字幕 toggle) exits caption mode.
                TranscriptView(record: record,
                               text: ai.transcriptText(record.id) ?? "",
                               cues: captionCues,
                               onClose: { captionMode = false })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()

                // In phone landscape the sheet is too short for the cover + header,
                // so drop them; the controls then fit without scrolling. The leading
                // and trailing Spacers keep the controls centered.
                if !compactHeight {
                    CoverImage(urlString: player.current?.coverURL, size: 240)
                        .shadow(radius: 8)

                    VStack(spacing: 6) {
                        Text(player.current?.title ?? "")
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)
                        Text(player.current?.programName ?? "")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(player.current?.language ?? "")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal)
                }
            }

            // Scrubber
            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubTime : clock.currentTime },
                        set: { scrubTime = $0 }
                    ),
                    in: 0...max(clock.duration, 1)
                ) { editing in
                    if editing {
                        scrubTime = clock.currentTime
                    } else {
                        player.seek(to: scrubTime)
                    }
                    isScrubbing = editing
                }
                HStack {
                    Text(timeString(isScrubbing ? scrubTime : clock.currentTime))
                    Spacer()
                    Text(timeString(clock.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)

            // Transport
            HStack(spacing: 36) {
                Button { player.previous() } label: {
                    Image(systemName: "backward.end.fill").font(.title2)
                }
                .disabled(!player.hasPrevious)

                Button { player.skip(-15) } label: {
                    Image(systemName: "gobackward.15").font(.title2)
                }

                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                }

                Button { player.skip(15) } label: {
                    Image(systemName: "goforward.15").font(.title2)
                }

                Button { player.next() } label: {
                    Image(systemName: "forward.end.fill").font(.title2)
                }
                .disabled(!player.hasNext)
            }

            // Repeat / speed / favorite / download
            if let record = player.current {
                HStack(spacing: 32) {
                    Button {
                        player.cycleRepeatMode()
                    } label: {
                        Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                            .foregroundStyle(player.repeatMode == .off ? Color.secondary : Color.accentColor)
                    }

                    Menu {
                        ForEach(PlayerManager.availableRates, id: \.self) { rate in
                            Button {
                                player.playbackRate = rate
                            } label: {
                                if rate == player.playbackRate {
                                    Label(rateLabel(rate), systemImage: "checkmark")
                                } else {
                                    Text(rateLabel(rate))
                                }
                            }
                        }
                    } label: {
                        Label(rateLabel(player.playbackRate), systemImage: "gauge.with.needle")
                    }

                    Button {
                        favorites.toggle(record)
                    } label: {
                        Label("收藏",
                              systemImage: favorites.isFavorite(episodeId: record.id) ? "heart.fill" : "heart")
                            .foregroundStyle(.pink)
                    }

                    if !record.pdfAttachments.isEmpty {
                        Button {
                            if StudyPanel.usesSidePanel {
                                study.item = .attachment(record)
                                dismiss()
                            } else {
                                showAttachment = true
                            }
                        } label: {
                            Label("講義", systemImage: "info.circle")
                        }
                    }

                    if downloads.isDownloaded(episodeId: record.id) {
                        Label("已下載", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if downloads.isDownloading(episodeId: record.id) {
                        ProgressView()
                    } else {
                        Button {
                            downloads.download(record)
                        } label: {
                            Label("下載", systemImage: "arrow.down.circle")
                        }
                    }
                }
                .font(.subheadline)
            }

            // AI tools (caption / transcript / handout) — only once an API key is set.
            if let record = player.current, settings.hasAPIKey {
                HStack(spacing: 44) {
                    // Caption toggle: only when the transcript carries timestamps,
                    // so the follow-along has cues to highlight/scroll. Hidden in
                    // phone landscape (compact), where caption mode is disabled.
                    if captionsAvailable && !compactHeight {
                        Button {
                            captionMode.toggle()
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: captionMode ? "text.below.photo.fill" : "text.below.photo")
                                    .font(.title3)
                                Text("字幕").font(.caption2)
                            }
                            .foregroundStyle(captionMode ? Color.accentColor : Color.primary)
                        }
                        .buttonStyle(.borderless)
                    }
                    AIActionButton(kind: .transcript, record: record)
                    AIActionButton(kind: .handout, record: record)
                }
                .foregroundStyle(.primary)
            }

            if !showCaptions { Spacer() }
        }
        .presentationDetents([.large])
        .onAppear { refreshCaptionCues() }
        .onChange(of: transcriptToken) { _, _ in refreshCaptionCues() }
        .onChange(of: player.current?.id) { _, _ in captionMode = false }
        .sheet(isPresented: $showAttachment) {
            if let record = player.current {
                AttachmentView(title: record.title, attachments: record.pdfAttachments,
                               onClose: { showAttachment = false })
                    .appEnvironment()
            }
        }
    }

    private func rateLabel(_ rate: Float) -> String {
        rate == rate.rounded() ? String(format: "%.0f×", rate) : String(format: "%g×", rate)
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
