// Copyright 2026 Denis Florent Media Group SRL
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.


import RelayInterface
import SwiftUI

/// A poll in the timeline: the question, the answers to pick from, and the
/// results once they may be shown.
///
/// Voting sends the whole selection each time, as the protocol expects; a
/// second click on a chosen answer withdraws it. The sender sees a button
/// to end the poll, after which the counts are final for everyone.
struct PollMessageView: View {
    let message: TimelineMessage
    let poll: TimelineMessage.Poll

    @Environment(\.matrixService) private var matrixService
    @Environment(\.timelineActions) private var actions

    private var mySelections: Set<String> {
        poll.selections(of: matrixService.userId())
    }

    private var style: BubbleStyle {
        .special(kind: .poll)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(poll.question)
                    .bold()
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "chart.bar")
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(poll.answers) { answer in
                    PollAnswerRow(
                        answer: answer,
                        isSelected: mySelections.contains(answer.id),
                        share: share(of: answer),
                        showsResults: poll.showsResults,
                        isEnabled: !poll.hasEnded
                    ) {
                        toggle(answer)
                    }
                }
            }

            HStack {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                if message.isOutgoing && !poll.hasEnded {
                    Button("End Poll") { actions.endPoll(message.eventID) }
                        .font(.caption)
                        .buttonStyle(.link)
                }
            }
        }
        .padding(.horizontal, BubbleStyle.horizontalPadding)
        .padding(.vertical, BubbleStyle.verticalPadding)
        .frame(maxWidth: 360, alignment: .leading)
        .background(style.backgroundColor)
        .clipShape(BubbleStyle.shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Poll: \(poll.question)")
    }

    private var footer: String {
        let votes = poll.totalVotes == 1 ? "1 vote" : "\(poll.totalVotes) votes"
        if poll.hasEnded { return "Final results · \(votes)" }
        if poll.showsResults { return votes }
        return "Results are shown when the poll ends"
    }

    private func share(of answer: TimelineMessage.Poll.Answer) -> Double {
        guard poll.showsResults, poll.totalVotes > 0 else { return 0 }
        return Double(answer.voterIDs.count) / Double(poll.totalVotes)
    }

    private func toggle(_ answer: TimelineMessage.Poll.Answer) {
        var selection = mySelections
        if selection.contains(answer.id) {
            selection.remove(answer.id)
        } else if poll.maxSelections == 1 {
            selection = [answer.id]
        } else if selection.count < poll.maxSelections {
            selection.insert(answer.id)
        } else {
            return
        }
        // Keep the poll's own order, which the server may rely on.
        let ordered = poll.answers.map(\.id).filter { selection.contains($0) }
        actions.respondToPoll(message.eventID, ordered)
    }
}

private struct PollAnswerRow: View {
    let answer: TimelineMessage.Poll.Answer
    let isSelected: Bool
    let share: Double
    let showsResults: Bool
    let isEnabled: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
                Text(answer.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if showsResults {
                    Text(answer.voterIDs.count, format: .number)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                if showsResults {
                    GeometryReader { proxy in
                        Color.accentColor.opacity(0.18)
                            .frame(width: proxy.size.width * share)
                    }
                }
            }
            .background(.quaternary.opacity(0.5))
            .clipShape(.rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(answer.text)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var accessibilityValue: String {
        guard showsResults else { return isSelected ? "Chosen" : "" }
        let count = answer.voterIDs.count == 1 ? "1 vote" : "\(answer.voterIDs.count) votes"
        return isSelected ? "Chosen, \(count)" : count
    }
}
