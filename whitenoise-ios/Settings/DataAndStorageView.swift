import SwiftUI

/// Data-and-storage preferences: outbound media quality and the per-type ×
/// per-network auto-download matrix. Semantics are shared with the Android
/// client so the same choices mean the same behavior on both platforms.
struct DataAndStorageView: View {
    @State private var quality = MediaQualityStore.quality()
    @State private var store = MediaAutoDownloadStore.shared
    @State private var remoteGIFStore = RemoteGIFLoadingStore.shared
    @AccessibilityFocusState(for: .voiceOver) private var focusedAutoDownload: AutoDownloadFocus?

    private enum AutoDownloadFocus: Hashable {
        case media(MediaAutoDownloadType)
        case reset
    }

    var body: some View {
        Form {
            Section {
                ForEach(MediaAutoDownloadType.allCases, id: \.self) { type in
                    NavigationLink {
                        AutoDownloadLevelView(type: type, title: typeTitle(type), store: store)
                    } label: {
                        HStack {
                            Text(typeTitle(type))
                            Spacer()
                            Text(Self.levelTitle(store.matrix.level(for: type)))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityFocused($focusedAutoDownload, equals: .media(type))
                }
                if store.matrix != .defaultMatrix {
                    Button {
                        if focusedAutoDownload == .reset {
                            focusedAutoDownload = .media(.image)
                        }
                        store.resetToDefaults()
                    } label: {
                        Text("Reset Auto-Download Settings")
                    }
                    .accessibilityFocused($focusedAutoDownload, equals: .reset)
                }
            } header: {
                Text("Auto-Download")
            } footer: {
                Text("Media that doesn’t download automatically can be downloaded by tapping it.")
            }

            Section {
                WNToggle(
                    "Automatically Load Remote GIFs",
                    isOn: Binding(
                        get: { remoteGIFStore.automaticallyLoads },
                        set: { remoteGIFStore.setAutomaticallyLoads($0) }
                    )
                )
            } header: {
                Text("Remote Media")
            } footer: {
                Text("Loading GIFs shares your IP address and the requested GIF with GIPHY. When off, tap a GIF to load it.")
            }

            Section {
                NavigationLink {
                    SentMediaQualityView(quality: $quality)
                } label: {
                    LabeledContent("Sent Media Quality", value: Self.qualityTitle(quality))
                }
            } header: {
                Text("Sent Media")
            } footer: {
                Text("Set the quality of photos and voice notes you send.")
            }
        }
        .productScreen(.settings, section: .storage)
        .localizedNavigationTitle("Data Usage")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Shares choice labels with the picker; Wi-Fi Only also excludes metered connections.
    static func levelTitle(_ level: MediaAutoDownloadLevel) -> String {
        switch level {
        case .never: return L10n.string("Never")
        case .wifiOnly: return L10n.string("Wi-Fi Only")
        case .wifiAndCellular: return L10n.string("Wi-Fi and Cellular")
        }
    }

    /// Keeps the summary and picker labels aligned after the store normalizes legacy values.
    fileprivate static func qualityTitle(_ level: MediaQuality) -> String {
        switch level {
        case .standard: return L10n.string("Standard")
        case .high: return L10n.string("High")
        }
    }

    private func typeTitle(_ type: MediaAutoDownloadType) -> String {
        switch type {
        case .image: return L10n.string("Photos")
        case .audio: return L10n.string("Audio")
        case .video: return L10n.string("Videos")
        case .document: return L10n.string("Files")
        }
    }
}

private struct SentMediaQualityView: View {
    @Binding var quality: MediaQuality

    var body: some View {
        List {
            Section {
                qualityRow(.standard, subtitle: L10n.string("Smaller files, less data"))
                qualityRow(.high, subtitle: L10n.string("Higher quality, larger files"))
            } header: {
                Text("Photos and Voice Notes")
            } footer: {
                Text("Identifying photo metadata, including location, is removed at both quality levels. Videos are sent unchanged.")
            }
        }
        .localizedNavigationTitle("Sent Media Quality")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Saves immediately and keeps the picker open so the selected choice confirms the change.
    private func qualityRow(_ level: MediaQuality, subtitle: String) -> some View {
        Button {
            quality = level
            MediaQualityStore.setQuality(level)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(DataAndStorageView.qualityTitle(level))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if quality == level {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(quality == level ? .isSelected : [])
    }
}

/// Radio-style level picker for one media type: Never / Wi-Fi Only /
/// Wi-Fi and Cellular, checkmark on the current choice.
private struct AutoDownloadLevelView: View {
    let type: MediaAutoDownloadType
    let title: String
    let store: MediaAutoDownloadStore

    var body: some View {
        List {
            Section {
                ForEach(MediaAutoDownloadLevel.allCases, id: \.self) { level in
                    Button {
                        store.setLevel(level, for: type)
                    } label: {
                        HStack {
                            Text(DataAndStorageView.levelTitle(level))
                                .foregroundStyle(.primary)
                            Spacer()
                            if store.matrix.level(for: type) == level {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text(helperText)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var helperText: String {
        switch type {
        case .image:
            L10n.string("Choose when photos download automatically. Wi-Fi Only excludes personal hotspots and connections using Low Data Mode.")
        case .audio:
            L10n.string("Choose when audio, including voice notes, downloads automatically. Wi-Fi Only excludes personal hotspots and connections using Low Data Mode.")
        case .video:
            L10n.string("Choose when videos download automatically. Wi-Fi Only excludes personal hotspots and connections using Low Data Mode.")
        case .document:
            L10n.string("Choose when files download automatically. Wi-Fi Only excludes personal hotspots and connections using Low Data Mode.")
        }
    }
}
