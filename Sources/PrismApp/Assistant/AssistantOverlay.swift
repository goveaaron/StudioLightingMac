import SwiftUI
import PrismCore

/// ⌘K command bar: type (or say) what you want. OWNER: Assistant workstream.
struct AssistantOverlay: View {
    @Environment(AppModel.self) private var app
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { app.ui.isAssistantPresented = false }
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.spectrum)
                    TextField("Try “teal on the left, blue on the right, pink above”", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18))
                        .focused($focused)
                        .onSubmit(submit)
                    if app.assistant.isThinking { ProgressView().controlSize(.small) }
                    IconButton(systemImage: app.voice.isListening ? "mic.fill" : "mic", help: "Talk to Prism (⇧⌘K)",
                               isActive: app.voice.isListening) { app.voice.toggleListening() }
                }
                if !app.assistant.transcript.isEmpty {
                    Divider().overlay(Theme.stroke)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(app.assistant.transcript.suffix(8)) { m in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: m.role == .user ? "person.fill" : "sparkles")
                                        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                                    Text(m.text).font(Theme.Font.body)
                                        .foregroundStyle(m.role == .user ? Theme.textSecondary : Theme.textPrimary)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
            .padding(Theme.Space.l)
            .frame(width: 640)
            .glassBackground(radius: 18)
            .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
            .padding(.top, 90)
        }
        .onAppear { focused = true }
        .onExitCommand { app.ui.isAssistantPresented = false }
    }

    private func submit() {
        let t = text
        text = ""
        Task { await app.assistant.submit(t) }
    }
}
