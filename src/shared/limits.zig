//! Size limits shared by layers that cannot import each other.

/// The largest config file, whether loaded at startup or kept as a session
/// snapshot.
pub const max_config = 64 * 1024;
