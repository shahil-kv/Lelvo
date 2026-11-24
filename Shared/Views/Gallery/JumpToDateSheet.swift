import SwiftUI
import LelvoCore

/// Month and year wheels to jump the timeline. Scrolls via the existing scrubber fraction; no Telegram calls.
struct JumpToDateSheet: View {
    let datesNewestFirst: [Date]
    let onJump: (CGFloat) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var month: Int
    @State private var year: Int
    private let years: [Int]
    private let months = Array(1...12)
    private let calendar = Calendar.current

    init(datesNewestFirst: [Date], onJump: @escaping (CGFloat) -> Void) {
        self.datesNewestFirst = datesNewestFirst
        self.onJump = onJump
        let range = JumpToDate.yearRange(in: datesNewestFirst)
        years = Array(range)
        let seed = datesNewestFirst.first ?? Date()
        _month = State(initialValue: Calendar.current.component(.month, from: seed))
        _year = State(initialValue: Calendar.current.component(.year, from: seed))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Scrolls the timeline. Your library stays on this device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                HStack(spacing: 12) {
                    Picker("Month", selection: $month) {
                        ForEach(months, id: \.self) { m in
                            Text(calendar.monthSymbols[m - 1]).tag(m)
                        }
                    }
                    #if os(iOS)
                    .pickerStyle(.wheel)
                    #else
                    .pickerStyle(.menu)
                    #endif
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Month")
                    Picker("Year", selection: $year) {
                        ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                    }
                    #if os(iOS)
                    .pickerStyle(.wheel)
                    #else
                    .pickerStyle(.menu)
                    #endif
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Year")
                }
                #if os(iOS)
                .frame(height: 160)
                #endif
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .navigationTitle("Jump to date")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Go") { go() }.fontWeight(.semibold)
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        #endif
    }

    private func go() {
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = 15
        let target = calendar.date(from: parts) ?? Date()
        let fraction = JumpToDate.fraction(target: target, datesNewestFirst: datesNewestFirst)
        onJump(CGFloat(fraction))
        Haptics.selection()
        dismiss()
    }
}
