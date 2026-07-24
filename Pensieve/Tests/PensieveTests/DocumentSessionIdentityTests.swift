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
}
