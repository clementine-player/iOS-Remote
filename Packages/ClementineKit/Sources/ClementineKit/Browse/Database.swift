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
        // Text in order for the phone's language, whatever its case or accents: SQLite's own
        // collation orders text by its bytes, putting "abba" after "ZZ Top", and "Émile" after
        // both. Named as the one Android's SQLite has, so both clients' SQL is the same. Names
        // differing only in case are equal here: the query then orders them by their bytes, so
        // "Apple" comes before "apple" on both clients.
        sqlite3_create_collation_v2(handle, "LOCALIZED", SQLITE_UTF8, nil, { _, length1, text1, length2, text2 in
            let first = String(decoding: UnsafeRawBufferPointer(start: text1, count: Int(length1)), as: UTF8.self)
            let second = String(decoding: UnsafeRawBufferPointer(start: text2, count: Int(length2)), as: UTF8.self)
            switch first.compare(second, options: .caseInsensitive, locale: .current) {
            case .orderedAscending: return -1
            case .orderedSame: return 0
            case .orderedDescending: return 1
            }
        }, nil)
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
        bind(statement, arguments)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError }
    }

    /// Runs a query with [arguments] of any SQLite type, returning each row's columns with their
    /// own types.
    func rows(_ sql: String, _ arguments: [Value] = []) throws -> [[Value]] {
        let statement = try prepare(sql, [])
        defer { sqlite3_finalize(statement) }
        bind(statement, arguments)
        var rows: [[Value]] = []
        let columns = sqlite3_column_count(statement)
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE {
                break
            }
            guard step == SQLITE_ROW else { throw lastError }
            rows.append((0..<columns).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER:
                    return .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT:
                    return .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT:
                    return .text(String(cString: sqlite3_column_text(statement, column)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    guard let bytes = sqlite3_column_blob(statement, column), count > 0 else {
                        return .blob(Data())
                    }
                    return .blob(Data(bytes: bytes, count: count))
                default:
                    return .null
                }
            })
        }
        return rows
    }

    /// The rowid of the last row inserted.
    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// How many rows the last statement changed.
    var changes: Int { Int(sqlite3_changes(handle)) }

    enum Value: Equatable {
        case null
        case text(String)
        case integer(Int64)
        case real(Double)
        case blob(Data)

        var text: String? {
            if case .text(let text) = self { return text }
            return nil
        }

        var integer: Int64? {
            if case .integer(let value) = self { return value }
            return nil
        }

        var real: Double? {
            switch self {
            case .real(let value): value
            case .integer(let value): Double(value)
            default: nil
            }
        }

        var blob: Data? {
            if case .blob(let data) = self { return data }
            return nil
        }
    }

    private func bind(_ statement: OpaquePointer?, _ arguments: [Value]) {
        for (index, argument) in arguments.enumerated() {
            let position = Int32(index + 1)
            switch argument {
            case .null:
                sqlite3_bind_null(statement, position)
            case .text(let text):
                sqlite3_bind_text(statement, position, text, -1, Self.transient)
            case .integer(let value):
                sqlite3_bind_int64(statement, position, value)
            case .real(let value):
                sqlite3_bind_double(statement, position, value)
            case .blob(let data) where data.isEmpty:
                // A null pointer would bind NULL rather than an empty blob.
                sqlite3_bind_zeroblob(statement, position, 0)
            case .blob(let data):
                _ = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, position, bytes.baseAddress, Int32(data.count), Self.transient)
                }
            }
        }
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
