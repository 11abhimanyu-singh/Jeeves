//
//  DataRepairSheet.swift
//  Jeeves
//
//  Shows exactly what the cleanup will change before it changes anything, and
//  separates the rows a rule can settle from the ones only the user can. The
//  second group gets the sentence to say in chat, not a button — guessing
//  which of three books is the real one is how you lose the right one.
//

import SwiftUI
import SwiftData

struct DataRepairSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var findings: [DataRepair.Finding] = []
    @State private var receipts: [String] = []
    @State private var scanned = false

    private var fixable: [DataRepair.Finding] { findings.filter { $0.action == .fixable } }
    private var manual: [DataRepair.Finding] { findings.filter { $0.action == .manual } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !receipts.isEmpty {
                        doneCard
                    } else if !scanned {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    } else if findings.isEmpty {
                        cleanCard
                    } else {
                        if !fixable.isEmpty { fixableSection }
                        if !manual.isEmpty { manualSection }
                    }
                }
                .padding(20)
            }
            .background(Color.bg)
            .navigationTitle("Clean up old data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .onAppear {
            guard !scanned else { return }
            findings = DataRepair.scan(context: modelContext)
            scanned = true
        }
    }

    private var cleanCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing to clean").font(Font.serif(17, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Text("No duplicates, orphans or unreadable rows. Anything the digest still reports is a live finding, not old debris.")
                .font(.ui(13)).foregroundStyle(Color.textSoft)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.sageLight))
    }

    private var doneCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cleaned").font(Font.serif(17, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            ForEach(receipts, id: \.self) { r in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark").font(.ui(11, weight: .bold))
                        .foregroundStyle(Color.sageDeep).padding(.top, 3)
                    Text(r).font(.ui(13)).foregroundStyle(Color.textPrimary)
                }
            }
            Text("Each of these is in the event log, so tomorrow's digest reports what was cleaned rather than hiding it.")
                .font(.ui(11.5)).foregroundStyle(Color.textMuted).padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.sageLight))
    }

    private var fixableSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("I CAN FIX THESE").font(.ui(11, weight: .bold)).kerning(0.9)
                .foregroundStyle(Color.accentDeep)
            ForEach(fixable) { f in card(f) }
            Button {
                receipts = DataRepair.applyAll(findings, context: modelContext)
            } label: {
                Text("Fix \(fixable.count) issue\(fixable.count == 1 ? "" : "s")")
                    .font(.ui(14.5, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.accent))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("YOUR CALL").font(.ui(11, weight: .bold)).kerning(0.9)
                .foregroundStyle(Color.textMuted)
                .padding(.top, 8)
            Text("These need a decision I shouldn't make for you.")
                .font(.ui(12)).foregroundStyle(Color.textSoft)
            ForEach(manual) { f in card(f) }
        }
    }

    private func card(_ f: DataRepair.Finding) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(f.title).font(.ui(14, weight: .semibold)).foregroundStyle(Color.textPrimary)
            Text(f.detail).font(.ui(12.5)).foregroundStyle(Color.textSoft)
                .fixedSize(horizontal: false, vertical: true)
            if let hint = f.chatHint {
                Text(hint).font(.ui(12)).foregroundStyle(Color.accentDeep)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 15).fill(Color.surface))
    }
}
