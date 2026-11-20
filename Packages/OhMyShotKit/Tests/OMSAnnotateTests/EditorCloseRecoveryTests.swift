import Testing
@testable import OMSAnnotate

struct EditorCloseRecoveryTests {
    @Test func retryKeepsTheCurrentEditsBeforeClosing() async {
        var keeps = 0
        var prompts = 0
        let closed = await EditorCloseRecovery.mayClose {
            keeps += 1
            return keeps == 1 ? .failed : keeps == 2 ? .changedWhileKeeping : .kept
        } choose: {
            prompts += 1
            return .retry
        } saveProject: {
            Issue.record("Unexpected project save")
            return false
        }
        #expect(closed)
        #expect(keeps == 3)
        #expect(prompts == 1)
    }

    @Test(arguments: [false, true]) func recoveryProjectMustActuallyBeSaved(saved: Bool) async {
        var saves = 0
        let closed = await EditorCloseRecovery.mayClose { .failed } choose: { .saveProject } saveProject: {
            saves += 1
            return saved
        }
        #expect(closed == saved)
        #expect(saves == 1)
    }

    @Test(arguments: [false, true]) func onlyAnExplicitDiscardCanSkipSaving(discard: Bool) async {
        let closed = await EditorCloseRecovery.mayClose { .failed } choose: {
            discard ? .discard : .keepEditing
        } saveProject: {
            Issue.record("Unexpected project save")
            return false
        }
        #expect(closed == discard)
    }
}
