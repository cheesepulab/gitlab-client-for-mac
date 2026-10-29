import Foundation

/// One line segment of the history graph inside a row: from a lane at the row's top (or
/// middle) to a lane at its middle (or bottom).
public struct GraphEdge: Sendable, Hashable {
    public let from: Int
    public let to: Int
    public let color: Int
}

public struct GraphRow: Sendable, Hashable {
    /// Lane of the commit's dot.
    public let lane: Int
    public let color: Int
    /// Segments from the row's top edge to its middle.
    public let top: [GraphEdge]
    /// Segments from the row's middle to its bottom edge.
    public let bottom: [GraphEdge]
    public let laneCount: Int
}

/// Assigns lanes to commits listed newest first. Keep one builder per history list and feed
/// it each page in order, since lanes continue across pages.
public struct GraphLaneBuilder: Sendable {
    private var lanes: [String?] = []
    private var colors: [Int] = []
    private var nextColor = 0

    public init() {}

    public mutating func rows(for commits: [Commit]) -> [GraphRow] {
        commits.map { row(for: $0) }
    }

    public mutating func row(for commit: Commit) -> GraphRow {
        let waiting = lanes.indices.filter { lanes[$0] == commit.hash }
        let lane: Int
        if let first = waiting.first {
            lane = first
        } else {
            lane = claimLane()
        }
        let color = colors[lane]

        var top: [GraphEdge] = []
        for index in lanes.indices where lanes[index] != nil {
            top.append(GraphEdge(from: index, to: waiting.contains(index) ? lane : index, color: colors[index]))
        }
        for index in waiting where index != lane { lanes[index] = nil }

        lanes[lane] = commit.parents.first
        var parentLanes: [Int] = commit.parents.isEmpty ? [] : [lane]
        for parent in commit.parents.dropFirst() {
            if let existing = lanes.firstIndex(where: { $0 == parent }) {
                parentLanes.append(existing)
            } else {
                let index = claimLane()
                lanes[index] = parent
                parentLanes.append(index)
            }
        }

        var bottom: [GraphEdge] = []
        for index in lanes.indices where lanes[index] != nil {
            if parentLanes.contains(index) {
                bottom.append(GraphEdge(from: lane, to: index, color: index == lane ? color : colors[index]))
            } else {
                bottom.append(GraphEdge(from: index, to: index, color: colors[index]))
            }
        }

        let width = max(lane + 1, (top + bottom).map { max($0.from, $0.to) + 1 }.max() ?? 1)
        while let last = lanes.last, last == nil {
            lanes.removeLast()
            colors.removeLast()
        }
        return GraphRow(lane: lane, color: color, top: top, bottom: bottom, laneCount: width)
    }

    private mutating func claimLane() -> Int {
        let color = nextColor
        nextColor += 1
        if let free = lanes.firstIndex(where: { $0 == nil }) {
            colors[free] = color
            return free
        }
        lanes.append(nil)
        colors.append(color)
        return lanes.count - 1
    }
}
