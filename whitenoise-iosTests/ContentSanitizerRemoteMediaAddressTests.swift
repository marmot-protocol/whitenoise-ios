import Testing
@testable import whitenoise_ios

struct ContentSanitizerRemoteMediaAddressTests {
    @Test(arguments: [
        "192.0.2.0", "192.0.2.255", "192.88.99.0", "192.88.99.255",
        "198.18.0.0", "198.19.255.255", "198.51.100.0", "198.51.100.255",
        "203.0.113.0", "203.0.113.255", "192.0.0.9", "192.0.0.10",
        "fec0::", "feff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
        "100::", "100::ffff:ffff:ffff:ffff", "100:0:0:1::1",
        "2001:db8::", "2001:db8:ffff:ffff:ffff:ffff:ffff:ffff",
        "2001:2::", "2001:2:0:ffff:ffff:ffff:ffff:ffff",
        "2001:1::4", "2001:10::1", "2001:1ff:ffff:ffff:ffff:ffff:ffff:ffff",
        "64:ff9b:1::", "64:ff9b:1:ffff:ffff:ffff:ffff:ffff",
        "3fff::", "3fff:fff:ffff:ffff:ffff:ffff:ffff:ffff", "5f00::1",
        "::ffff:198.18.0.1", "::ffff:0:198.19.255.255", "::198.51.100.1",
        "64:ff9b::198.18.0.1", "2002:c612:1::1",
    ])
    func rejectsNonPublicLiteralAndImageURL(address: String) {
        #expect(ContentSanitizer.isPrivateOrLoopbackAddressLiteral(address))
        let host = address.contains(":") ? "[\(address)]" : address
        #expect(ContentSanitizer.imageURL("https://\(host)/image.png") == nil)
    }

    @Test(arguments: [
        "198.17.255.255", "198.20.0.0", "192.0.1.255", "192.0.3.0",
        "198.51.99.255", "198.51.101.0", "203.0.112.255", "203.0.114.0",
        "192.31.196.1", "192.52.193.1", "192.175.48.1", "93.184.216.34",
        "2001:4860:4860::8888", "2606:4700:4700::1111",
        "2001:1::1", "2001:1::2", "2001:1::3", "2001:3::1", "2001:4:112::1",
        "2001:20::1", "2001:2f:ffff:ffff:ffff:ffff:ffff:ffff",
        "2001:30::1", "2001:3f:ffff:ffff:ffff:ffff:ffff:ffff", "2001:200::1",
        "2001:db7:ffff:ffff:ffff:ffff:ffff:ffff", "2001:db9::1", "3fff:1000::1",
        "64:ff9b::93.184.216.34", "::ffff:93.184.216.34", "2002:5db8:d822::1",
    ])
    func retainsPublicAddressesAndGlobalExceptions(address: String) {
        #expect(!ContentSanitizer.isPrivateOrLoopbackAddressLiteral(address))
        let host = address.contains(":") ? "[\(address)]" : address
        #expect(ContentSanitizer.imageURL("https://\(host)/image.png") != nil)
    }
}
