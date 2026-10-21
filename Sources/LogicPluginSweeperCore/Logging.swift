import Foundation
import os

public enum LogicPluginSweeperLog {
    public static let subsystem = "com.sybilillin.LogicPluginSweeper"
    public static let scanner = Logger(subsystem: subsystem, category: "scanner")
    public static let database = Logger(subsystem: subsystem, category: "database")
    public static let quarantine = Logger(subsystem: subsystem, category: "quarantine")
}
