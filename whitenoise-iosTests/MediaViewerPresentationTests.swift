import Testing
@testable import whitenoise_ios

@Suite("Media viewer presentation")
struct MediaViewerPresentationTests {

    @Test func chromeStartsVisibleSoControlsAreReachableWithoutATap() {
        #expect(MediaViewerChrome().isVisible)
    }

    @Test func togglingChromeAlternatesAndReturnsToTheStartingState() {
        var chrome = MediaViewerChrome()

        chrome.toggle()
        #expect(!chrome.isVisible)

        chrome.toggle()
        #expect(chrome.isVisible)
    }

    @Test func savingAndSharingWaitForDecryptedBytes() {
        let pending = MediaViewerControlState(
            hasPreparedMedia: false,
            hasForwardingContext: true
        )

        #expect(!pending.canSave)
        #expect(!pending.canShare)
    }

    @Test func preparedMediaEnablesSavingAndSharing() {
        let ready = MediaViewerControlState(
            hasPreparedMedia: true,
            hasForwardingContext: false
        )

        #expect(ready.canSave)
        #expect(ready.canShare)
    }

    @Test func forwardingNeedsBothPreparedMediaAndADestinationProvider() {
        #expect(MediaViewerControlState(
            hasPreparedMedia: true,
            hasForwardingContext: true
        ).canForward)

        #expect(!MediaViewerControlState(
            hasPreparedMedia: false,
            hasForwardingContext: true
        ).canForward)

        #expect(!MediaViewerControlState(
            hasPreparedMedia: true,
            hasForwardingContext: false
        ).canForward)
    }
}
