import Testing

/// Parent suite that serializes all NoteIndexer ML test suites relative to each other,
/// preventing concurrent model loading and resource contention.
@Suite(.serialized)
struct NoteIndexerTests {}
