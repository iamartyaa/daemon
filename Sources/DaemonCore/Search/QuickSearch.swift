import Foundation

/// A Recall source that can also answer from keywords alone, in a few milliseconds and without the model.
/// The panel runs both on every keystroke and shows whichever it has when its budget runs out.
@MainActor
public protocol QuickRecallSource: RecallDataSource {
    func quickSearch(_ query: String) async throws -> [SearchHit]
}

extension Engine: QuickRecallSource {}
