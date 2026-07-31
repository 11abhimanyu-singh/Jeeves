//
//  DailyDigestView.swift
//  Jeeves
//
//  The daily digest, read on the phone. Everything it shows is computed HERE,
//  from the local store — the anomaly scan, the three product metrics, plan
//  health, and the export channel's own status. That matters: the iCloud
//  export exists to get data OUT to a Mac, and it has been failing for days.
//  None of that should stand between the user and their own numbers.
//
//  Deliberately a read-only surface. It narrates and never repairs, matching
//  the rule the pipeline has followed since the anomaly scan shipped: surface
//  the problem, let the person decide the fix.
//

import SwiftUI
import SwiftData

struct DailyDigestView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var logs: [PlanGenerationLog]

    @State private var anomalies: [Anomaly] = []
    @State private var metrics: ProductMetricsSnapshot?
    @State private var loaded = false

    private var high: [Anomaly] { anomalies.filter { $0.severity == "high" } }
    private var medium: [Anomaly] { anomalies.filter { $0.severity == "medium" } }
    private var low: [Anomaly] { anomalies.filter { $0.severity == "low" } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                verdictCard
                if let metrics { metricsSection(metrics) }
                planHealthCard
                if anomalies.isEmpty {
                    cleanCard
                } else {
                    anomalySection("Needs attention", high, Color.accentDeep)
                    anomalySection("Worth knowing", medium, Color(hex: "B4842A"))
                    anomalySection("Minor", low, Color.textMuted)
                }
                footnote
            }
            .padding(20)
        }
        .background(Color.bg)
        .onAppear { load() }
        .refreshable { load(force: true) }
    }

    // MARK: Verdict

    private var verdictCard: some View {
        let n = anomalies.count
        let headline = n == 0 ? "Everything checks out."
            : "\(n) thing\(n == 1 ? "" : "s") worth a look."
        return VStack(alignment: .leading, spacing: 6) {
            Text(Date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased())
                .font(.system(size: 10.5, weight: .bold)).kerning(1)
                .foregroundStyle(Color.textMuted)
            Text(headline)
                .font(.serif(24, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            if n > 0 {
                Text("\(high.count) high · \(medium.count) medium · \(low.count) low")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.textSoft)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.surface))
    }

    private var cleanCard: some View {
        Text("No anomalies in the whole store — workouts, plans, travel, tasks and notes all read consistently.")
            .font(.system(size: 13.5))
            .foregroundStyle(Color.textSoft)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.sageLight))
    }

    // MARK: Metrics

    private func metricsSection(_ m: ProductMetricsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("How it's doing", "Last \(m.windowDays) days")
            metricRow("Corrections", m.correctionRate, goodIs: "lower",
                      format: { "\(Int(($0 * 100).rounded()))%" })
            metricRow("Plans kept", m.replanAcceptance, goodIs: "higher",
                      format: { "\(Int(($0 * 100).rounded()))%" })
            metricRow("Ask → done", m.timeToOutcomeMinutes, goodIs: "lower",
                      format: { "\(Int($0.rounded())) min" })
        }
    }

    private func metricRow(_ label: String, _ value: MetricValue,
                           goodIs: String, format: (Double) -> String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text(value.note).font(.system(size: 11.5))
                    .foregroundStyle(Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value.value.map(format) ?? "—")
                    .font(.serif(20, weight: .semibold))
                    .foregroundStyle(value.isConfident ? Color.textPrimary : Color.textMuted)
                Text(value.isConfident ? "\(goodIs) is better" : "early days")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.textMuted)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.surface))
    }

    // MARK: Plan health + the export channel

    private var planHealthCard: some View {
        let recent = logs.sorted { $0.startedAt > $1.startedAt }.prefix(20)
        let succeeded = recent.filter { $0.outcome == .success || $0.outcome == .repaired }.count
        let last = recent.first
        let health = SyncOutbox.health

        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Under the hood", nil)
            row("Plan generation",
                recent.isEmpty ? "no runs recorded"
                : "\(succeeded)/\(recent.count) recent runs succeeded"
                + (last.map { " · last \($0.startedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))" } ?? ""))
            // The export is what carries all of this to a laptop; when it's
            // failing, say so HERE rather than leaving the Mac to guess.
            if let failure = health.failure {
                row("Mac export", "failing — \(failure)", tint: Color.accentDeep)
            } else if let ok = health.lastSuccess {
                // "Written" is not "delivered": a local write to the iCloud
                // container succeeds even when the app isn't syncing.
                let upload = SyncOutbox.uploadState()
                let when = ok.formatted(.dateTime.month(.abbreviated).day().hour().minute())
                if let upload, !upload.uploaded {
                    row("Mac export", "written \(when) but NOT uploaded"
                        + (upload.error.map { " — \($0)" } ?? " — iCloud hasn't taken it"),
                        tint: Color.accentDeep)
                } else if upload?.uploaded == true {
                    row("Mac export", "uploaded · last write \(when)")
                } else {
                    row("Mac export", "last write \(when) (upload state unknown)")
                }
            } else {
                row("Mac export", "never completed on this device", tint: Color.accentDeep)
            }
        }
    }

    private func row(_ label: String, _ value: String, tint: Color = Color.textSoft) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .frame(width: 110, alignment: .leading)
            Text(value).font(.system(size: 12.5)).foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.surface))
    }

    // MARK: Anomalies

    @ViewBuilder
    private func anomalySection(_ title: String, _ items: [Anomaly], _ tint: Color) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle(title, "\(items.count)")
                ForEach(Array(items.enumerated()), id: \.offset) { _, a in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 7) {
                            Circle().fill(tint).frame(width: 7, height: 7)
                            Text(a.title).font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(a.detail).font(.system(size: 12.5))
                            .foregroundStyle(Color.textSoft)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(a.day) · \(a.rule)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.textMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.surface))
                }
            }
        }
    }

    private func sectionTitle(_ title: String, _ trailing: String?) -> some View {
        HStack {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .bold)).kerning(1)
                .foregroundStyle(Color.textMuted)
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.textMuted)
            }
        }
    }

    private var footnote: some View {
        Text("Computed on this phone from your own data — nothing here depends on the Mac export. Pull to refresh.")
            .font(.system(size: 11))
            .foregroundStyle(Color.textMuted)
            .padding(.top, 4)
    }

    // MARK: Load

    private func load(force: Bool = false) {
        guard force || !loaded else { return }
        loaded = true
        anomalies = AnomalyScan.scan(context: modelContext)
        metrics = ProductMetrics.snapshot(context: modelContext)
    }
}
