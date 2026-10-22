import SwiftUI

/// Popover for manually adding a Branch, Issue, or PR link to a card.
struct AddLinkPopover: View {
    var onAddBranch: (String) -> Void = { _ in }
    var onAddIssue: (Int) -> Void = { _ in }
    var onAddPR: (Int) -> Void = { _ in }

    @State private var linkType = "branch"
    @State private var branchText = ""
    @State private var numberText = ""

    var body: some View { usageTrackedBody.trackUsage("view", "AddLinkPopover") }

    @ViewBuilder private var usageTrackedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Link")
                .font(.app(.subheadline).bold())

            Picker("Type", selection: $linkType) {
                Text("Branch").tag("branch")
                Text("Issue").tag("issue")
                Text("PR").tag("pr")
            }
            .pickerStyle(.segmented)

            if linkType == "branch" {
                TextField("Branch name", text: $branchText)
                    .textFieldStyle(.roundedBorder)
            } else {
                HStack {
                    Text("#")
                        .foregroundStyle(.secondary)
                    TextField("Number", text: $numberText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
            }

            HStack {
                Spacer()
                Button("Add") {
                    if linkType == "branch" {
                        let branch = branchText.trimmingCharacters(in: .whitespaces)
                        guard !branch.isEmpty else { return }
                        onAddBranch(branch)
                    } else {
                        guard let number = Int(numberText.trimmingCharacters(in: .whitespaces)),
                              number > 0 else { return }
                        if linkType == "pr" {
                            onAddPR(number)
                        } else {
                            onAddIssue(number)
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isAddDisabled)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 220)
    }

    private var isAddDisabled: Bool {
        if linkType == "branch" {
            return branchText.trimmingCharacters(in: .whitespaces).isEmpty
        } else {
            return Int(numberText.trimmingCharacters(in: .whitespaces)) == nil
        }
    }
}
