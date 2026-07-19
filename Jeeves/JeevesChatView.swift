//
//  JeevesChatView.swift
//  Jeeves
//
//  The Jeeves chat scaffold — PRD §9 step 3. Deliberately built on the
//  app's existing warm-editorial-light tokens, not the PRD's dark-warm/NYT
//  redesign (§3) — that reskin is a separate, later phase, kept out of
//  this one so the chat loop can be proven and tested on its own.
//
//  Session history lives in memory only for now (lost on relaunch) — the
//  PRD lists persisted chat storage as a "likely needed" model, but that's
//  a real product decision (do old sessions matter, do they need to be
//  browsable) worth its own pass rather than bundling in here by default.
//

import SwiftUI

struct JeevesChatView: View {
    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var isSending = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.textPrimary.opacity(0.14))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if messages.isEmpty {
                            Text("Say hello to Jeeves — ask about your day, or just say hi. Full plan generation isn't wired up yet; this is proving the conversation loop first.")
                                .font(.system(size: 13.5))
                                .foregroundStyle(Color.textMuted)
                                .multilineTextAlignment(.center)
                                .padding(.top, 32)
                                .padding(.horizontal, 24)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }

                        ForEach(messages) { message in
                            bubble(for: message).id(message.id)
                        }

                        if isSending {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Jeeves is thinking…").font(.system(size: 12.5)).foregroundStyle(Color.textMuted)
                            }
                            .padding(.leading, 4)
                        }

                        if let errorText {
                            Text(errorText).font(.system(size: 12.5)).foregroundStyle(Color.accentDeep)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: messages.count) { _, _ in
                    guard let last = messages.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            Divider().overlay(Color.textPrimary.opacity(0.1))
            inputBar
        }
        .background(Color.bg)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.accent)
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: "sparkles").foregroundStyle(.white).font(.system(size: 13)))
            Text("Jeeves").font(.heading(18)).foregroundStyle(Color.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 10)
    }

    private func bubble(for message: ChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Text(message.content)
                .font(.system(size: 14.5))
                .foregroundStyle(message.role == .user ? .white : Color.textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 16).fill(message.role == .user ? Color.accent : Color.surface))
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Jeeves…", text: $inputText, axis: .vertical)
                .lineLimit(1...4)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.surface))

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSend ? Color.accent : Color.textMuted.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color.bg)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let priorHistory = messages
        messages.append(ChatMessage(role: .user, content: text))
        inputText = ""
        errorText = nil
        isSending = true

        Task {
            do {
                let reply = try await JeevesChatService.send(history: priorHistory, newMessage: text)
                messages.append(ChatMessage(role: .assistant, content: reply))
            } catch {
                errorText = error.localizedDescription
            }
            isSending = false
        }
    }
}

#Preview {
    JeevesChatView()
}
