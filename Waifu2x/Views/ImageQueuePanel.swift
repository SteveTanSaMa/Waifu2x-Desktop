import SwiftUI

struct ImageQueuePanel: View {
    @Environment(\.locale) private var locale
    @ObservedObject var workspace: Workspace
    var body: some View {
        let _ = locale
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    heading
                    Spacer(minLength: 8)
                    selectionButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    heading
                    HStack {
                        Spacer(minLength: 0)
                        selectionButton
                    }
                }
            }
            .tint(Color(nsColor: ThemeColors.textAccent)).padding(.horizontal, 24).padding(.top, 12)
            if workspace.isMultiSelecting {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        selectionCount
                        Spacer(minLength: 0)
                        selectionActions
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        selectionCount
                        HStack {
                            Spacer(minLength: 0)
                            selectionActions
                        }
                    }
                }
                .font(.system(size: 12)).buttonStyle(.borderless)
                .tint(Color(nsColor: ThemeColors.textAccent)).disabled(workspace.busy)
                .padding(.horizontal, 24)
            }
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(workspace.images) { image in
                            QueueImageRow(image: image, selected: workspace.selectedID == image.id,
                                          multiSelecting: workspace.isMultiSelecting,
                                          marked: workspace.markedIDs.contains(image.id),
                                          toggleMark: { workspace.toggleMarked(image) },
                                          canRemove: !workspace.busy,
                                          select: { workspace.select(image); if workspace.isMultiSelecting { workspace.toggleMarked(image) } }, remove: { workspace.remove(image) })
                                .id(image.id)
                        }
                    }.padding(.horizontal, 8).padding(.bottom, CanvasPanelLayout.bottomClearance)
                }
                .onAppear { reader.scrollTo(workspace.selectedID, anchor: .center) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottomTrailing) {
            Button(action: workspace.chooseImage) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color(nsColor: ToolbarActionPalette.prominentInk))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .modifier(ToolbarControlSurface(expanded: true))
            .disabled(workspace.busy)
            .accessibilityLabel(L("添加图片…")).accessibilityIdentifier("queueAddButton")
            .help(L("添加图片（⌘O）"))
            .background(HeaderGeometryReader(identifier: "queueAddBounds"))
            .padding(CanvasPanelLayout.controlInset)
        }
    }

    private var heading: some View {
        HStack(spacing: 6) {
            Text(L("图片")).font(.system(size: 16, weight: .semibold))
            Text(workspace.images.count, format: .number).font(.caption).foregroundStyle(.secondary)
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var selectionButton: some View {
        Button(workspace.isMultiSelecting ? L("完成") : L("多选"), action: workspace.toggleMultiSelection)
            .buttonStyle(.borderless).font(.system(size: 14))
            .fixedSize(horizontal: true, vertical: false)
            .disabled(workspace.busy || workspace.images.isEmpty)
            .accessibilityLabel(workspace.isMultiSelecting ? L("结束多选") : L("多选图片"))
    }

    private var selectionCount: some View {
        Text(L("已选 %d 张", workspace.markedIDs.count)).foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var selectionActions: some View {
        HStack(spacing: 10) {
            Button(L("全选"), action: workspace.markAll)
            Button(L("清空"), action: workspace.clearMarks)
        }.fixedSize(horizontal: true, vertical: false)
    }
}

private struct QueueImageRow: View {
    @Environment(\.locale) private var locale
    @ObservedObject var image: QueueImage
    let selected: Bool
    let multiSelecting: Bool
    let marked: Bool
    let toggleMark: () -> Void
    let canRemove: Bool
    let select: () -> Void
    let remove: () -> Void
    var body: some View {
        let _ = locale
        HStack(spacing: 4) {
            if multiSelecting {
                Button(action: toggleMark) {
                    Image(systemName: marked ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(marked ? Color(nsColor: ThemeColors.textAccent) : .secondary)
                        .font(.system(size: 17)).frame(width: 22, height: 32)
                }.buttonStyle(.plain).disabled(!canRemove)
                    .accessibilityLabel(L("选择 %@", image.input.name)).accessibilityValue(marked ? L("已选") : L("未选"))
            }
            Button(action: select) {
                HStack(spacing: 12) {
                    Image(decorative: image.input.image, scale: 1)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 54, height: 54)
                        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(image.input.name).font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 5) {
                            if image.state == .processing { ProgressView().controlSize(.mini) }
                            else if image.state == .completed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                            else if image.state == .failed { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                            Text(image.status).lineLimit(1)
                        }.font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            if canRemove {
                Button(action: remove) { Label(L("移除 %@", image.input.name), systemImage: "xmark") }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).font(.system(size: 10))
                    .foregroundStyle(.secondary).help(L("从列表移除，不影响源文件"))
            }
        }.padding(8)
        .background((multiSelecting ? marked : selected) ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help(image.failure ?? image.input.dimensions)
        .contextMenu {
            if let failure = image.failure { Text(failure) }
            Button(L("移除图片"), action: remove).disabled(!canRemove)
        }
    }
}
