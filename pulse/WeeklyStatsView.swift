//
//  WeeklyStatsView.swift
//  pulse
//

import SwiftUI
import Charts

struct DailyActivity: Identifiable {
    let id = UUID()
    let day: String
    let count: Int
    let type: String
}

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

    // MARK: - Daily Activity Data

    private func dailyActivityData(_ stats: WeeklyStats) -> [DailyActivity] {
        let dayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let calendar = Calendar(identifier: .iso8601)

        var requestedByDay: [Int: Int] = [:]
        var completedByDay: [Int: Int] = [:]

        for pr in stats.reviewsRequested {
            let weekday = calendar.component(.weekday, from: pr.updatedDate)
            let dayIndex = (weekday + 5) % 7 // Mon=0, Tue=1, ..., Sun=6
            requestedByDay[dayIndex, default: 0] += 1
        }

        for pr in stats.reviewsSubmitted {
            let weekday = calendar.component(.weekday, from: pr.updatedDate)
            let dayIndex = (weekday + 5) % 7
            completedByDay[dayIndex, default: 0] += 1
        }

        var data: [DailyActivity] = []
        for i in 0..<7 {
            data.append(DailyActivity(day: dayLabels[i], count: requestedByDay[i, default: 0], type: "Requested"))
            data.append(DailyActivity(day: dayLabels[i], count: completedByDay[i, default: 0], type: "Completed"))
        }
        return data
    }

    // MARK: - Stats Content

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

                // Daily activity chart
                let chartData = dailyActivityData(stats)
                let hasActivity = chartData.contains { $0.count > 0 }

                if hasActivity {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Daily Activity")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)

                        Chart(chartData) { item in
                            BarMark(
                                x: .value("Day", item.day),
                                y: .value("Count", item.count)
                            )
                            .foregroundStyle(by: .value("Type", item.type))
                            .position(by: .value("Type", item.type))
                        }
                        .chartForegroundStyleScale([
                            "Requested": Color.blue,
                            "Completed": Color.green
                        ])
                        .chartLegend(position: .bottom, spacing: 8)
                        .chartXAxis {
                            AxisMarks(values: .automatic) { _ in
                                AxisValueLabel()
                                    .font(.caption2)
                            }
                        }
                        .chartYAxis {
                            AxisMarks(values: .automatic) { _ in
                                AxisGridLine()
                                AxisValueLabel()
                                    .font(.caption2)
                            }
                        }
                        .frame(height: 140)
                    }
                    .padding(.horizontal, 16)
                }

                if !stats.repoBreakdown.isEmpty {
                    Divider()

                    // Repo breakdown with bars
                    VStack(alignment: .leading, spacing: 10) {
                        Text("By Repository")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)

                        let sortedRepos = stats.repoBreakdown.sorted { $0.value.requested + $0.value.submitted > $1.value.requested + $1.value.submitted }
                        let maxCount = sortedRepos.map { max($0.value.requested, $0.value.submitted) }.max() ?? 1

                        ForEach(sortedRepos, id: \.key) { repo, repoStats in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(repo)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                HStack(spacing: 6) {
                                    repoBar(count: repoStats.requested, maxCount: maxCount, color: .blue, label: "req")
                                    repoBar(count: repoStats.submitted, maxCount: maxCount, color: .green, label: "done")
                                }
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

    // MARK: - Repo Bar

    private func repoBar(count: Int, maxCount: Int, color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            GeometryReader { geo in
                let fraction = maxCount > 0 ? CGFloat(count) / CGFloat(maxCount) : 0
                let barWidth = Swift.max(fraction * geo.size.width, count > 0 ? 4 : 0)
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.opacity(0.7))
                    .frame(width: barWidth)
            }
            .frame(height: 14)

            Text("\(count) \(label)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    // MARK: - Helpers

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
