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


import SwiftUI

/// Writes a poll: a question, two to twenty answers, how many answers one
/// person may pick, and whether results show while the poll runs.
struct PollComposerSheet: View {
    let create: (String, [String], Int, Bool) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var answers = ["", ""]
    @State private var allowsMultiple = false
    @State private var isDisclosed = true
    @State private var isSending = false
    @FocusState private var focusedAnswer: Int?

    private var trimmedAnswers: [String] {
        answers.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var canCreate: Bool {
        !question.trimmingCharacters(in: .whitespaces).isEmpty && trimmedAnswers.count >= 2 && !isSending
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("New Poll")
                    .fontWeight(.semibold)
                Spacer()
                Button("Create", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            Form {
                Section("Question") {
                    TextField("Question", text: $question, prompt: Text("What do you want to ask?"), axis: .vertical)
                        .lineLimit(1...3)
                }
                Section {
                    ForEach(answers.indices, id: \.self) { index in
                        HStack {
                            TextField("Answer \(index + 1)", text: $answers[index], prompt: Text("Answer \(index + 1)"))
                                .focused($focusedAnswer, equals: index)
                                .onSubmit { addAnswerIfLast(after: index) }
                            if answers.count > 2 {
                                Button("Remove Answer", systemImage: "minus.circle") {
                                    answers.remove(at: index)
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if answers.count < 20 {
                        Button("Add Answer", systemImage: "plus.circle") {
                            answers.append("")
                            focusedAnswer = answers.count - 1
                        }
                        .buttonStyle(.borderless)
                    }
                } header: {
                    Text("Answers")
                } footer: {
                    Text("At least two. Press Return to add the next one.")
                }
                Section("Options") {
                    Toggle("Allow choosing several answers", isOn: $allowsMultiple)
                    Toggle("Show results while the poll is open", isOn: $isDisclosed)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 460, height: 480)
    }

    private func addAnswerIfLast(after index: Int) {
        if index == answers.count - 1, answers.count < 20, !answers[index].trimmingCharacters(in: .whitespaces).isEmpty {
            answers.append("")
        }
        focusedAnswer = min(index + 1, answers.count - 1)
    }

    private func submit() {
        guard canCreate else { return }
        isSending = true
        let question = question.trimmingCharacters(in: .whitespaces)
        let answers = trimmedAnswers
        let maxSelections = allowsMultiple ? answers.count : 1
        Task {
            await create(question, answers, maxSelections, isDisclosed)
            dismiss()
        }
    }
}
