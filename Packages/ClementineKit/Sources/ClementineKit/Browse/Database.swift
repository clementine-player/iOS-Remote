import Foundation
import SQLite3

public struct DatabaseError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public var description: String { message }
}

/// A small wrapper around an SQLite connection. Not thread-safe: each is used from one actor.
final class Database {
    private var handle: OpaquePointer?

    /// Opens the database at [path], or an in-memory one when nil.
    init(path: String?, readOnly: Bool = false) throws {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_NOMUTEX
        let result = sqlite3_open_v2(path ?? ":memory:", &handle, flags, nil)
        guard result == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Can't open the database"
            sqlite3_close(handle)
            handle = nil
            throw DatabaseError(message: message)
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Runs statements that return nothing.
    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(error)
            throw DatabaseError(message: message)
        }
    }

    /// Runs a query with text [arguments], returning each row's columns as text (nil for NULL).
    func query(_ sql: String, _ arguments: [String] = []) throws -> [[String?]] {
        let statement = try prepare(sql, arguments)
        defer { sqlite3_finalize(statement) }
        var rows: [[String?]] = []
        let columns = sqlite3_column_count(statement)
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE {
                break
            }
            guard step == SQLITE_ROW else { throw lastError }
            rows.append((0..<columns).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            })
        }
        return rows
    }

    /// Runs a statement with [arguments] of any SQLite type.
    func run(_ sql: String, _ arguments: [Value]) throws {
        let statement = try prepare(sql, [])
        defer { sqlite3_finalize(statement) }
        for (index, argument) in arguments.enumerated() {
            let position = Int32(index + 1)
            switch argument {
            case .text(let text):
                sqlite3_bind_text(statement, position, text, -1, Self.transient)
            case .integer(let value):
                sqlite3_bind_int64(statement, position, value)
            case .real(let value):
                sqlite3_bind_double(statement, position, value)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError }
    }

    enum Value {
        case text(String)
        case integer(Int64)
        case real(Double)
    }

    private func prepare(_ sql: String, _ arguments: [String]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError
        }
        for (index, argument) in arguments.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), argument, -1, Self.transient)
        }
        return statement
    }

    private var lastError: DatabaseError {
        DatabaseError(message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "No database")
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
