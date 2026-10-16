import Foundation
import Testing
@testable import Voce

private func makeIsolatedDefaults() -> UserDefaults {
    let suiteName = "VoceAccessSessionExpiryTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

@Test("Entitlement responses decode the access session expiry")
func entitlementDecodesSessionExpiry() throws {
    let json = Data("""
    {
      "email": "person@example.com",
      "entitled": true,
      "feature": "voce_app_access",
      "grantedFeatures": ["voce_app_access"],
      "sessionExpiresAt": 1800000000000
    }
    """.utf8)

    let entitlement = try JSONDecoder().decode(VoceProEntitlement.self, from: json)

    #expect(entitlement.sessionExpiresAt == 1_800_000_000_000)
    #expect(
        VoceAccessSessionStore.date(fromMilliseconds: entitlement.sessionExpiresAt!)
            == Date(timeIntervalSince1970: 1_800_000_000)
    )
}

@Test("Entitlement responses from older servers decode without a session expiry")
func entitlementDecodesWithoutSessionExpiry() throws {
    let json = Data("""
    {
      "email": "person@example.com",
      "entitled": true,
      "feature": "voce_app_access",
      "grantedFeatures": ["voce_app_access"]
    }
    """.utf8)

    let entitlement = try JSONDecoder().decode(VoceProEntitlement.self, from: json)

    #expect(entitlement.sessionExpiresAt == nil)
}

@Test("Session expiry is stored per normalized email")
func sessionExpiryIsStoredPerNormalizedEmail() {
    let store = VoceAccessSessionStore(defaults: makeIsolatedDefaults())
    let expiry = Date(timeIntervalSince1970: 1_800_000_000)

    store.saveSessionExpiry(expiry, email: "  Person@Example.com ")

    #expect(store.sessionExpiry(for: "person@example.com") == expiry)
    #expect(store.sessionExpiry(for: "other@example.com") == nil)
}

@Test("A later expiry report replaces the stored one")
func sessionExpiryIsReplacedByLaterReport() {
    let store = VoceAccessSessionStore(defaults: makeIsolatedDefaults())
    store.saveSessionExpiry(Date(timeIntervalSince1970: 1_800_000_000), email: "person@example.com")

    let extended = Date(timeIntervalSince1970: 1_800_086_400)
    store.saveSessionExpiry(extended, email: "person@example.com")

    #expect(store.sessionExpiry(for: "person@example.com") == extended)
}
