pub const Box = @import("box.zig");
pub const Reader = @import("reader.zig");
pub const Writer = @import("writer.zig");

pub const SampleMetadata = Box.SampleMetadata;
pub const SampleIterator = Box.SampleIterator;

test {
    _ = @import("box.zig");
    _ = @import("reader.zig");
    _ = @import("writer.zig");
}
