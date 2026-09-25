//! Numbered slot values, shared by the output filter that receives them and
//! the sources that display them.

/// The longest value a slot accepts, after decoding.
pub const max_value = 1024;
/// Whether a slot value is expanded as markup or displayed literally.
pub const SlotMode = enum { markup, literal };
