import XCTest

@testable import Pensieve

final class DocumentSessionIdentityTests: XCTestCase {
  func testEveryNonEmptySessionHasStableKindSpecificIdentity() {
    XCTAssertNil(DocumentSession.empty.identity)

    let first = DocumentSession.untitled()
    let second = DocumentSession.untitled()
    XCTAssertNotNil(first.identity)
    XCTAssertNotEqual(first.identity, second.identity)
    XCTAssertEqual(first.identity, first.identity)

    let recoveryID = UUID()
    var recovered = DocumentSession.empty
    recovered.restoreUntitled(title: "Recovered.md", text: "draft", recoveryID: recoveryID)
    XCTAssertEqual(recovered.identity, .recovered(recoveryID))

    let unstandardized = URL(fileURLWithPath: "/tmp/pensieve-identity/../identity.md")
    let file = DocumentSession(document: DocumentRef(id: unstandardized))
    XCTAssertEqual(file.identity, .file(unstandardized.standardizedFileURL))
  }

  func testSaveAsTransitionReplacesDraftIdentityWithStandardizedFileIdentity() {
    var session = DocumentSession.untitled(title: "Draft.md")
    let draftIdentity = session.identity
    let savedURL = URL(fileURLWithPath: "/tmp/pensieve-save-as/../saved.md")

    session.load(document: DocumentRef(id: savedURL), text: "body")

    XCTAssertNotEqual(session.identity, draftIdentity)
    XCTAssertEqual(session.identity, .file(savedURL.standardizedFileURL))
  }

  func testRecoveryDraftShareSameAIIdentityKeyAcrossRestore() {
    // A dirty untitled draft that has been backed by a recovery record (first
    // autosave assigns `recoveryID`) must derive the SAME AI-identity key both
    // before close and after a relaunch restore, so the AI continuation stored
    // for the draft is found again. The key is `identity.persistentID` — the
    // exact value `DocumentWindowModel.aiDocumentID` publishes to the AI store.
    var draft = DocumentSession.untitled(title: "Draft.md")
    draft.isDirty = true
    let untitledKey = draft.identity?.persistentID

    let recoveryID = UUID()
    draft.recoveryID = recoveryID
    let beforeClose = draft.identity?.persistentID

    // Assigning a recovery record must flip the ephemeral untitled identity onto
    // the durable recovered identity in place — still an untitled kind.
    XCTAssertTrue(draft.isUntitled)
    XCTAssertNotEqual(beforeClose, untitledKey)
    XCTAssertEqual(draft.identity, .recovered(recoveryID))
    XCTAssertEqual(beforeClose, "recovery:\(recoveryID.uuidString.lowercased())")

    // A post-relaunch restore rebuilds the draft from the same recovery record.
    var restored = DocumentSession.empty
    restored.restoreUntitled(title: "Draft.md", text: "body", recoveryID: recoveryID)
    let afterRestore = restored.identity?.persistentID

    XCTAssertEqual(beforeClose, afterRestore)
  }

  @MainActor
  func testEmptyWindowsGetDistinctStableAIFallbackIdentity() {
    // Two windows with no document must NOT collapse onto one shared AI-session
    // key. `DocumentAISessionStore` keys sessions by `aiDocumentID`, so a shared
    // constant would let empty windows share and overwrite each other's
    // continuation. Each empty window gets its own stable per-window fallback.
    let first = DocumentWindowModel()
    let second = DocumentWindowModel()

    XCTAssertNil(first.documentIdentity)
    XCTAssertNil(second.documentIdentity)
    XCTAssertNotEqual(first.aiDocumentID, second.aiDocumentID)
    // Stable across reads for the same window (not regenerated per access).
    XCTAssertEqual(first.aiDocumentID, first.aiDocumentID)
  }
}
