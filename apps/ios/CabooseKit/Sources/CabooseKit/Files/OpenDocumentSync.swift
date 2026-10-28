import Foundation

/// A three-way comparison: both sides are compared with the last synchronized version.
public enum OpenDocumentSync: Equatable {
    case unchanged, uploadLocal, downloadRemote, conflict

    public static func decide(local: String, baselineLocal: String, remote: String, baselineRemote: String) -> Self {
        switch (local != baselineLocal, remote != baselineRemote) {
        case (false, false): .unchanged
        case (true, false): .uploadLocal
        case (false, true): .downloadRemote
        case (true, true): .conflict
        }
    }
}
