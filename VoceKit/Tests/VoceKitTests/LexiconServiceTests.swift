import Foundation
import Testing
@testable import VoceKit

@Test("Lexicon applies global and app-scoped replacements")
func lexiconGlobalAndScopedReplacement() async throws {
    let service = PersonalLexiconService()
    await service.upsert(term: "voceh", preferred: "Voce", scope: .global)
    await service.upsert(term: "cursor", preferred: "Cursor IDE", scope: .app(bundleID: "com.todesktop.230313mzl4w4u92"))

    let generalContext = AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes")
    let ideContext = AppContext(bundleIdentifier: "com.todesktop.230313mzl4w4u92", appName: "Cursor", isIDE: true)

    let general = await service.apply(to: "hey voceh open cursor", appContext: generalContext)
    let ide = await service.apply(to: "hey voceh open cursor", appContext: ideContext)

    #expect(general == "hey Voce open cursor")
    #expect(ide == "hey Voce open Cursor IDE")
}

@Test("Lexicon allows multiple heard variants for one preferred term")
func lexiconMultipleVariantsForPreferredTerm() async throws {
    let service = PersonalLexiconService()
    await service.upsert(term: "Spectra Corp", preferred: "SpectraCorp", scope: .global)
    await service.upsert(term: "Vector Corp", preferred: "SpectraCorp", scope: .global)
    await service.upsert(term: "Spectral Core", preferred: "SpectraCorp", scope: .global)

    let corrected = await service.apply(
        to: "Schedule Spectra Corp today, Vector Corp tomorrow, and Spectral Core Friday.",
        appContext: nil
    )

    #expect(corrected == "Schedule SpectraCorp today, SpectraCorp tomorrow, and SpectraCorp Friday.")
}
