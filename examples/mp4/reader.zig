const std = @import("std");
const mp4 = @import("formats").mp4;

const Reader = @This();
const Box = mp4.Box;

file: std.fs.File,
moov: mp4.Box.Moov,

pub const Sample = struct {
    track_id: u32,
    metadata: Box.SampleMetadata,
    data: []const u8,
};

pub fn init(allocator: std.mem.Allocator, path: []const u8) !Reader {
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });

    var moov: ?mp4.Box.Moov = null;
    errdefer if (moov) |*box| box.deinit(allocator);

    var buffer: [1024]u8 = undefined;
    var reader = file.reader(&buffer);

    while (true) {
        const header = try Box.Header.parse(&reader.interface);

        switch (header.type) {
            .moov => {
                moov = try Box.Moov.parse(allocator, header, &reader.interface);
                break;
            },
            else => try reader.seekBy(@intCast(header.payloadSize())),
        }
    }

    if (moov == null) {
        return error.InvalidMP4File;
    }

    return .{ .file = file, .moov = moov.? };
}

pub fn deinit(self: *Reader, allocator: std.mem.Allocator) void {
    self.moov.deinit(allocator);
    self.file.close();
}

pub fn sampleIterator(self: *Reader, allocator: std.mem.Allocator, config: IteratorConfig) !SampleIterator {
    return SampleIterator.init(allocator, self, config);
}

pub const IteratorConfig = struct {
    tracks: ?[]const u32,
};

pub const SampleIterator = struct {
    pub const Track = struct {
        track_id: u32,
        timescale: u32,
        metadata_iterator: mp4.SampleIterator,
        curr_sample: ?Box.SampleMetadata,
        done: bool = false,
    };

    allocator: std.mem.Allocator,
    file: std.fs.File,
    tracks: []Track,
    data: []u8,

    fn init(allocator: std.mem.Allocator, reader: *Reader, config: IteratorConfig) !SampleIterator {
        const tracks_length = if (config.tracks) |tracks| tracks.len else reader.moov.traks.items.len;
        var tracks = try std.ArrayList(Track).initCapacity(allocator, tracks_length);
        errdefer tracks.deinit(allocator);

        for (reader.moov.traks.items) |*trak| {
            if (config.tracks) |track_ids| {
                const track_id = trak.tkhd.track_id;
                if (std.mem.indexOfScalar(u32, track_ids, track_id) == null) {
                    continue;
                }
            }

            tracks.appendAssumeCapacity(.{
                .track_id = trak.tkhd.track_id,
                .timescale = trak.mdia.mdhd.timescale,
                .metadata_iterator = trak.sampleIterator(),
                .curr_sample = null,
            });
        }

        return .{
            .allocator = allocator,
            .file = reader.file,
            .tracks = try tracks.toOwnedSlice(allocator),
            .data = try allocator.alloc(u8, 4096),
        };
    }

    pub fn deinit(self: *SampleIterator) void {
        self.allocator.free(self.tracks);
        self.allocator.free(self.data);
    }

    pub fn next(self: *SampleIterator) !?Sample {
        var earliest_track: ?*Track = null;

        for (self.tracks) |*track| {
            if (track.done) continue;

            if (track.curr_sample == null) {
                track.curr_sample = track.metadata_iterator.next();
                if (track.curr_sample == null) {
                    track.done = true;
                    continue;
                }
            }

            if (earliest_track) |earliest| {
                const dts = track.curr_sample.?.dts * earliest.timescale / track.timescale;
                if (dts < earliest.curr_sample.?.dts) {
                    earliest_track = track;
                }
            } else {
                earliest_track = track;
            }
        }

        if (earliest_track == null) return null;

        const track = earliest_track.?;
        const sample = track.curr_sample.?;
        earliest_track.?.curr_sample = null;

        if (self.data.len < sample.size) {
            self.data = try self.allocator.realloc(self.data, sample.size);
        }

        _ = try self.file.pread(self.data[0..sample.size], sample.offset);

        return .{
            .track_id = track.track_id,
            .metadata = sample,
            .data = self.data[0..sample.size],
        };
    }
};
