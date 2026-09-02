import AppKit
import SwiftUI

struct SearchPanelView: View {

    @ObservedObject var model: SearchModel

    /// Called when a click or Return finishes the job.
    let dismiss: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider()
            list
            Divider()
            hints
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(0.09))
        )
        // Async because the hosting view is not in a window yet when this first runs, and
        // focus assigned before then goes nowhere.
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)

            if let scope = model.scope {
                Text(scope.name)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.tint.opacity(0.16), in: Capsule())
            }

            TextField(placeholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 19, weight: .regular))
                .focused($focused)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var placeholder: String {
        model.scope == nil ? "Search every menu bar item" : "Search \(model.scope?.name ?? "")"
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    if model.showsApplications {
                        ForEach(Array(model.applications.enumerated()), id: \.element.id) {
                            index, app in
                            applicationRow(app, at: index)
                        }
                    } else {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, row in
                            resultRow(row, at: index)
                        }
                    }

                    if model.count == 0 {
                        Text("Nothing matches")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 28)
                    }
                }
                .padding(6)
            }
            .frame(height: 340)
            .onChange(of: model.selection) { _, selection in
                proxy.scrollTo(selection, anchor: .center)
            }
        }
    }

    private func applicationRow(_ app: SearchIndex.Application, at index: Int) -> some View {
        row(
            index: index,
            pid: app.pid,
            title: app.name,
            subtitle: app.rowCount == 1 ? nil : "\(app.rowCount) entries",
            isEnabled: true,
            trailing: app.rowCount == 1 ? nil : "↩ to narrow"
        )
        .onTapGesture { if model.activateSelection(at: index) { dismiss() } }
    }

    private func resultRow(_ result: SearchIndex.Row, at index: Int) -> some View {
        row(
            index: index,
            pid: result.pid,
            title: result.title,
            subtitle: result.subtitle,
            isEnabled: result.isEnabled,
            trailing: nil
        )
        .onTapGesture { if model.activateSelection(at: index) { dismiss() } }
    }

    private func row(
        index: Int,
        pid: pid_t,
        title: String,
        subtitle: String?,
        isEnabled: Bool,
        trailing: String?
    ) -> some View {
        let selected = index == model.selection

        return HStack(spacing: 10) {
            if let icon = NSRunningApplication(processIdentifier: pid)?.icon {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 14))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            if let trailing, selected {
                Text(trailing)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(isEnabled ? 1 : 0.4)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(.clear))
        )
        .contentShape(Rectangle())
        .id(index)
    }

    private var hints: some View {
        HStack(spacing: 14) {
            hint("↑↓", "move")
            hint("↩", model.showsApplications ? "open or narrow" : "activate")
            hint("esc", model.scope == nil ? "close" : "back")
            Spacer()
            Text("\(model.count)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func hint(_ key: String, _ what: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
            Text(what)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
