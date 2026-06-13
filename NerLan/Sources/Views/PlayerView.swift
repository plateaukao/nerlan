import SwiftUI

/// Full-screen player sheet with transport, favorite and download controls.
struct PlayerView: View {
    @EnvironmentObject var player: PlayerManager
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var favorites: FavoritesStore
    @Environment(\.dismiss) private var dismiss

    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0
    @State private var showAttachment = false

    var body: some View {
        VStack(spacing: 24) {
            Capsule()
                .fill(Color(.systemGray4))
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            Spacer()

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

            // Scrubber
            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubTime : player.currentTime },
                        set: { scrubTime = $0 }
                    ),
                    in: 0...max(player.duration, 1)
                ) { editing in
                    if editing {
                        scrubTime = player.currentTime
                    } else {
                        player.seek(to: scrubTime)
                    }
                    isScrubbing = editing
                }
                HStack {
                    Text(timeString(isScrubbing ? scrubTime : player.currentTime))
                    Spacer()
                    Text(timeString(player.duration))
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
                            showAttachment = true
                        } label: {
                            Label("講義", systemImage: "info.circle")
                        }
                    }

                    if downloads.isDownloaded(episodeId: record.id) {
                        Label("已下載", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if let p = downloads.progress[record.id] {
                        ProgressView(value: p)
                            .frame(width: 80)
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

            Spacer()
        }
        .presentationDetents([.large])
        .sheet(isPresented: $showAttachment) {
            if let record = player.current {
                AttachmentView(title: record.title, attachments: record.pdfAttachments)
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
