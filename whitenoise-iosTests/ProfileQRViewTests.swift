import Foundation
import Testing

struct ProfileQRViewTests {
    @Test func profileQRCodeIsRenderedIntoStateInsteadOfBody() throws {
        let source = try sourceString("whitenoise-ios/Profile/ProfileQRView.swift")

        #expect(source.contains("@State private var qrImage: UIImage?"))
        #expect(source.contains(".task(id: deepLink)"))
        #expect(source.contains("qrImage = QRCode.image(from: deepLink)"))
        #expect(source.contains("if let image = qrImage"))
        #expect(source.occurrenceCount(of: "QRCode.image(from: deepLink)") == 1)
        #expect(!source.matches(#"private var qrCard: some View \{[\s\S]*QRCode\.image\(from: deepLink\)"#))
    }

    private func sourceString(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private extension String {
    func occurrenceCount(of needle: String) -> Int {
        components(separatedBy: needle).count - 1
    }

    func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: .regularExpression) != nil
    }
}
