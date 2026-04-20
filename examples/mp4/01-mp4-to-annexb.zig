const std = @import("std");
const Reader = @import("reader.zig");
const Box = @import("formats").mp4.Box;

const H264ParameterSetIterator = struct {
    data: []const u8,
    offset: usize = 0,
    num_sps: u8,
    num_pps: u8 = 0,

    fn init(data: []const u8) H264ParameterSetIterator {
        return .{ .data = data, .num_sps = data[0] & 0x1F, .offset = 1 };
    }

    fn next(self: *H264ParameterSetIterator) ?[]const u8 {
        if (self.offset >= self.data.len) return null;

        if (self.num_sps > 0) {
            if (self.getNalu()) |result| {
                self.num_sps -= 1;
                if (self.num_sps == 0) {
                    self.num_pps = self.data[self.offset];
                    self.offset += 1;
                }

                return result;
            }

            return null;
        }

        if (self.num_pps == 0) return null;
        if (self.getNalu()) |result| {
            self.num_pps -= 1;
            return result;
        }
        return null;
    }

    fn getNalu(self: *H264ParameterSetIterator) ?[]const u8 {
        const nal_size = std.mem.readInt(u16, self.data[self.offset..][0..2], .big);
        self.offset += nal_size + 2;
        if (self.offset > self.data.len) return null;
        return self.data[self.offset - nal_size .. self.offset];
    }
};

/// This example shows how to read an MP4 file and write it back to disk in Annex B format, which is a common format for H.264/H.265 video streams.
/// The code reads the MP4 file, extracts the video track, and writes the video data in Annex B format to a new file.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args_iterator = try std.process.ArgIterator.initWithAllocator(allocator);
    defer args_iterator.deinit();
    _ = args_iterator.skip(); // Skip the program name

    const source = args_iterator.next();
    if (source == null) {
        std.debug.print("Usage: mp4_to_annexb <input.mp4>\n", .{});
        return;
    }

    var reader = try Reader.init(allocator, source.?);
    defer reader.deinit(allocator);

    // Get the video track id
    var trak: ?*Box.Trak = null;
    for (reader.moov.traks.items) |*trak2| {
        switch (trak2.codec()) {
            .h264, .h265 => trak = trak2,
            else => continue,
        }
    }

    if (trak == null) {
        std.debug.print("No h264/h265 video track found in the MP4 file.\n", .{});
        return;
    }

    // Get the prefix length of each NAL unit
    const codec_config = trak.?.mdia.minf.stbl.stsd.entries.items[0].video.codec_config;
    const nalu_length = switch (codec_config) {
        .avc => |config| blk: {
            if (config.len < 5) return error.InvalidCodecConfig;
            break :blk config[4] & 0x03 + 1;
        },
        .hvc => |config| blk: {
            if (config.len < 22) return error.InvalidCodecConfig;
            break :blk config[21] & 0x03 + 1;
        },
        else => return error.UnsupportedCodec,
    };

    var iterator = try reader.sampleIterator(allocator, .{ .tracks = &[_]u32{trak.?.tkhd.track_id} });
    defer iterator.deinit();

    const out_path = args_iterator.next() orelse switch (codec_config) {
        .avc => "test.h264",
        .hvc => "test.h265",
        else => unreachable,
    };

    var out_file = try std.fs.cwd().createFile(out_path, .{ .truncate = true });
    defer out_file.close();

    var write_buffer: [4096]u8 = undefined;
    var writer = out_file.writer(&write_buffer);

    switch (codec_config) {
        .avc => |config| {
            var ps_iterator = H264ParameterSetIterator.init(config[5..]);
            while (ps_iterator.next()) |parameter_set| {
                try writer.interface.writeAll(&[4]u8{ 0, 0, 0, 1 });
                try writer.interface.writeAll(parameter_set);
            }
        },
        else => {},
    }

    while (try iterator.next()) |sample| {
        const sample_size = sample.metadata.size;
        var offset: usize = 0;
        while (offset < sample_size) {
            if (offset + nalu_length > sample_size) return error.InvalidSample;
            var nalu_size: u32 = 0;
            for (sample.data[offset .. offset + nalu_length]) |byte| {
                nalu_size = (nalu_size << 8) | byte;
            }

            if (offset + nalu_length + nalu_size > sample_size) return error.InvalidSample;
            offset += nalu_length + nalu_size;

            try writer.interface.writeAll(&[4]u8{ 0, 0, 0, 1 });
            try writer.interface.writeAll(sample.data[offset - nalu_size .. offset]);
        }
    }

    try writer.interface.flush();
    std.debug.print("Done writing file\n", .{});
}
