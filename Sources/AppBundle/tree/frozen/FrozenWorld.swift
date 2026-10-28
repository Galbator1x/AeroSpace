struct FrozenWorld {
    let monitors: [FrozenMonitor]
    let windowIds: Set<UInt32>
    var floatingWindowGeometry: [UInt32: FrozenWindow] = [:]
}

func collectAllWindowIdsRecursive(_ node: TreeNode) -> [UInt32] {
    if let window = node as? Window { return [window.windowId] }
    var result = [UInt32]()
    for child in node.children {
        result += collectAllWindowIdsRecursive(child)
    }
    return result
}
