import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PrismCore

// MARK: - Import From Lightkey Sheet

struct ImportLightkeySheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var importResult: LightkeyImportResult?
    @State private var sourceLabel: String = ""
    @State private var errorMessage: String?
    @State private var isDropTargeted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import from Lightkey")
                        .font(Theme.Font.title)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Bring your existing .lightkeyproj patch, stage layout, folders, and preset looks straight into Prism.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Load Sample Show (London Studio)") {
                    loadSampleLondonStudio()
                }
                .buttonStyle(.pill(compact: true))
            }

            if let errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(Theme.danger)
                    Text(errorMessage)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button("Dismiss") { self.errorMessage = nil }
                        .buttonStyle(.plain)
                        .font(Theme.Font.captionStrong)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Theme.danger.opacity(0.15)))
            }

            if let result = importResult {
                previewContent(result)
            } else {
                dropZoneView
            }

            HStack {
                if importResult != nil {
                    Button("Choose Another File…") {
                        chooseFile()
                    }
                    .buttonStyle(.pill)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.pill)
                    .keyboardShortcut(.cancelAction)

                if let result = importResult {
                    Button {
                        app.show.importLightkeyResult(result)
                        app.ui.toast(result.summaryText, style: .success, systemImage: "square.and.arrow.down.on.square.fill")
                        dismiss()
                    } label: {
                        Label("Import \(result.importedFixtureCount) Lights & \(result.importedLookCount) Looks", systemImage: "checkmark")
                    }
                    .buttonStyle(.pill(prominent: true))
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Theme.Space.xl)
        .background(Theme.window)
        .frame(width: 780, height: 580)
        .onAppear {
            if app.ui.isRunningTour && importResult == nil {
                loadSampleLondonStudio()
            }
        }
    }

    private var dropZoneView: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.spectrum)
            Text("Drop a .lightkeyproj file here")
                .font(Theme.Font.title)
                .foregroundStyle(Theme.textPrimary)
            Text("Prism reads your DMX universes, fixture addresses, stage coordinates, and 16-bit preset colors without needing Lightkey installed.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            HStack(spacing: Theme.Space.m) {
                Button {
                    chooseFile()
                } label: {
                    Label("Choose .lightkeyproj File…", systemImage: "folder")
                }
                .buttonStyle(.pill(prominent: true))

                Button {
                    loadSampleLondonStudio()
                } label: {
                    Label("Preview London Studio Rig", systemImage: "sparkles")
                }
                .buttonStyle(.pill)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(isDropTargeted ? Theme.accentSoft : Theme.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(isDropTargeted ? Theme.accent : Theme.strokeStrong, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let first = providers.first else { return false }
            _ = first.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    DispatchQueue.main.async {
                        importFromURL(url)
                    }
                }
            }
            return true
        }
    }

    private func previewContent(_ result: LightkeyImportResult) -> some View {
        let resolved = result.project.resolvedFixtures(library: app.library.lookup)

        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            // Summary stat badges
            HStack(spacing: Theme.Space.m) {
                summaryStatCard(title: "Project", value: result.project.name, icon: "doc.badge.gearshape")
                summaryStatCard(title: "Patched Lights", value: "\(result.importedFixtureCount)", icon: "lightbulb.led.fill")
                summaryStatCard(title: "Saved Looks", value: "\(result.importedLookCount)", icon: "sparkles.rectangle.stack")
                summaryStatCard(title: "Preset Folders", value: "\(result.importedFolderCount)", icon: "folder.fill")
            }

            HStack(alignment: .top, spacing: Theme.Space.m) {
                // Mini stage preview
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader("Stage Layout Preview", systemImage: "square.grid.3x3.topleft.filled")
                    GeometryReader { geo in
                        let w = max(geo.size.width, 1)
                        let h = max(geo.size.height, 1)
                        let stageW = max(result.project.stage.width, 1)
                        let stageH = max(result.project.stage.height, 1)
                        ZStack {
                            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                                .fill(Theme.canvas)
                            ForEach(resolved) { rf in
                                let nx = clamp(rf.fixture.transform.x / stageW, 0.08, 0.92)
                                let ny = clamp(rf.fixture.transform.y / stageH, 0.08, 0.92)
                                VStack(spacing: 2) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Theme.accent)
                                        .frame(width: rf.definition.category == .tube ? 28 : 14, height: rf.definition.category == .tube ? 7 : 14)
                                        .rotationEffect(.degrees(rf.fixture.transform.rotation))
                                    Text(rf.fixture.stageLabel)
                                        .font(.system(size: 9, weight: .bold, design: .rounded))
                                        .foregroundStyle(Theme.textPrimary)
                                }
                                .position(x: nx * w, y: ny * h)
                            }
                        }
                    }
                    .frame(height: 190)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.stroke))
                }
                .frame(width: 260)
                .prismPanel()

                // Fixtures & Looks lists
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SectionHeader("Patched Lights (\(resolved.count))", systemImage: "cable.connector")
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(resolved) { rf in
                                HStack(spacing: 8) {
                                    Text(rf.fixture.stageLabel)
                                        .font(Theme.Font.mono(11))
                                        .foregroundStyle(Theme.accent)
                                        .frame(width: 34, alignment: .leading)
                                    Text(rf.fixture.name)
                                        .font(Theme.Font.captionStrong)
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    Text("\(rf.definition.displayName) · \(rf.mode.name)")
                                        .font(Theme.Font.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                    Text(rf.addressRange.map { "U\(rf.fixture.universe) · \($0.lowerBound)–\($0.upperBound)" } ?? "Unpatched")
                                        .font(Theme.Font.number(11))
                                        .foregroundStyle(Theme.textTertiary)
                                        .frame(width: 86, alignment: .trailing)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panelRaised))
                            }
                        }
                    }
                    .frame(maxHeight: 125)

                    SectionHeader("Saved Looks (\(result.project.looks.count))", systemImage: "paintpalette")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(result.project.looks) { look in
                                let colors = look.states.storage.values.prefix(6).map { Color($0.color.displayRGB) }
                                VStack(alignment: .leading, spacing: 4) {
                                    SwatchStrip(colors: colors.isEmpty ? [.black] : colors, height: 10)
                                        .frame(width: 110)
                                    Text(look.name)
                                        .font(Theme.Font.captionStrong)
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1)
                                }
                                .padding(7)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panelRaised))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .prismPanel()
            }

            if !result.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(result.warnings, id: \.self) { warning in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.warning)
                            Text(warning)
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Theme.warning.opacity(0.10)))
            }
        }
    }

    private func summaryStatCard(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(title.uppercased())
                    .font(Theme.Font.sectionLabel)
                    .foregroundStyle(Theme.textTertiary)
                Text(value)
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.stroke))
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Lightkey Project"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let utType = UTType(filenameExtension: "lightkeyproj") {
            panel.allowedContentTypes = [utType, .propertyList, .package]
        }
        if panel.runModal() == .OK, let url = panel.url {
            importFromURL(url)
        }
    }

    private func importFromURL(_ url: URL) {
        do {
            let res = try LightkeyImporter.importProject(at: url, library: app.library.lookup)
            self.importResult = res
            self.sourceLabel = url.lastPathComponent
            self.errorMessage = nil
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    private func loadSampleLondonStudio() {
        do {
            let data = try LightkeyArchiveBuilder.londonStudioArchiveData()
            let res = try LightkeyImporter.importProject(from: data, projectName: "London Studio (Lightkey)", library: app.library.lookup)
            self.importResult = res
            self.sourceLabel = "London Studio.lightkeyproj"
            self.errorMessage = nil
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
}
