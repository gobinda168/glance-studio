import AppKit
import Darwin
import GlanceCore

/// Which Studio split a `claude` runs in (spec "Parts", "Session → tab"): the split whose foreground process group is
/// the `claude`'s group. And whether that `claude` was started with the channel flag.
@MainActor
enum ChannelSessions {
    static func resolve(claudePID: Int32) -> (surface: String?, channel: Bool) {
        let arguments = ProcessArguments.read(pid: Int(claudePID))?.arguments ?? []
        let channel = ChannelLaunch.hasChannel(arguments: arguments)
        let group = getpgid(claudePID)
        guard group > 0 else { return (nil, channel) }
        for controller in TerminalController.all {
            for view in controller.surfaceTree where view.surfaceModel?.foregroundPID == Int(group) {
                return (view.id.uuidString, channel)
            }
        }
        return (nil, channel)
    }
}
