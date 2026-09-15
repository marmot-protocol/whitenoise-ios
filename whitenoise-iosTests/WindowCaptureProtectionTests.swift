import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
struct WindowCaptureProtectionTests {
    @Test func foregroundContentRemainsVisibleWithoutCapture() {
        #expect(!ScreenPrivacyPolicy.shouldCover(enabled: true, sceneIsActive: true, isCaptured: false))
    }

    @Test func backgroundAndRecordingRequireACover() {
        #expect(ScreenPrivacyPolicy.shouldCover(enabled: true, sceneIsActive: false, isCaptured: false))
        #expect(ScreenPrivacyPolicy.shouldCover(enabled: true, sceneIsActive: true, isCaptured: true))
        #expect(ScreenPrivacyPolicy.shouldCover(enabled: true, sceneIsActive: false, isCaptured: true))
    }

    @Test func disablingPrivacyAllowsRecordingAndAppSwitcherPreview() {
        #expect(!ScreenPrivacyPolicy.shouldCover(enabled: false, sceneIsActive: true, isCaptured: true))
        #expect(!ScreenPrivacyPolicy.shouldCover(enabled: false, sceneIsActive: false, isCaptured: false))
    }

    @Test func shieldLeavesContentWindowAndKeyWindowUntouched() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let keyWindow = scene.keyWindow
        let content = UIWindow(windowScene: scene)
        let originalSuperlayer = content.layer.superlayer
        let protection = WindowCaptureProtection()
        defer { protection.removeShield() }

        protection.update(enabled: true, window: content, sceneIsActive: false, isCaptured: false)
        let shield = try #require(protection.shieldWindow)
        #expect(protection.isActive)
        #expect(shield.windowScene === scene)
        #expect(shield.windowLevel > .alert)
        #expect(scene.keyWindow === keyWindow)
        #expect(content.layer.superlayer === originalSuperlayer)
        #expect(shield.rootViewController?.view.backgroundColor == .systemBackground)

        protection.update(enabled: true, window: content, sceneIsActive: true, isCaptured: true)
        #expect(protection.isActive)
        #expect(protection.shieldWindow === shield)
        protection.update(enabled: true, window: content, sceneIsActive: true, isCaptured: false)
        #expect(!protection.isActive)
        #expect(scene.keyWindow === keyWindow)
        protection.update(enabled: false, window: content, sceneIsActive: false, isCaptured: true)
        #expect(protection.shieldWindow == nil)
        #expect(shield.isHidden)
    }

    @Test func sceneNotificationsCoverSynchronouslyAndIgnoreOtherScenes() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let content = UIWindow(windowScene: scene)
        let center = NotificationCenter()
        let observer = ScreenPrivacyObserverView(notificationCenter: center)
        content.addSubview(observer)
        observer.isEnabled = true
        defer { observer.protection.removeShield() }

        center.post(name: UIScene.didActivateNotification, object: scene)
        #expect(!observer.protection.isActive)
        center.post(name: UIScene.willDeactivateNotification, object: NSObject())
        #expect(!observer.protection.isActive)
        center.post(name: UIScene.willDeactivateNotification, object: scene)
        #expect(observer.protection.isActive)
        observer.refresh()
        #expect(observer.protection.isActive)
        center.post(name: UIScene.didActivateNotification, object: scene)
        #expect(!observer.protection.isActive)
        center.post(name: UIScene.didEnterBackgroundNotification, object: scene)
        #expect(observer.protection.isActive)
        observer.removeFromSuperview()
        #expect(!observer.protection.isActive)
    }

    @Test func detachingOrReplacingWindowRemovesOldShield() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let protection = WindowCaptureProtection()
        defer { protection.removeShield() }
        let first = UIWindow(windowScene: scene)
        let second = UIWindow(windowScene: scene)
        protection.update(enabled: true, window: first, sceneIsActive: false, isCaptured: false)
        let oldShield = try #require(protection.shieldWindow)
        protection.update(enabled: true, window: second, sceneIsActive: false, isCaptured: false)
        #expect(oldShield.isHidden)
        #expect(protection.shieldWindow !== oldShield)
        protection.update(enabled: true, window: nil, sceneIsActive: false, isCaptured: false)
        #expect(!protection.isActive)
        #expect(protection.shieldWindow == nil)
    }
}
