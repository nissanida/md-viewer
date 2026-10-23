// Sends a command to an MD Viewer launched with MDV_AUTOMATION=1 (development only).
//   swiftc scripts/automate.swift -o automate
//   ./automate "snapshot /tmp/window.png"     ./automate "action toggleTerminal:"
//   ./automate "open /path/to/file.md"        ./automate "appearance dark"
import Foundation

let command = CommandLine.arguments.dropFirst().joined(separator: " ")
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("dev.mdviewer.automation"), object: command, userInfo: nil, deliverImmediately: true)
