//! Resolves Git URLs and metadata.
//!
//! This library mimics https://www.npmjs.com/package/hosted-git-info. At the
//! time of writing, the latest version is 9.0.0. Although @markovejnovic
//! believes there are bugs in the original library, this library aims to be
//! bug-for-bug compatible with the original.

// TODO(markovejnovic): This is a fraction of what hosted-git-info actually delivers, but it's the
// fraction that matters for us. If we want to make this API public, we will likely need to expose
// more information.
pub const HostedGitInfo = struct {
    type: []const u8,
};

/// Handles input like git:github.com:user/repo and inserting the // after the first : if necessary
///
/// May error with `error.InvalidGitUrl` if the URL is not valid.
///
/// Note that this may or may not allocate but it manages its own memory.
pub fn parseUrl(allocator: std.mem.Allocator, npa_str: []u8) !*bun.jsc.URL {
    // We can try to create a URL directly. If that succeeds, great. Ship it.
    if (bun.jsc.URL.fromString(.init(npa_str))) |url| {
        return url;
    }

    // Now that may fail, if the URL is not nicely formatted. In that case, we try to correct the
    // URL and parse it.
    const corrected = correctUrlMut(normalizeProtocol(npa_str));
    if (tryCreateUrl(allocator, &corrected)) |url| {
        return url;
    }

    // Otherwise, we complain.
    return error.InvalidGitUrl;
}

pub fn fromUrl(allocator: std.mem.Allocator, git_url: []u8) !?HostedGitInfo {
    var git_url_mut = git_url;
    if (isGithubShorthand(git_url)) {
        // In this case we have to prefix the url with `github:`.
        //
        // NOTE(markovejnovic): I don't exactly understand why this is treated specially.
        //
        // TODO(markovejnovic): Perhaps we can avoid this allocation...
        // This one seems quite easy to get rid of.
        git_url_mut = try bun.strings.concat(allocator, &.{ "github:", git_url });
        defer allocator.free(git_url_mut);
    }

    const parsed: *bun.jsc.URL = try parseUrl(allocator, git_url_mut);
    defer parsed.deinit();

    if (deduceHostInfo(parsed)) |host_info| {
        return .{
            // We have to slice out the colon at the end, since the user isn't expecting that.
            .type = host_info.shortcut[0 .. host_info.shortcut.len - 1],
        };
    }

    // Now that we parsed the URL, great, we can try to we can look up the host by the protocol.
    // So, you might actually find something like this:
    // github://foo/bar or sourcehut://foo/bar
    // We have to now determine the shortcut.
    return null;
}

pub const TestingAPIs = struct {
    pub fn jsParseUrl(go: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) bun.JSError!jsc.JSValue {
        const allocator = bun.default_allocator;

        if (callframe.argumentsCount() != 1) {
            return go.throw(
                "hostedGitInfo.prototype.parseUrl takes exactly 1 argument",
                .{},
            );
        }

        const arg0 = callframe.argument(0);
        if (!arg0.isString()) {
            return go.throw(
                "hostedGitInfo.prototype.parseUrl takes a string as its " ++
                    "first argument",
                .{},
            );
        }

        // TODO(markovejnovic): This feels like there's too much going on all
        // to give us a slice. Maybe there's a better way to code this up.
        const npa_str = try arg0.toBunString(go);
        defer npa_str.deref();
        var as_utf8 = npa_str.toUTF8(allocator);
        defer as_utf8.deinit();
        const parsed = parseUrl(allocator, as_utf8.mut()) catch |err| {
            return go.throw("Invalid Git URL: {}", .{err});
        };

        return parsed.href().toJS(go);
    }

    pub fn jsFromUrl(go: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) bun.JSError!jsc.JSValue {
        const allocator = bun.default_allocator;

        // TODO(markovejnovic): The original hosted-git-info actually takes another argument that
        //                      allows you to inject options. Seems untested so we didn't implement
        //                      it.
        if (callframe.argumentsCount() != 1) {
            return go.throw("hostedGitInfo.prototype.fromUrl takes exactly 1 argument", .{});
        }

        const arg0 = callframe.argument(0);
        if (!arg0.isString()) {
            return go.throw(
                "hostedGitInfo.prototype.fromUrl takes a string as its first argument",
                .{},
            );
        }

        // TODO(markovejnovic): This feels like there's too much going on all to give us a slice.
        // Maybe there's a better way to code this up.
        const npa_str = try arg0.toBunString(go);
        defer npa_str.deref();
        var as_utf8 = npa_str.toUTF8(allocator);
        defer as_utf8.deinit();
        const parsed = fromUrl(allocator, as_utf8.mut()) catch |err| {
            return go.throw("Invalid Git URL: {}", .{err});
        } orelse {
            return .null;
        };

        return bun.String.fromBytes(parsed.type).toJS(go);
    }

    const jsc = bun.jsc;
};

/// Enumeration of possible URL protocols. Note that this enumeration has a
/// many-to-one relationship with Protocol.
const UrlProtocol = enum {
    git_plus_ssh,
    ssh,
    git_plus_https,
    git,
    http,
    https,
    git_plus_http,
};

const url_protocol_strings = bun.ComptimeStringMap(UrlProtocol, .{
    .{ "git+ssh:", .git_plus_ssh },
    .{ "ssh:", .ssh },
    .{ "git+https:", .git_plus_https },
    .{ "git:", .git },
    .{ "http:", .http },
    .{ "https:", .https },
    .{ "git+http:", .git_plus_http },
});

const Host = enum {
    github,
    bitbucket,
    gitlab,
    gist,
    sourcehut,
};

const HostInfo = struct {
    protocols: []const UrlProtocol,
    domain: []const u8,
    shortcut: []const u8,
    tree_path: ?[]const u8,
    blob_path: ?[]const u8,
    edit_path: ?[]const u8,
    edit_template: u8, // TODO(markovejnovic): Wrong type obviously lol
    tarball_template: u8, // TODO(markovejnovic): Wrong type obviously lol
    extract: u8, // TODO(markovejnovic): Wrong type obviously lol
};

fn getHostInfo(host: Host) HostInfo {
    return switch (host) {
        .github => .{
            .protocols = &.{
                .git,
                .http,
                .git_plus_ssh,
                .git_plus_https,
                .ssh,
                .https,
            },
            .domain = "github.com",
            .shortcut = "github:",
            .tree_path = "tree",
            .blob_path = "blob",
            .edit_path = "edit",
            .edit_template = 0,
            .tarball_template = 0,
            .extract = 0,
        },
        .bitbucket => .{
            .protocols = &.{ .git_plus_ssh, .git_plus_https, .ssh, .https },
            .domain = "bitbucket.org",
            .shortcut = "bitbucket:",
            .tree_path = "src",
            .blob_path = "src",
            .edit_path = "?mode=edit",
            .edit_template = 0,
            .tarball_template = 0,
            .extract = 0,
        },
        .gitlab => .{
            .protocols = &.{ .git_plus_ssh, .git_plus_https, .ssh, .https },
            .domain = "gitlab.com",
            .shortcut = "gitlab:",
            .tree_path = "tree",
            .blob_path = "tree",
            .edit_path = "-/edit",
            .edit_template = 0,
            .tarball_template = 0,
            .extract = 0,
        },
        .gist => .{
            .protocols = &.{
                .git,
                .git_plus_ssh,
                .git_plus_https,
                .ssh,
                .https,
            },
            .domain = "gist.github.com",
            .shortcut = "gist:",
            .tree_path = null,
            .blob_path = null,
            .edit_path = "edit",
            .edit_template = 0,
            .tarball_template = 0,
            .extract = 0,
        },
        .sourcehut => .{
            .protocols = &.{ .git_plus_ssh, .https },
            .domain = "git.sr.ht",
            .shortcut = "sourcehut:",
            .tree_path = "tree",
            .blob_path = "tree",
            .edit_path = null,
            .edit_template = 0,
            .tarball_template = 0,
            .extract = 0,
        },
    };
}

/// Search for the appropriate `HostInfo` by the protocol string.
fn findHostInfoByProtocol(protocol: []const u8) ?HostInfo {
    inline for (@typeInfo(Host).@"enum".fields) |field| {
        const host: Host = @enumFromInt(field.value);
        const info = getHostInfo(host);
        // We slice the last character off since URL.protocol() returns foo out of foo:// and
        // info.shortcut includes the colon.
        if (std.mem.eql(u8, info.shortcut[0 .. info.shortcut.len - 1], protocol)) {
            return info;
        }
    }
    return null;
}

fn findHostInfoByDomain(hostname: []const u8) ?HostInfo {
    inline for (@typeInfo(Host).@"enum".fields) |field| {
        const host: Host = @enumFromInt(field.value);
        const info = getHostInfo(host);
        if (std.mem.eql(u8, info.domain, hostname)) {
            return info;
        }
    }
    return null;
}

/// Search the the appropriate `HostInfo` by deducing it from the URL.
fn deduceHostInfo(url: *bun.jsc.URL) ?HostInfo {
    const proto_str = url.protocol();
    if (findHostInfoByProtocol(proto_str.byteSlice())) |host_info| {
        return host_info;
    }

    // TODO(markovejnovic): I don't know if this conversion is correct.
    const as_slice = url.hostname().byteSlice();
    const hostname = bun.strings.withoutPrefixComptime(as_slice, "www.");
    if (findHostInfoByDomain(hostname)) |host_info| {
        return host_info;
    }

    return null;
}

/// Test whether the given node-package-arg string is a GitHub shorthand.
///
/// This mirrors the implementation of hosted-git-info, though it is significantly faster.
fn isGithubShorthand(
    npa_str: []const u8,
) bool {
    // The implementation in hosted-git-info is a multi-pass algorithm. We've opted to implement a
    // single-pass algorithm for better performance.
    //
    // This could be even faster with SIMD but this is probably good enough for now.
    if (npa_str.len < 1) {
        return false;
    }

    // Implements doesNotStartWithDot
    if (npa_str[0] == '.' or npa_str[0] == '/') {
        return false;
    }

    var pound_idx: ?u32 = null;
    var seen_slash = false;

    for (npa_str, 0..) |c, i| {
        switch (c) {
            // Implement atOnlyAfterHash and colonOnlyAfterHash
            ':', '@' => {
                if (pound_idx == null) {
                    return false;
                }
            },

            '#' => {
                pound_idx = @intCast(i);
            },
            '/' => {
                // Implements secondSlashOnlyAfterHash
                if (seen_slash and pound_idx == null) {
                    return false;
                }

                seen_slash = true;
            },
            else => {
                // Implement spaceOnlyAfterHash
                if (std.ascii.isWhitespace(c) and pound_idx == null) {
                    return false;
                }
            },
        }
    }

    // Implements doesNotEndWithSlash
    const does_not_end_with_slash =
        if (pound_idx) |pi|
            npa_str.len > 2 and npa_str[pi - 1] != '/'
        else
            npa_str[npa_str.len - 1] != '/';

    // Implement hasSlash
    return seen_slash and does_not_end_with_slash;
}

const UrlProtocolPair = struct {
    url: []u8,
    protocol: union(enum) {
        well_formed: UrlProtocol,

        // A protocol which is not known by the library. Includes the : character, but not the
        // double-slash, so `foo://bar` would yield `foo:`.
        custom: []u8,

        // Either no protocol was speecified or the library couldn't figure it out.
        unknown: void,
    },
};

/// Given a loose string that may or may not be a valid URL, attempt to normalize it.
///
/// This never allocates but requires `npa_str` be stable.
///
/// Returns a struct containing the URL string with the `protocol://` part removed and a tagged
/// enumeration. If the protocol is known, it is returned as a UrlProtocol. If the protocol is
/// specified in the URL, it is given as a slice and if it is not specified, the `unknown` field is
/// returned.
///
/// This mirrors the `correctProtocol` function in `hosted-git-info/parse-url.js`.
fn normalizeProtocol(npa_str: []u8) UrlProtocolPair {
    var first_colon_idx: i32 = -1;
    if (bun.strings.indexOfChar(npa_str, ':')) |idx| {
        first_colon_idx = @intCast(idx);
    }

    // The cast here is safe -- first_colon_idx is guaranteed to be [-1, infty)
    const proto_slice = npa_str[0..@intCast(first_colon_idx + 1)];

    if (url_protocol_strings.get(proto_slice)) |url_protocol| {
        // We need to slice off the protocol from the string. Note there are two very annoying
        // cases -- one where the protocol string is foo://bar and one where it is foo:bar.
        var post_colon = bun.strings.dropMut(
            npa_str,
            @intCast(first_colon_idx + 1),
        );

        return .{
            .url = if (bun.strings.hasPrefixComptime(post_colon, "//"))
                post_colon[2..post_colon.len]
            else
                post_colon,
            .protocol = .{ .well_formed = url_protocol },
        };
    }

    // Now we search for the @ character to see if we have a user@host:path GIT+SSH style URL.
    const first_at_idx = bun.strings.indexOfChar(npa_str, '@');
    if (first_at_idx) |at_idx| {
        // We have an @ in the string
        if (first_colon_idx != -1) {
            // We have a : in the string.
            if (at_idx > first_colon_idx) {
                // The @ is after the :, so we have something like user:pass@host which is a valid
                // URL. and should be promoted to git_plus_ssh. It's guaranteed that the issue is
                // not that we have proto://user@host:path because we would've caught that above.
                return .{ .url = npa_str, .protocol = .{ .well_formed = .git_plus_ssh } };
            } else {
                // Otherwise we have something like user@host:path which is also a valid URL.
                // Things are, however, different, since we don't really know what the protocol is.
                // Remember, we would've hit the proto://user@host:path above.

                // NOTE(markovejnovic): I don't, at this moment, understand how exactly
                // hosted-git-info and npm-package-arg handle this "unknown" protocol as of now.
                // We can't really guess either -- there's no :// which comes before @
                return .{ .url = npa_str, .protocol = .unknown };
            }
        } else {
            // Something like user@host which is also a valid URL. Since no :, that means that the
            // URL is as good as it gets. No need to slice.
            return .{ .url = npa_str, .protocol = .{ .well_formed = .git_plus_ssh } };
        }
    }

    // The next thing we can try is to search for the double slash and treat this protocol as a
    // custom one.
    //
    // NOTE(markovejnovic): I also think this is wrong in parse-url.js.
    // They:
    // 1. Test the protocol against known protocols (which is fine)
    // 2. Then, if not found, they go through that hoop of checking for @ and : guessing if it is a
    //    git+ssh URL or not
    // 3. And finally, they search for ://.
    //
    // The last two steps feel like they should happen in reverse order:
    //
    // If I have a foobar://user:host@path URL (and foobar is not given as a known protocol), their
    // implementation will not report this as a foobar protocol, but rather as
    // git+ssh://foobar://user:host@path which is obviously a joke.
    //
    // I even tested it: https://tinyurl.com/5y4e6zrw
    //
    // Our goal is to be bug-for-bug compatible, at least for now, so this is how I re-implemented
    // it.
    const maybe_dup_slash_idx = bun.strings.indexOf(npa_str, "//");
    if (maybe_dup_slash_idx) |dup_slash_idx| {
        if (dup_slash_idx == first_colon_idx + 1) {
            return .{
                .url = bun.strings.dropMut(npa_str, dup_slash_idx + 2),
                .protocol = .{ .custom = npa_str[0..dup_slash_idx] },
            };
        }
    }

    // Well, otherwise we have to split the original URL into two pieces,
    // right at the colon.
    if (first_colon_idx != -1) {
        return .{
            .url = bun.strings.dropMut(npa_str, @intCast(first_colon_idx + 1)),
            .protocol = .{ .custom = npa_str[0..@intCast(first_colon_idx + 1)] },
        };
    }

    // Well we couldn't figure out anything.
    return .{ .url = npa_str, .protocol = .unknown };
}

/// Attempt to correct an scp-style URL into a proper URL, parsable with bun.jsc.URL. Potentially
/// mutates the original input.
///
/// This function assumes that the input is an scp-style URL.
fn correctUrlMut(url_proto_pair: UrlProtocolPair) UrlProtocolPair {
    var at_idx: i32 = undefined;
    var col_idx: i32 = undefined;
    if (bun.strings.lastIndexBeforeChar(url_proto_pair.url, '@', '#')) |idx| {
        at_idx = @intCast(idx);
    } else {
        at_idx = -1;
    }

    if (bun.strings.lastIndexBeforeChar(url_proto_pair.url, ':', '#')) |idx| {
        col_idx = @intCast(idx);
    } else {
        col_idx = -1;
    }

    if (col_idx > at_idx) {
        url_proto_pair.url[@intCast(col_idx)] = '/';
        return url_proto_pair;
    }

    if (col_idx == -1 and url_proto_pair.protocol == .unknown) {
        return .{
            .url = url_proto_pair.url,
            .protocol = .{ .well_formed = .git_plus_ssh },
        };
    }

    return url_proto_pair;
}

fn concatPartsToUrl(allocator: std.mem.Allocator, parts: []const []const u8) ?*bun.jsc.URL {
    // TODO(markovejnovic): There is a sad unnecessary allocation here that I don't know how to get
    // rid of -- in theory, URL.zig could allocate once.
    const new_str = bun.handleOom(bun.strings.concat(allocator, parts));
    defer allocator.free(new_str);
    return bun.jsc.URL.fromString(bun.String.init(new_str));
}

/// Given a protocol pair, create a bun.jsc.URL if possible.
///
/// May allocate, but owns its memory.
fn tryCreateUrl(allocator: std.mem.Allocator, proto_pair: *const UrlProtocolPair) ?*bun.jsc.URL {
    // Ehhh.. Old IE's max path length was 2K so let's just use that.
    // I searched for a statistical distribution and found nothing.
    const LONG_URL_THRESH = 2048;

    var alloc = std.heap.stackFallback(LONG_URL_THRESH, allocator);

    switch (proto_pair.protocol) {
        .unknown => {
            // Honestly, we're kind of SOL here. Let's try parsing this as-is and if it works, hey,
            // great, if it doesn't, well, we're pretty cooked.
            return bun.jsc.URL.fromString(.init(proto_pair.url));
        },
        .custom => |proto_str| {
            return concatPartsToUrl(
                alloc.get(),
                &.{ proto_str, "//", proto_pair.url },
            );
        },
        .well_formed => |proto_tag| {
            return concatPartsToUrl(
                alloc.get(),
                &.{
                    url_protocol_strings.getStringRuntime(proto_tag),
                    "//",
                    proto_pair.url,
                },
            );
        },
    }
}

const bun = @import("bun");
const std = @import("std");
