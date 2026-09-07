import SwiftUI

/// Reusable Track Work control for Jira card / detail chrome. Lead mounts this
/// beside a rendered ticket; AX id is stable (`TicketWorkTrack`).
struct TicketWorkTrackButton: View {
    var title: String = "Track Work"
    var isTracked: Bool = false
    var isEnabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(
                isTracked ? "Open Tracking" : title,
                systemImage: isTracked ? "ticket.fill" : "ticket"
            )
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!isEnabled)
        .accessibilityLabel(isTracked ? "Open tracking" : "Track work")
        .accessibilityIdentifier(TicketWorkflowAccessibility.trackWorkButton)
    }
}

/// Optional results strip. Accepts Package D / lead presentation models.
struct TicketWorkResultsSlotView: View {
    var results: [TicketWorkResultsPresentation]

    var body: some View {
        if !results.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Results")
                    .font(.headline)
                ForEach(results) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: icon(for: result.outcome))
                                .foregroundStyle(color(for: result.outcome))
                            Text(result.headline)
                                .font(.subheadline.weight(.medium))
                        }
                        ForEach(Array(result.detailLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .accessibilityIdentifier("TicketWorkResult.\(result.id.uuidString)")
                }
            }
        }
    }

    private func icon(for outcome: TicketWorkResultsOutcome) -> String {
        switch outcome {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .running: return "arrow.triangle.2.circlepath"
        case .unknown: return "questionmark.circle"
        }
    }

    private func color(for outcome: TicketWorkResultsOutcome) -> Color {
        switch outcome {
        case .succeeded: return .green
        case .failed: return .red
        case .running: return .orange
        case .unknown: return .secondary
        }
    }
}

struct TicketWorkTemplateEditorView: View {
    @Bindable var model: TicketWorkTemplateEditorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                stageList
                Divider()
                stepEditor
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(TicketWorkflowAccessibility.templateEditor)
    }

    private var header: some View {
        HStack {
            Text("Checklist Template")
                .font(.headline)
            Spacer()
            if let error = model.lastError {
                Text(errorLabel(error))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button("Save") {
                model.commit()
                dismiss()
            }
            .disabled(!model.isDirty)
            .keyboardShortcut(.defaultAction)
            Button("Done") { dismiss() }
        }
        .padding(12)
    }

    private var stageList: some View {
        List(selection: Binding(
            get: { model.selectedStage as TicketWorkflowStage? },
            set: { if let stage = $0 { model.selectStage(stage) } }
        )) {
            ForEach(TicketWorkflowStage.allCases, id: \.self) { stage in
                Text(stage.displayName)
                    .tag(stage)
            }
        }
        .frame(width: 140)
        .listStyle(.sidebar)
    }

    private var stepEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.selectedStage.displayName)
                .font(.title3.weight(.semibold))

            List {
                ForEach(model.stepsInSelectedStage) { step in
                    stepRow(step)
                }
            }
            .listStyle(.inset)

            HStack {
                TextField("New step title", text: $model.newStepTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.addStep() }
                Button("Add") { model.addStep() }
                    .disabled(model.newStepTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stepRow(_ step: TicketChecklistStepTemplate) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                TextField(
                    "Title",
                    text: Binding(
                        get: { model.renameDraft(for: step) },
                        set: { model.setRenameDraft(stepID: step.id, title: $0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.commitRename(stepID: step.id) }

                HStack(spacing: 8) {
                    Toggle(
                        "Required",
                        isOn: Binding(
                            get: { step.isRequired },
                            set: { model.setRequired(stepID: step.id, isRequired: $0) }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .disabled(step.isProtected || step.role == .jiraClosureVerified)

                    if step.isProtected {
                        Text("Protected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 4)

            Button {
                model.moveUp(stepID: step.id)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .help("Move up within stage")

            Button {
                model.moveDown(stepID: step.id)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .help("Move down within stage")

            Button(role: .destructive) {
                model.remove(stepID: step.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canRemove(step))
            .help(model.canRemove(step) ? "Remove step" : "Protected step cannot be removed")
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier(TicketWorkflowAccessibility.stepRow(step.id))
    }

    private func errorLabel(_ error: TicketWorkTemplateEditing.EditError) -> String {
        switch error {
        case .stepNotFound: return "Step not found"
        case .protectedStep: return "Protected step cannot be changed that way"
        case .crossStageReorder: return "Steps cannot move across stages"
        case .emptyTitle: return "Title cannot be empty"
        case .stageImmutable: return "Stages cannot be reordered"
        }
    }
}
