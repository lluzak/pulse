//
//  WeeklyStatsView.swift
//  pulse
//

import SwiftUI

struct WeeklyStatsView: View {
    var gitHubService: GitHubService
    var onClose: () -> Void

    @State private var selectedDate: Date = Date()

    private var isCurrentWeek: Bool {
        let (currentStart, _) = WeeklyStats.calendarWeekBounds(for: Date())
        let (selectedStart, _) = WeeklyStats.calendarWeekBounds(for: selectedDate)
        return Calendar.current.isDate(currentStart, inSameDayAs: selectedStart)
    }

    private var weekRangeText: String {
        let (start, end) = WeeklyStats.calendarWeekBounds(for: selectedDate)
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let yearFormatter = DateFormatter()
        yearFormatter.dateFormat = ", yyyy"
        return "Week of \(formatter.string(from: start)) – \(formatter.string(from: end))\(yearFormatter.string(from: end))"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with week navigation
            HStack {
                Button(action: { navigateWeek(by: -1) }) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)

                Spacer()

                Text(weekRangeText)
                    .font(.headline)

                Spacer()

                Button(action: { navigateWeek(by: 1) }) {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .disabled(isCurrentWeek)
                .opacity(isCurrentWeek ? 0.3 : 1.0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if gitHubService.isLoadingWeeklyStats {
                Spacer()
                ProgressView("Loading stats...")
                Spacer()
            } else if let error = gitHubService.weeklyStatsError {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else if let stats = gitHubService.weeklyStats {
                statsContent(stats)
            } else {
                Spacer()
                Text("No data")
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Divider()

            // Footer with close
            HStack {
                Spacer()
                Button("Close") { onClose() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                Spacer()
            }
            .padding(.vertical, 10)
        }
        .task(id: selectedDate) {
            await gitHubService.fetchWeeklyStats(for: selectedDate)
        }
    }

    @ViewBuilder
    private func statsContent(_ stats: WeeklyStats) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                // Summary stats
                VStack(spacing: 12) {
                    statRow(label: "Reviews Requested", value: "\(stats.reviewsRequested.count)")
                    statRow(label: "Reviews Completed", value: "\(stats.reviewsSubmitted.count)")
                    statRow(label: "Avg Turnaround", value: formatTurnaround(stats.avgTurnaroundHours))
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                if !stats.repoBreakdown.isEmpty {
                    Divider()

                    // Repo breakdown
                    VStack(alignment: .leading, spacing: 8) {
                        Text("By Repository")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)

                        let sortedRepos = stats.repoBreakdown.sorted { $0.value.requested + $0.value.submitted > $1.value.requested + $1.value.submitted }

                        ForEach(sortedRepos, id: \.key) { repo, repoStats in
                            HStack {
                                Text(repo)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text("\(repoStats.requested) req / \(repoStats.submitted) done")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }

                if stats.reviewsRequested.isEmpty && stats.reviewsSubmitted.isEmpty {
                    Text("No review activity this week")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 20)
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
        }
    }

    private func formatTurnaround(_ hours: Double?) -> String {
        guard let hours = hours else { return "N/A" }
        if hours < 1 {
            return "\(Int(hours * 60))m"
        } else if hours < 24 {
            return String(format: "%.1fh", hours)
        } else {
            return String(format: "%.1fd", hours / 24.0)
        }
    }

    private func navigateWeek(by offset: Int) {
        if let newDate = Calendar.current.date(byAdding: .weekOfYear, value: offset, to: selectedDate) {
            selectedDate = newDate
        }
    }
}
