enum EditorCloseRecovery {
    enum KeepResult {
        case kept, changedWhileKeeping, failed
    }

    enum Choice {
        case retry, saveProject, discard, keepEditing
    }

    static func mayClose(
        keep: () async -> KeepResult,
        choose: () async -> Choice,
        saveProject: () async -> Bool
    ) async -> Bool {
        while true {
            switch await keep() {
            case .kept: return true
            case .changedWhileKeeping: continue
            case .failed:
                switch await choose() {
                case .retry: continue
                case .saveProject: return await saveProject()
                case .discard: return true
                case .keepEditing: return false
                }
            }
        }
    }
}
