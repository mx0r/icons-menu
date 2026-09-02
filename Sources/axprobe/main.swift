// axprobe — the AX debugging tool for IconsMenu.
//
// Originally the Step 0 feasibility spike. Kept because anything that goes wrong with this
// app goes wrong at the AX layer, and inspecting that from a terminal beats a debugger.
//
// Usage:
//   axprobe                    list every status item, as the app sees it
//   axprobe --raw              ...include placeholders the app filters out, and AX attrs
//   axprobe --press <pid> <n>  press item n of that pid
//   axprobe --menu <pid> <n>   press item n, mirror the resulting menu, dismiss it

import AppKit
import ApplicationServices

// MARK: - Reporting

func describe(_ item: StatusItem, in inventory: Inventory, verbose: Bool) {
    let position: String
    if let frame = item.frame {
        position = String(
            format: "x=%.0f y=%.0f %.0fx%.0f %@",
            frame.origin.x, frame.origin.y, frame.width, frame.height,
            item.isOnScreen ? "on-screen" : "OFF-SCREEN"
        )
    } else {
        position = "no frame"
    }

    let actions = AX.actionNames(item.element)
    let pressable = actions.contains(kAXPressAction as String) ? "AXPress" : "NO-AXPRESS"

    print("  [\(item.index)] \(inventory.qualifiedName(for: item))")
    print("       label=\(item.label ?? "-")  id=\(item.id)")
    print("       \(position)\(item.isPlaceholder ? "  PLACEHOLDER" : "")")
    print("       \(pressable)  actions=[\(actions.joined(separator: ", "))]")

    if verbose {
        print("       attrs=[\(AX.attributeNames(item.element).joined(separator: ", "))]")
    }
}

func list(verbose: Bool) {
    // --raw bypasses the scanner's filtering to show what it is dropping.
    let inventory = verbose ? rawInventory() : StatusItemScanner.scan()
    let byApp = Dictionary(grouping: inventory.items, by: \.pid)

    print("\(inventory.items.count) status item(s) across \(byApp.count) app(s)"
          + (verbose ? "  [raw — placeholders included]" : "") + "\n")

    // Third-party first; Apple's own agents are rarely what you are debugging.
    let sorted = byApp.sorted { lhs, rhs in
        let l = lhs.value[0], r = rhs.value[0]
        let lApple = l.bundleID.hasPrefix("com.apple.")
        let rApple = r.bundleID.hasPrefix("com.apple.")
        if lApple != rApple { return !lApple }
        return l.appName.localizedCaseInsensitiveCompare(r.appName) == .orderedAscending
    }

    for (pid, items) in sorted {
        let first = items[0]
        print("\(first.appName)  [\(first.bundleID)]  pid \(pid)  \(items.count) item(s)")
        for item in items.sorted(by: { $0.index < $1.index }) {
            describe(item, in: inventory, verbose: verbose)
        }
        print("")
    }

    print("--- summary ---")
    print("off-screen:        \(inventory.unreachable.count) "
          + "\(inventory.unreachable.map(\.appName).joined(separator: ", "))")
    let placeholders = inventory.items.filter(\.isPlaceholder)
    print("placeholders:      \(placeholders.count) "
          + "\(Set(placeholders.map(\.appName)).sorted().joined(separator: ", "))")
    let unpressable = inventory.items.filter {
        !AX.actionNames($0.element).contains(kAXPressAction as String)
    }
    print("without AXPress:   \(unpressable.count) "
          + "\(unpressable.map(\.appName).joined(separator: ", "))")
}

/// Everything `AXExtrasMenuBar` reports, including the zero-size placeholders that
/// `StatusItemScanner` filters out.
func rawInventory() -> Inventory {
    let ownPID = ProcessInfo.processInfo.processIdentifier
    var found: [StatusItem] = []

    for app in NSWorkspace.shared.runningApplications {
        let pid = app.processIdentifier
        guard pid > 0, pid != ownPID, let bundleID = app.bundleIdentifier else { continue }
        guard let extras = AX.copyAttribute(AX.application(pid: pid), "AXExtrasMenuBar")
        else { continue }

        for (index, element) in AX.children(extras as! AXUIElement).enumerated() {
            AX.bound(element)
            found.append(StatusItem(
                index: index,
                pid: pid,
                bundleID: bundleID,
                appName: app.localizedName ?? bundleID,
                label: AX.label(element),
                frame: AX.frame(element),
                element: element,
                menu: ItemActivator.readMenu(for: element)
            ))
        }
    }
    return Inventory(items: found)
}

// MARK: - Probes

func find(pid: pid_t, index: Int) -> StatusItem {
    guard let item = rawInventory().items.first(where: { $0.pid == pid && $0.index == index })
    else {
        print("no item \(index) for pid \(pid) — run axprobe with no arguments to list them")
        exit(1)
    }
    return item
}

func press(pid: pid_t, index: Int) {
    let item = find(pid: pid, index: index)
    print("pressing \(item.appName) [\(item.index)] — onScreen=\(item.isOnScreen)")

    // Synchronous here on purpose: the app presses on a background queue, but for probing
    // we want to see the outcome. Expect `dispatched` for anything menu-backed.
    let outcome = AX.perform(item.element, kAXPressAction as String, timeout: 0.3)
    switch outcome {
    case .completed:
        print("  completed — returned immediately, so nothing modal opened")
    case .dispatched:
        print("  dispatched — no reply before timeout, i.e. a menu is open")
    case .failed(let error):
        print("  FAILED (\(error.rawValue))")
    }
    print("  Now look at the screen: did something open, and where?")
}

func mirror(pid: pid_t, index: Int) {
    let item = find(pid: pid, index: index)
    print("mirroring \(item.appName) [\(item.index)] — onScreen=\(item.isOnScreen)")
    print("  (reading only — nothing is pressed)")

    guard let entries = item.menu else {
        print("  nothing to mirror — popover-backed, or the menu is built on demand")
        return
    }
    print(render(entries))
}

/// Renders the cached tree, which the scan has already read in full.
func render(_ entries: [MirroredEntry], indent: String = "    ") -> String {
    entries.map { entry in
        if entry.isSeparator { return indent + "—" }
        let line = indent + entry.title + (entry.isEnabled ? "" : "  [disabled]")
        guard entry.hasSubmenu else { return line }
        return line + " ▸\n" + render(entry.children, indent: indent + "  ")
    }
    .joined(separator: "\n")
}

// MARK: - Entry point

guard AX.isTrusted else {
    print("""
    NOT AX-TRUSTED.

    Grant Accessibility to the terminal running this, then re-run:
      System Settings → Privacy & Security → Accessibility

    Nothing works without it — AXExtrasMenuBar reports nothing for every app.
    """)
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case nil:
    list(verbose: false)
case "--raw":
    list(verbose: true)
case "--press", "--menu":
    guard arguments.count == 3, let pid = pid_t(arguments[1]), let index = Int(arguments[2]) else {
        print("usage: axprobe \(arguments[0]) <pid> <item-index>")
        exit(1)
    }
    arguments[0] == "--press" ? press(pid: pid, index: index) : mirror(pid: pid, index: index)
default:
    print("""
    usage:
      axprobe                    list every status item, as the app sees it
      axprobe --raw              ...include filtered placeholders, and AX attributes
      axprobe --press <pid> <n>  press item n of that pid
      axprobe --menu <pid> <n>   press item n, mirror the resulting menu, dismiss it
    """)
    exit(1)
}
