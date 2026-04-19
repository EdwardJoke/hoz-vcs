//! Error types for Hoz VCS
const std = @import("std");

/// Top-level Hoz error set
pub const Error = error{
    // Object database errors
    ObjectNotFound,
    ObjectAlreadyExists,
    InvalidObject,
    ObjectCorrupt,

    // OID errors
    InvalidOid,
    InvalidHexLength,

    // Ref errors
    RefNotFound,
    RefAlreadyExists,
    RefLocked,
    InvalidRefName,
    SymbolicRefBroken,

    // Index errors
    IndexCorrupt,
    IndexVersionMismatch,
    IndexConflict,

    // Tree errors
    TreeNotFound,
    TreeCorrupt,

    // Commit errors
    CommitNotFound,
    EmptyCommit,
    MergeConflict,

    // Reference resolution
    AmbiguousRef,
    DetachedHead,

    // Network/Protocol
    NetworkError,
    ProtocolError,
    AuthenticationFailed,
    ConnectionRefused,

    // File system
    PathNotFound,
    PathExists,
    PermissionDenied,
    IoError,

    // Configuration
    ConfigNotFound,
    ConfigInvalid,

    // General
    InvalidArgument,
    NotImplemented,
    InternalError,
};

/// Result type alias for convenience
pub fn Result(comptime T: type) type {
    Error!T;
}

/// Convert any error to Hoz error
pub fn fromAnyError(err: anyerror) Error {
    return switch (err) {
        error.ObjectNotFound => Error.ObjectNotFound,
        error.ObjectAlreadyExists => Error.ObjectAlreadyExists,
        error.InvalidObject => Error.InvalidObject,
        error.ObjectCorrupt => Error.ObjectCorrupt,
        error.InvalidOid => Error.InvalidOid,
        error.InvalidHexLength => Error.InvalidHexLength,
        error.RefNotFound => Error.RefNotFound,
        error.RefAlreadyExists => Error.RefAlreadyExists,
        error.RefLocked => Error.RefLocked,
        error.InvalidRefName => Error.InvalidRefName,
        error.SymbolicRefBroken => Error.SymbolicRefBroken,
        error.IndexCorrupt => Error.IndexCorrupt,
        error.IndexVersionMismatch => Error.IndexVersionMismatch,
        error.IndexConflict => Error.IndexConflict,
        error.TreeNotFound => Error.TreeNotFound,
        error.TreeCorrupt => Error.TreeCorrupt,
        error.CommitNotFound => Error.CommitNotFound,
        error.EmptyCommit => Error.EmptyCommit,
        error.MergeConflict => Error.MergeConflict,
        error.AmbiguousRef => Error.AmbiguousRef,
        error.DetachedHead => Error.DetachedHead,
        error.NetworkError => Error.NetworkError,
        error.ProtocolError => Error.ProtocolError,
        error.AuthenticationFailed => Error.AuthenticationFailed,
        error.ConnectionRefused => Error.ConnectionRefused,
        error.PathNotFound => Error.PathNotFound,
        error.PathExists => Error.PathExists,
        error.PermissionDenied => Error.PermissionDenied,
        error.IoError => Error.IoError,
        error.ConfigNotFound => Error.ConfigNotFound,
        error.ConfigInvalid => Error.ConfigInvalid,
        error.InvalidArgument => Error.InvalidArgument,
        error.NotImplemented => Error.NotImplemented,
        else => Error.InternalError,
    };
}

/// Error message helper - returns a human-readable string
pub fn errorMessage(err: Error) []const u8 {
    return switch (err) {
        Error.ObjectNotFound => "Object not found",
        Error.ObjectAlreadyExists => "Object already exists",
        Error.InvalidObject => "Invalid object format",
        Error.ObjectCorrupt => "Object is corrupted",
        Error.InvalidOid => "Invalid object ID format",
        Error.InvalidHexLength => "Invalid hex string length",
        Error.RefNotFound => "Reference not found",
        Error.RefAlreadyExists => "Reference already exists",
        Error.RefLocked => "Reference is locked",
        Error.InvalidRefName => "Invalid reference name",
        Error.SymbolicRefBroken => "Symbolic reference is broken",
        Error.IndexCorrupt => "Index file is corrupted",
        Error.IndexVersionMismatch => "Index version mismatch",
        Error.IndexConflict => "Index has conflicts",
        Error.TreeNotFound => "Tree not found",
        Error.TreeCorrupt => "Tree is corrupted",
        Error.CommitNotFound => "Commit not found",
        Error.EmptyCommit => "Cannot create empty commit",
        Error.MergeConflict => "Merge has conflicts",
        Error.AmbiguousRef => "Reference is ambiguous",
        Error.DetachedHead => "HEAD is detached",
        Error.NetworkError => "Network error",
        Error.ProtocolError => "Protocol error",
        Error.AuthenticationFailed => "Authentication failed",
        Error.ConnectionRefused => "Connection refused",
        Error.PathNotFound => "Path not found",
        Error.PathExists => "Path already exists",
        Error.PermissionDenied => "Permission denied",
        Error.IoError => "I/O error",
        Error.ConfigNotFound => "Configuration not found",
        Error.ConfigInvalid => "Invalid configuration",
        Error.InvalidArgument => "Invalid argument",
        Error.NotImplemented => "Not implemented",
        Error.InternalError => "Internal error",
    };
}

test "error message" {
    try std.testing.expectEqualStrings("Object not found", errorMessage(Error.ObjectNotFound));
    try std.testing.expectEqualStrings("Reference not found", errorMessage(Error.RefNotFound));
}
