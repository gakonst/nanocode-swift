import SwiftUI

public struct ThinkingView: View {
  let text: String
  let live: Bool
  let startedAt: Double?
  let endedAt: Double?
  @State private var open = false
  @Environment(\.nanocodeTheme) private var theme

  public init(text: String, live: Bool, startedAt: Double? = nil, endedAt: Double? = nil) {
    self.text = text
    self.live = live
    self.startedAt = startedAt
    self.endedAt = endedAt
  }

  var label: String {
    if live { return "Thinking…" }
    if let startedAt, let endedAt, endedAt > startedAt { return "Thought for \(Format.duration(endedAt - startedAt))" }
    return "Thought"
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        withAnimation(.easeOut(duration: 0.15)) { open.toggle() }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "brain").font(.system(size: 11))
          Text(label).font(.body(theme.bodySize - 2))
          Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(open || live ? 90 : 0))
        }
        .foregroundStyle(theme.muted)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if open || live {
        MarkdownView(text, live: live, size: theme.bodySize - 2)
          .foregroundStyle(theme.muted)
          .padding(.leading, 10)
          .overlay(alignment: .leading) { Rectangle().fill(theme.border).frame(width: 2) }
      }
    }
  }
}

public struct UserMessageView: View {
  let entry: Entry
  @Environment(\.nanocodeTheme) private var theme

  public init(_ entry: Entry) { self.entry = entry }

  public var body: some View {
    HStack {
      Spacer(minLength: 48)
      VStack(alignment: .trailing, spacing: 6) {
        if !entry.images.isEmpty {
          HStack {
            ForEach(entry.images, id: \.self) { image in RemoteImage(image, maxHeight: 120) }
          }
        }
        if !entry.text.isEmpty {
          Text(entry.text).font(.body(theme.bodySize)).textSelection(.enabled)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(theme.userBubble, in: RoundedRectangle(cornerRadius: 16))
        }
        if entry.steer {
          Text("steered into the running turn").font(.body(theme.bodySize - 4)).foregroundStyle(theme.muted)
        }
      }
    }
  }
}

public struct BlockView: View {
  let block: Turn.Block
  @Environment(\.nanocodeTheme) private var theme

  public init(_ block: Turn.Block) { self.block = block }

  public var body: some View {
    switch block.entry.kind {
    case .assistant:
      MarkdownView(block.entry.text, live: block.live)
    case .reasoning:
      ThinkingView(text: block.entry.text, live: block.live, startedAt: block.entry.startedAt, endedAt: block.entry.endedAt)
    case .tool:
      if let tool = block.entry.tool { ToolCellView(tool) } else {
        Text(block.entry.text).font(.mono(theme.codeSize)).foregroundStyle(theme.muted)
      }
    case .error:
      Label(block.entry.text, systemImage: "exclamationmark.triangle").font(.body(theme.bodySize - 1)).foregroundStyle(theme.danger)
    case .user:
      UserMessageView(block.entry)
    }
  }
}

public struct ActivityRow: View {
  let activity: Activity
  @State private var phase = false
  @Environment(\.nanocodeTheme) private var theme

  public init(_ activity: Activity) { self.activity = activity }

  var label: String {
    switch activity.phase {
    case .idle: ""
    case .waiting: "Working…"
    case .thinking: "Thinking…"
    case .writing: "Writing…"
    case .running: "Running \(activity.tool ?? "a tool")…"
    }
  }

  public var body: some View {
    HStack(spacing: 8) {
      Circle().fill(theme.accent).frame(width: 7, height: 7).opacity(phase ? 1 : 0.3)
      Text(label).font(.body(theme.bodySize - 2)).foregroundStyle(theme.muted)
    }
    .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever()) { phase = true } }
  }
}

public struct TranscriptState: Sendable {
  public var entries: [Entry]
  public var live: [Entry]
  public var pending: Bool
  public var error: String?
  public var waiting: String?

  public init(entries: [Entry], live: [Entry] = [], pending: Bool = false, error: String? = nil, waiting: String? = nil) {
    self.entries = entries
    self.live = live
    self.pending = pending
    self.error = error
    self.waiting = waiting
  }

  public var turns: [Turn] { Turn.group(entries, live: live, pending: pending) }
  public var activity: Activity { Activity.of(live, pending: pending) }
}

public struct TranscriptView: View {
  let state: TranscriptState
  var empty: AnyView?
  @Environment(\.nanocodeTheme) private var theme

  public init(_ state: TranscriptState) {
    self.state = state
  }

  public init<Empty: View>(_ state: TranscriptState, @ViewBuilder empty: () -> Empty) {
    self.state = state
    self.empty = AnyView(empty())
  }

  var progress: Int {
    state.entries.count * 1_000_003 + state.live.reduce(0) { $0 + $1.text.count + ($1.tool?.output.count ?? 0) }
  }

  public var body: some View {
    ScrollViewReader { proxy in
      content
        .onChange(of: progress) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        .onAppear { proxy.scrollTo("end", anchor: .bottom) }
    }
  }

  var content: some View {
    let turns = state.turns
    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 18) {
        if turns.isEmpty, let empty {
          empty.frame(maxWidth: .infinity, minHeight: 240)
        }
        ForEach(turns) { turn in
          VStack(alignment: .leading, spacing: 12) {
            if let prompt = turn.prompt { UserMessageView(prompt) }
            ForEach(turn.blocks) { block in BlockView(block) }
          }
        }
        if state.pending {
          let activity = state.activity
          if activity.phase == .waiting || activity.phase == .thinking && state.live.last?.kind != .reasoning {
            ActivityRow(activity)
          }
        }
        if let waiting = state.waiting {
          Text(waiting).font(.body(theme.bodySize - 3)).foregroundStyle(theme.muted)
        }
        if let error = state.error {
          Label(error, systemImage: "exclamationmark.triangle").font(.body(theme.bodySize - 1)).foregroundStyle(theme.danger)
            .textSelection(.enabled)
        }
        Color.clear.frame(height: 4).id("end")
      }
      .frame(maxWidth: theme.columnWidth, alignment: .leading)
      .padding(.horizontal, 18)
      .padding(.vertical, 16)
      .frame(maxWidth: .infinity)
    }
    .defaultScrollAnchor(.bottom)
  }
}
