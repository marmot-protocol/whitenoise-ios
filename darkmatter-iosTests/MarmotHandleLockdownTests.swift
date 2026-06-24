import Foundation
import Testing
@testable import darkmatter_ios

/// #395 — final "handle lockdown" step of the thin-shell refactor. All Marmot
/// access from feature code (views / view-models / stores) must go through
/// `MarmotClient`'s wrappers and subscription factories; the raw `Marmot`
/// handle must be unreachable outside the documented seam files:
/// `AppState.swift` (lifecycle/bootstrap seam),
/// `NotificationCoordinator.swift` (notification orchestration seam), and
/// `MarmotClient.swift` (the wrapper that owns the handle).
///
/// This is a source-guard test by design: the "no raw handle in feature code"
/// boundary cannot be observed at runtime, matching the existing FFI-boundary
/// enforcement in `MarmotClientStorageReadOffloadTests`.
struct MarmotHandleLockdownTests {

    /// The seam files allowed to touch the raw `Marmot` handle. `MarmotClient`
    /// owns it; `AppState` is the lifecycle/bootstrap composition seam;
    /// `RuntimeLifecycle` is the runtime suspend/resume + bootstrap seam carved
    /// out of `AppState` (Phase 2); and `NotificationCoordinator` owns
    /// notification subscription/push orchestration. Every other file in the app
    /// target must route through `currentMarmotClient()` and the `MarmotClient`
    /// wrappers.
    private static let seamFiles: Set<String> = [
        "darkmatter-ios/Core/AppState.swift",
        "darkmatter-ios/Core/RuntimeLifecycle.swift",
        "darkmatter-ios/Core/NotificationCoordinator.swift",
        "darkmatter-ios/Core/MarmotClient.swift",
    ]

    /// Matches a raw-handle access — the `marmot` property read on any receiver
    /// (`appState.marmot`, `client.marmot`, `appState.client?.marmot`,
    /// `currentMarmotClient().marmot`, `someLocal.marmot`, …) — while NOT
    /// matching the `MarmotKit` module import or a `.marmotKit`-style longer
    /// identifier. A leading `.` with a word boundary after `marmot` is the
    /// distinguishing shape; `(?![A-Za-z0-9_])` rejects `.marmotKit`.
    private static let rawHandlePattern = #"\.marmot(?![A-Za-z0-9_])"#

    /// Scanning the WHOLE app target (not a hardcoded offender list) is what
    /// makes the boundary actually enforced: a brand-new feature file that
    /// reaches `something.marmot` fails this test the moment it lands, even
    /// though it was never on any list.
    @Test func noFeatureFileTouchesTheRawMarmotHandle() throws {
        let appRoot = Self.appTargetRoot
        let offenders = try Self.swiftFiles(under: appRoot)
            .filter { !Self.seamFiles.contains($0.relativePath) }
            .filter { file in
                let source = try? String(contentsOf: file.url, encoding: .utf8)
                return source.map { Self.containsRawHandleAccess($0) } ?? false
            }
            .map(\.relativePath)
            .sorted()

        #expect(
            offenders.isEmpty,
            """
            These feature files reach the raw Marmot handle (a `.marmot` access \
            outside AppState.swift / RuntimeLifecycle.swift / \
            NotificationCoordinator.swift / MarmotClient.swift). \
            Route them through `appState.currentMarmotClient()` and the `MarmotClient` \
            wrappers (#395):
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    /// Sanity check on the scanner itself: the two seam files DO contain raw
    /// `.marmot` accesses (otherwise the guard above would be vacuously green if
    /// the regex or enumeration silently broke). If this ever fails, the
    /// enumeration root or the pattern regressed — not the boundary.
    @Test func scannerSeesRawHandleInTheSeamFiles() throws {
        for relative in Self.seamFiles {
            let url = Self.appTargetRoot.appendingPathComponent(
                String(relative.dropFirst("darkmatter-ios/".count))
            )
            let source = try String(contentsOf: url, encoding: .utf8)
            #expect(
                Self.containsRawHandleAccess(source),
                "Scanner found no `.marmot` access in seam file \(relative); the regex or enumeration root regressed"
            )
        }
    }

    /// The wrappers and subscription factories that the routing depends on must
    /// exist on `MarmotClient`, and `MarmotClient` must conform to
    /// `AccountRelayListManaging` so the relay-save path takes `manager: client`.
    @Test func marmotClientExposesTheRoutingSurface() throws {
        let source = try String(
            contentsOf: Self.appTargetRoot.appendingPathComponent("Core/MarmotClient.swift"),
            encoding: .utf8
        )

        for wrapper in [
            #"func createGroup\("#,
            #"func setGroupArchived\("#,
            #"func sendText\("#,
            #"func replyToMessage\("#,
            #"func uploadMedia\("#,
            #"func downloadMedia\("#,
            #"func leaveGroup\("#,
            #"func groupMembers\("#,
            #"func groupDetails\("#,
            #"func groupManagementState\("#,
            #"func groupMlsState\("#,
            #"func groupPushDebugInfo\("#,
            #"func deleteMessage\("#,
            #"func reactToMessage\("#,
            #"func unreactFromMessage\("#,
            #"func publishUserProfile\("#,
            #"func refreshProfile\("#,
            #"func accountKeyPackages\("#,
            #"func publishNewKeyPackage\("#,
            #"func deleteAccountKeyPackage\("#,
            #"func npub\(accountIdHex: String\) -> String\?"#,
            #"func subscribeEvents\(\) -> EventsSubscription"#,
            #"func subscribeChatList\("#,
            #"func subscribeTimelineMessages\("#,
            #"func subscribeGroupState\("#,
            #"func watchAgentTextStream\("#,
        ] {
            #expect(
                source.range(of: wrapper, options: .regularExpression) != nil,
                "MarmotClient is missing the \(wrapper) routing wrapper"
            )
        }

        #expect(
            source.range(of: #"extension MarmotClient: AccountRelayListManaging"#, options: .regularExpression) != nil,
            "MarmotClient no longer conforms to AccountRelayListManaging; RelaysViewModel cannot pass manager: client"
        )
    }

    // MARK: - Source scanning helpers

    /// Absolute path of the `darkmatter-ios/` app source root, derived from this
    /// test file's location (`darkmatter-iosTests/MarmotHandleLockdownTests.swift`
    /// → repo root → `darkmatter-ios`).
    private static var appTargetRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()   // darkmatter-iosTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("darkmatter-ios")
    }

    private struct SourceFile {
        let url: URL
        /// Repo-relative path, e.g. `darkmatter-ios/Chats/ChatsListView.swift`.
        let relativePath: String
    }

    /// Recursively enumerate every `.swift` file under the app target.
    private static func swiftFiles(under root: URL) throws -> [SourceFile] {
        let repoRoot = root.deletingLastPathComponent()
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys
        ) else {
            return []
        }
        var files: [SourceFile] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(
                of: repoRoot.path + "/",
                with: ""
            )
            files.append(SourceFile(url: url, relativePath: relative))
        }
        return files
    }

    private static func containsRawHandleAccess(_ source: String) -> Bool {
        source.range(of: rawHandlePattern, options: .regularExpression) != nil
    }
}
