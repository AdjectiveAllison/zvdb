const std = @import("std");
const Allocator = std.mem.Allocator;
const AutoHashMap = std.AutoHashMap;
const ArrayList = std.ArrayList;

pub const HMMISConfig = struct {};
// Hierarchical Metadata-Mapped Index Structure
pub fn HMMIS(
    comptime T: type,
    comptime len: comptime_int,
) type {
    return struct {
        const Self = @This();

        // TODO: This needs a better type, but I like the tagged union approach of std.json.Value so it's there temporarily.
        const MetaData = AutoHashMap([]const u8, std.json.Value);

        const Cluster = struct {
            centroid: [len]T,
            metadata: MetaData,
            cells: ArrayList(Cell),
        };

        const Cell = struct {
            centroid: [len]T,
            // TODO: How does this map to ID later on?
            metadata: MetaData,
            embeddings: AutoHashMap(usize, [len]T),
        };
        allocator: Allocator,
        clusters: ArrayList(Cluster),

        pub fn init(allocator: Allocator, config: HMMISConfig) Self {

            // TODO: do something with config here.
            _ = config;
            return .{
                .allocator = allocator,
                .clusters = ArrayList(Cluster).init(allocator),
            };
        }

        pub fn deinit(self: *Self) !void {
            self.clusters.deinit();
        }
    };
}
