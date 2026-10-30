/// Fixed diagnostic labels only. Never pass arbitrary protocol error text to logs.
enum LiveGPUProtocolDiagnostic {
    static func reason(_ message: String) -> String {
        switch message {
        case "surface unknown or foreign grant": return "surfaceUnknownGrant"
        case "surface duplicate grant": return "surfaceDuplicateGrant"
        case "surface grant capacity": return "surfaceGrantCapacity"
        case "surface work after failed bind": return "surfaceFailedBindWork"
        case "surface bind succeeded without resource": return "surfaceMissingResource"
        case "surface query during retirement or stale request": return "surfaceStaleQuery"
        case "surface incomplete native query": return "surfaceIncompleteQuery"
        case "surface indexed native API unavailable": return "surfaceMissingIndexedAPI"
        case "surface indexed control during retirement": return "surfaceRetiring"
        case "unknown or half-closed stream": return "streamUnavailable"
        case "unknown process": return "processUnavailable"
        default: return "other"
        }
    }
}
