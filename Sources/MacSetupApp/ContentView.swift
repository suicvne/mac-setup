import SwiftUI

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var viewModel: SetupViewModel

    var body: some View {
        ZStack {
            windowBackground
                .ignoresSafeArea()

            backgroundTint
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    hero
                    controls
                    contentGrid
                }
                .padding(24)
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MacSetup")
                .font(.system(size: 42, weight: .bold, design: .rounded))
            Text("Run installs, apply the stable settings automatically, and keep the version-sensitive tweaks in one visible checklist.")
                .font(.title3)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                statCard(count: count(for: .ok), label: "Completed")
                statCard(count: count(for: .skipped), label: "Skipped")
                statCard(count: count(for: .warning), label: "Warnings")
                statCard(count: count(for: .failed), label: "Failures")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var controls: some View {
        HStack(alignment: .center, spacing: 16) {
            Toggle("Dry Run", isOn: binding(for: \.dryRun))
            Toggle("Install Apps", isOn: binding(for: \.installApps))
            Toggle("Apply Settings", isOn: binding(for: \.applySettings))

            Spacer()

            Button(action: viewModel.runSetup) {
                Text(viewModel.isRunning ? "Running..." : "Run Setup")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.66, green: 0.15, blue: 0.15))
            .disabled(viewModel.isRunning || (!viewModel.options.installApps && !viewModel.options.applySettings))
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var contentGrid: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 18) {
                recordPanel(title: "Applications", records: viewModel.appRecords)
                recordPanel(title: "Settings", records: viewModel.settingRecords)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 18) {
                manualStepsPanel
                logPanel
            }
            .frame(maxWidth: 360)
        }
    }

    private func recordPanel(title: String, records: [TaskRecord]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.weight(.bold))

            LazyVStack(spacing: 10) {
                ForEach(records) { record in
                    HStack(alignment: .top, spacing: 12) {
                        Circle()
                            .fill(color(for: record.status))
                            .frame(width: 10, height: 10)
                            .padding(.top, 6)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(record.name)
                                    .font(.headline)
                                Spacer()
                                Text(record.status.label)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(color(for: record.status))
                            }
                            Text(record.area)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(record.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(cardFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(borderColor, lineWidth: 1)
                    }
                }
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var manualStepsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Manual Checklist")
                        .font(.title2.weight(.bold))
                    Text("\(viewModel.completedManualStepIDs.count) of \(viewModel.manualSteps.count) done")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !viewModel.completedManualStepIDs.isEmpty {
                    Button("Clear") {
                        viewModel.resetManualChecklist()
                    }
                    .buttonStyle(.bordered)
                }
            }

            ForEach(viewModel.manualSteps) { step in
                let isCompleted = viewModel.isManualStepCompleted(step)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Button {
                            viewModel.toggleManualStep(step)
                        } label: {
                            Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                                .imageScale(.large)
                                .foregroundStyle(isCompleted ? .green : .secondary)
                        }
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.title)
                                .font(.headline)
                                .strikethrough(isCompleted, color: .secondary)
                            Text(step.area)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if step.link != nil {
                            Button("Open") {
                                viewModel.openManualStep(step)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    Text(step.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .opacity(isCompleted ? 0.75 : 1)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(borderColor, lineWidth: 1)
                }
                .opacity(isCompleted ? 0.85 : 1)
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Activity")
                    .font(.title2.weight(.bold))
                Spacer()
                Button {
                    openWindow(id: "activity-log")
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .imageScale(.medium)
                }
                .buttonStyle(.bordered)
                .labelStyle(.iconOnly)
                .help("Open Activity Log in a separate window")
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(viewModel.logLines.indices), id: \.self) { index in
                        Text(viewModel.logLines[index])
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(minHeight: 180)
            .padding(14)
            .background(logFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            }
            .foregroundStyle(logForeground)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func statCard(count: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(count)")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text(label)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
    }

    private func count(for status: TaskStatus) -> Int {
        (viewModel.appRecords + viewModel.settingRecords).filter { $0.status == status }.count
    }

    private func color(for status: TaskStatus) -> Color {
        switch status {
        case .pending:
            return .gray
        case .running:
            return .blue
        case .ok:
            return .green
        case .skipped:
            return .secondary
        case .warning:
            return .orange
        case .failed:
            return .red
        }
    }

    private func binding(for keyPath: WritableKeyPath<RunOptions, Bool>) -> Binding<Bool> {
        Binding(
            get: { viewModel.options[keyPath: keyPath] },
            set: { viewModel.options[keyPath: keyPath] = $0 }
        )
    }

    private var windowBackground: some View {
        Color(nsColor: .windowBackgroundColor)
    }

    private var backgroundTint: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [
                    Color(nsColor: .controlAccentColor).opacity(0.18),
                    Color(nsColor: .underPageBackgroundColor).opacity(0.0),
                    Color.white.opacity(0.05)
                ]
                : [
                    Color(nsColor: .controlAccentColor).opacity(0.14),
                    Color(nsColor: .underPageBackgroundColor).opacity(0.0),
                    Color(red: 0.96, green: 0.90, blue: 0.84).opacity(0.30)
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var cardFill: Color {
        Color(nsColor: colorScheme == .dark ? .controlBackgroundColor : .textBackgroundColor)
            .opacity(colorScheme == .dark ? 0.92 : 0.88)
    }

    private var borderColor: Color {
        Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.45 : 0.35)
    }

    private var logFill: Color {
        Color(nsColor: colorScheme == .dark ? .textBackgroundColor : .controlBackgroundColor)
            .opacity(colorScheme == .dark ? 0.96 : 0.92)
    }

    private var logForeground: Color {
        Color(nsColor: colorScheme == .dark ? .textColor : .labelColor)
    }
}
