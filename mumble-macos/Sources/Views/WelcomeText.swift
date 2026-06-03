import SwiftUI

struct WelcomeTextView: View {
    let html: String

    /// Cached parse. Recomputed only when `html` changes — `MainView`
    /// re-evaluates on every channel/user mutation, and re-running the
    /// HTML loader each time would burn CPU for output that hasn't moved.
    @State private var attributed = AttributedString()

    var body: some View {
        ScrollView {
            Text(attributed)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
        }
        .onChange(of: html, initial: true) { _, newValue in
            attributed = AttributedString(WelcomeHTML.attributedString(from: newValue))
        }
    }
}
