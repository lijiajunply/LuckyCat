import Testing
@testable import LuckyClash

struct ProxyShareCredentialsTests {
    @Test func validatesUTF8LengthAndForbiddenCharacters() {
        #expect(ProxyShareCredentials.validUsername("代理用户"))
        #expect(!ProxyShareCredentials.validUsername(" user"))
        #expect(!ProxyShareCredentials.validUsername("user:name"))
        #expect(!ProxyShareCredentials.validUsername("user\nname"))
        #expect(!ProxyShareCredentials.validUsername(String(repeating: "中", count: 86)))
        #expect(ProxyShareCredentials.validPassword(" "))
        #expect(!ProxyShareCredentials.validPassword(""))
        #expect(!ProxyShareCredentials.validPassword("pass\nword"))
        #expect(!ProxyShareCredentials.validPassword(String(repeating: "a", count: 256)))
    }
}
