import Foundation
// Dependency-free runner for hosts with Command Line Tools but no XCTest framework.
class XCTestCase {}
var failures = 0
func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ note: String = "", file: StaticString = #filePath, line: UInt = #line) { if lhs != rhs { failures += 1; print("FAIL \(file):\(line) \(note): \(lhs) != \(rhs)") } }
func XCTAssertTrue(_ value: Bool, _ note: String = "", file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(value, true, note, file: file, line: line) }
func XCTAssertThrowsError<T>(_ body: @autoclosure () throws -> T, _ note: String = "", file: StaticString = #filePath, line: UInt = #line) { do { _ = try body(); failures += 1; print("FAIL \(file):\(line) expected rejection: \(note)") } catch {} }
func XCTAssertNoThrow<T>(_ body: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) { do { _ = try body() } catch { failures += 1; print("FAIL \(file):\(line): \(error)") } }
do {
    if CommandLine.arguments.contains("--network") { try testNetworkBoundaries() }
    let activation = ActivationTests()
    activation.testRejectsUnsafeActivation()
    try activation.testValidLinkAndExplicitDevelopmentOrigin()
    try InstallerTests().testCancelMakesNoWritesAndConflictsPreserveExistingFiles()
    try InstallerTests().testInstallRepeatsIdentityAndRejectsModifiedOwnedContent()
    try InstallerTests().testExistingInstallSaysWhoPutItThere()
    try InstallerTests().testRejectsDestinationThatCouldInjectLegacyReceipt()
    try InstallerTests().testRollbackAndSymlinkEscape()
    try InstallerTests().testInterruptedUpdateRecoversAndKeepsIdentity()
    try InstallerTests().testRealAPIPackageAcrossAllTargetsAndScopes()
    try ArchiveTests().testTarRejectsUnsafeEntriesAndCorruption()
    try ArchiveTests().testAcceptsPinnedPAXPathAndRejectsPAXOverrides()
    try ManifestTests().testRejectsReceiptInjectionAndCaseCollision()
    try ManifestTests().testValidAndExpiredManifest()
    try ManifestTests().testRejectsPathsBoundsTargetDriftAndHashDrift()
    try McpTests().testValidationRefusesRunnerOptionsAndDrift()
    try McpTests().testEveryClientKeepsTheRestOfItsFileAndRemovesOnlyItsEntry()
    try McpTests().testRemovingTheLastServerLeavesFilesAsFound()
    try McpTests().testHostedServersPerClientAndKeys()
    try McpTests().testSomeoneElsesServerIsLeftAlone()
    try McpTests().testMcpLink()
} catch { failures += 1; print("FAIL unexpected error: \(error)") }
print("Native core tests: \(failures) failures")
exit(failures == 0 ? 0 : 1)
