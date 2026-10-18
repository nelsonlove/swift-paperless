//
//  LaunchArguments.swift
//  AppShared
//
//  The one reading of a boolean launch flag, shared by the preview mode and
//  the debug mock library.
//

import Foundation

enum LaunchArguments {
  /// The value `argument` gives the boolean flag `flag`: `true` for the bare
  /// flag, the parsed value for `flag=<value>` (`0`, `false` and `no` are
  /// false, anything else true), and `nil` when `argument` is another one.
  static func boolValue(of flag: String, in argument: String) -> Bool? {
    if argument == flag {
      return true
    }
    guard argument.hasPrefix("\(flag)=") else { return nil }
    let value = argument.dropFirst(flag.count + 1).lowercased()
    return !(value == "0" || value == "false" || value == "no")
  }

  /// The value the last occurrence of `flag` in `arguments` gives it, or `nil`
  /// when it does not occur.
  static func flag(_ flag: String, in arguments: [String]) -> Bool? {
    arguments.reduce(nil) { value, argument in boolValue(of: flag, in: argument) ?? value }
  }
}
