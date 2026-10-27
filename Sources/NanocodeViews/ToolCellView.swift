import SwiftUI

public struct ToolCellView: View {
  let cell: ToolCell
  var depth = 0
  @State private var open = false
  @Environment(\.nanocodeTheme) private var theme

  public init(_ cell: ToolCell, depth: Int = 0) {
    self.cell = cell
    self.depth = depth
  }

  var headline: String {
    if !cell.title.isEmpty { return cell.title }
    guard cell.body == .code else { return "" }
    return cell.input.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
  }

  var hasBody: Bool {
    !cell.input.isEmpty || !cell.output.isEmpty || !cell.images.isEmpty || !cell.children.isEmpty
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        withAnimation(.easeOut(duration: 0.15)) { open.toggle() }
      } label: {
        HStack(spacing: 8) {
          StatusIcon(status: cell.status)
          Text(cell.name).font(.mono(theme.codeSize, weight: .semibold)).foregroundStyle(theme.foreground)
          if !headline.isEmpty {
            Text(headline).font(.mono(theme.codeSize)).foregroundStyle(theme.muted).lineLimit(1).truncationMode(.tail)
          }
          Spacer(minLength: 4)
          let meta = ([cell.durationMs.map(Format.duration)] + cell.details.map { Optional($0) }).compactMap { $0 }
          if !meta.isEmpty {
            Text(meta.joined(separator: " · ")).font(.mono(theme.codeSize - 1)).foregroundStyle(theme.muted).lineLimit(1)
          }
          if hasBody {
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.muted)
              .rotationEffect(.degrees(open ? 90 : 0))
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if open {
        VStack(alignment: .leading, spacing: 8) {
          if !cell.input.isEmpty {
            CodeBlock(text: cell.input, language: cell.body == .diff ? "diff" : cell.language, maxHeight: 280)
          }
          if !cell.children.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
              ForEach(cell.children) { child in ToolCellView(child, depth: depth + 1) }
            }
            .padding(.leading, 10)
            .overlay(alignment: .leading) { Rectangle().fill(theme.border).frame(width: 1) }
          }
          if !cell.output.isEmpty {
            CodeBlock(text: cell.output, language: cell.outputLanguage, maxHeight: 280)
          }
          ForEach(cell.images, id: \.self) { image in RemoteImage(image, maxHeight: 260) }
        }
        .transition(.opacity)
      } else if depth == 0, cell.status == .running, !cell.output.isEmpty {
        Text(cell.output.split(separator: "\n").suffix(3).joined(separator: "\n"))
          .font(.mono(theme.codeSize - 1)).foregroundStyle(theme.muted).lineLimit(3)
      }
    }
    .padding(.vertical, depth == 0 ? 8 : 2)
    .padding(.horizontal, depth == 0 ? 12 : 0)
    .background(depth == 0 ? theme.surface : .clear, in: RoundedRectangle(cornerRadius: 10))
    .overlay(depth == 0 ? RoundedRectangle(cornerRadius: 10).strokeBorder(theme.border, lineWidth: 1) : nil)
  }
}

struct StatusIcon: View {
  let status: ToolStatus
  @Environment(\.nanocodeTheme) private var theme

  var body: some View {
    Group {
      switch status {
      case .running: ProgressView().controlSize(.mini)
      case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.success)
      case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(theme.danger)
      case .cancelled: Image(systemName: "slash.circle").foregroundStyle(theme.muted)
      case .yielded: Image(systemName: "arrow.clockwise.circle").foregroundStyle(theme.info)
      }
    }
    .font(.system(size: 12))
    .frame(width: 14, height: 14)
  }
}
