const std = @import("std");
const assets = @import("assets");

const not_found = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n" ++
    "Content-Length: 9\r\nConnection: close\r\n\r\nNot found";

pub fn serve(path: []const u8) ?[]const u8 {
    const clean = path[0 .. std.mem.indexOfAny(u8, path, "?#") orelse path.len];
    if (find(clean)) |response| return response;
    if (std.fs.path.extension(clean).len == 0) {
        if (find("/index.html")) |response| return response;
    }
    return not_found;
}

fn find(path: []const u8) ?[]const u8 {
    for (assets.files) |file| {
        if (std.mem.eql(u8, file.path, path)) return file.response;
    }
    return null;
}

test "unknown files are a 404, never a fallback to disk" {
    try std.testing.expectEqualStrings(not_found, serve("/no-such-file.js").?);
    try std.testing.expectEqualStrings(not_found, serve("/../build.zig").?);
}

test "routes get index.html, when there is one" {
    const index = find("/index.html") orelse return error.SkipZigTest;
    try std.testing.expectEqualStrings(index, serve("/").?);
    try std.testing.expectEqualStrings(index, serve("/profiles/3?tab=cpu").?);
    try std.testing.expect(std.mem.indexOf(u8, index, "/webui.js") != null);
}
