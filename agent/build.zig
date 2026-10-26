//! Everything the build needs for the agent, in one place
const std = @import("std");

const libelf_dir = "third_party/libelf";

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// The agent's tests are added to this step, so one `zig build test` runs everything.
    test_step: *std.Build.Step,
};

/// Builds the agent and returns its module.
pub fn add(b: *std.Build, options: Options) *std.Build.Module {
    // The one and only ebpf module: C libs and kernel programs attach here.
    const ebpf = b.createModule(.{
        .root_source_file = b.path("agent/ebpf/root.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
    });
    addCLibraries(b, ebpf, options);
    addKernelProgram(b, ebpf, "oncpu", "agent/ebpf/kernel/oncpu.ebpf.zig");

    // for testing only
    addKernelProgram(b, ebpf, "oncpu_testing", "agent/ebpf/kernel/oncpu.ebpf_testing.zig");

    const module = b.createModule(.{
        .root_source_file = b.path("agent/root.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
    });
    module.addImport("ebpf", ebpf);

    addTests(b, module, ebpf, options.test_step);
    return module;
}

// ------------------------------------------------------------ kernel programs

/// Compiles a kernel program written in Zig for the BPF target and embeds the result.
/// It must be optimized (the verifier rejects unoptimized code). Debug information is kept;
/// our loader ignores it, but it helps when inspecting the file.
fn addKernelProgram(b: *std.Build, module: *std.Build.Module, name: []const u8, source: []const u8) void {
    const object = b.addObject(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .bpfel, .os_tag = .freestanding }),
            .optimize = .ReleaseSmall,
            .strip = false,
        }),
    });
    module.addImport(b.fmt("{s}_bpf", .{name}), b.createModule(.{
        .root_source_file = object.getEmittedBin(),
    }));
    const installed = b.addInstallFile(object.getEmittedBin(), b.fmt("bpf/{s}.bpf.o", .{name}));
    b.getInstallStep().dependOn(&installed.step);
}

/// Runs the agent's tests, and also installs the test binary as zig-out/bin/agent-tests, so
/// the tests that need root can be run with sudo without building as root.
fn addTests(
    b: *std.Build,
    agent_module: *std.Build.Module,
    ebpf_module: *std.Build.Module,
    test_step: *std.Build.Step,
) void {
    // Tests inside agent/ebpf/**
    const ebpf_tests = b.addTest(.{ .root_module = ebpf_module });
    test_step.dependOn(&b.addRunArtifact(ebpf_tests).step);
    test_step.dependOn(&b.addInstallArtifact(ebpf_tests, .{
        .dest_sub_path = "agent-ebpf-tests",
    }).step);

    // Tests inside agent/** (root.zig and everything it @imports by file)
    const agent_tests = b.addTest(.{ .root_module = agent_module });
    test_step.dependOn(&b.addRunArtifact(agent_tests).step);
    test_step.dependOn(&b.addInstallArtifact(agent_tests, .{
        .dest_sub_path = "agent-tests",
    }).step);
}

// ---------------------------------------------------------------- C libraries
// The C code the agent still links, built from source as static libraries so the final
// binary needs nothing installed:
//
//   libbpf  the low-level kernel calls used by libbpf.zig (map create, update, lookup,
//           delete, program load). Pinned in build.zig.zon.
//   libelf  not called by our code, but libbpf needs it at link time. Vendored in
//           third_party/libelf (elfutils has no tarball that Zig can fetch).
//   zlib    needed by libelf. Pinned in build.zig.zon.

const c_flags = [_][]const u8{
    "-O2",
    "-w",
    "-D_LARGEFILE64_SOURCE",
    "-D_FILE_OFFSET_BITS=64",
};

fn addCLibraries(b: *std.Build, module: *std.Build.Module, options: Options) void {
    const zlib = addZlib(b, options);
    const elf = addLibelf(b, options, zlib.root);
    const bpf = addLibbpf(b, options, zlib.root);

    bpf.lib.root_module.linkLibrary(elf);
    bpf.lib.root_module.linkLibrary(zlib.lib);

    module.linkLibrary(bpf.lib);
    module.addIncludePath(bpf.public_headers); // <bpf/bpf.h>, <bpf/libbpf.h>
    module.addIncludePath(bpf.uapi); // <linux/bpf.h>
}

fn newLib(b: *std.Build, name: []const u8, options: Options) *std.Build.Step.Compile {
    return b.addLibrary(.{
        .name = name,
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = options.target,
            .optimize = options.optimize,
            .link_libc = true,
        }),
    });
}

// ------------------------------------------------------------------------ zlib

const Zlib = struct { lib: *std.Build.Step.Compile, root: std.Build.LazyPath };

fn addZlib(b: *std.Build, options: Options) Zlib {
    const dep = b.dependency("zlib", .{});
    const lib = newLib(b, "z", options);
    lib.root_module.addIncludePath(dep.path("."));
    lib.root_module.addCSourceFiles(.{
        .root = dep.path("."),
        .files = &zlib_sources,
        .flags = &(c_flags ++ .{"-DHAVE_UNISTD_H"}),
    });
    return .{ .lib = lib, .root = dep.path(".") };
}

const zlib_sources = [_][]const u8{
    "adler32.c", "compress.c", "crc32.c",   "deflate.c", "gzclose.c",
    "gzlib.c",   "gzread.c",   "gzwrite.c", "infback.c", "inffast.c",
    "inflate.c", "inftrees.c", "trees.c",   "uncompr.c", "zutil.c",
};

// ---------------------------------------------------------------------- libelf

fn addLibelf(b: *std.Build, options: Options, zlib_root: std.Build.LazyPath) *std.Build.Step.Compile {
    const lib = newLib(b, "elf", options);
    const m = lib.root_module;
    m.addIncludePath(b.path(libelf_dir ++ "/shim")); // our config.h comes first
    m.addIncludePath(b.path(libelf_dir ++ "/libelf"));
    m.addIncludePath(b.path(libelf_dir ++ "/lib"));
    m.addIncludePath(zlib_root);
    m.addCSourceFiles(.{
        .root = b.path(libelf_dir ++ "/libelf"),
        .files = &libelf_sources,
        .flags = &(c_flags ++ .{"-DHAVE_CONFIG_H"}),
    });
    return lib;
}

const libelf_sources = [_][]const u8{
    "elf32_checksum.c",       "elf32_fsize.c",          "elf32_getchdr.c",      "elf32_getehdr.c",
    "elf32_getphdr.c",        "elf32_getshdr.c",        "elf32_newehdr.c",      "elf32_newphdr.c",
    "elf32_offscn.c",         "elf32_updatefile.c",     "elf32_updatenull.c",   "elf32_xlatetof.c",
    "elf32_xlatetom.c",       "elf64_checksum.c",       "elf64_fsize.c",        "elf64_getchdr.c",
    "elf64_getehdr.c",        "elf64_getphdr.c",        "elf64_getshdr.c",      "elf64_newehdr.c",
    "elf64_newphdr.c",        "elf64_offscn.c",         "elf64_updatefile.c",   "elf64_updatenull.c",
    "elf64_xlatetof.c",       "elf64_xlatetom.c",       "elf_begin.c",          "elf_clone.c",
    "elf_cntl.c",             "elf_compress.c",         "elf_compress_gnu.c",   "elf_end.c",
    "elf_error.c",            "elf_fill.c",             "elf_flagdata.c",       "elf_flagehdr.c",
    "elf_flagelf.c",          "elf_flagphdr.c",         "elf_flagscn.c",        "elf_flagshdr.c",
    "elf_getarhdr.c",         "elf_getaroff.c",         "elf_getarsym.c",       "elf_getbase.c",
    "elf_getdata.c",          "elf_getdata_rawchunk.c", "elf_getident.c",       "elf_getphdrnum.c",
    "elf_getscn.c",           "elf_getshdrnum.c",       "elf_getshdrstrndx.c",  "elf_gnu_hash.c",
    "elf_hash.c",             "elf_kind.c",             "elf_memory.c",         "elf_ndxscn.c",
    "elf_newdata.c",          "elf_newscn.c",           "elf_next.c",           "elf_nextscn.c",
    "elf_rand.c",             "elf_rawdata.c",          "elf_rawfile.c",        "elf_readall.c",
    "elf_scnshndx.c",         "elf_strptr.c",           "elf_update.c",         "elf_version.c",
    "gelf_checksum.c",        "gelf_fsize.c",           "gelf_getauxv.c",       "gelf_getchdr.c",
    "gelf_getclass.c",        "gelf_getdyn.c",          "gelf_getehdr.c",       "gelf_getlib.c",
    "gelf_getmove.c",         "gelf_getnote.c",         "gelf_getphdr.c",       "gelf_getrela.c",
    "gelf_getrel.c",          "gelf_getshdr.c",         "gelf_getsym.c",        "gelf_getsyminfo.c",
    "gelf_getsymshndx.c",     "gelf_getverdaux.c",      "gelf_getverdef.c",     "gelf_getvernaux.c",
    "gelf_getverneed.c",      "gelf_getversym.c",       "gelf_newehdr.c",       "gelf_newphdr.c",
    "gelf_offscn.c",          "gelf_update_auxv.c",     "gelf_update_dyn.c",    "gelf_update_ehdr.c",
    "gelf_update_lib.c",      "gelf_update_move.c",     "gelf_update_phdr.c",   "gelf_update_rela.c",
    "gelf_update_rel.c",      "gelf_update_shdr.c",     "gelf_update_sym.c",    "gelf_update_syminfo.c",
    "gelf_update_symshndx.c", "gelf_update_verdaux.c",  "gelf_update_verdef.c", "gelf_update_vernaux.c",
    "gelf_update_verneed.c",  "gelf_update_versym.c",   "gelf_xlate.c",         "gelf_xlatetof.c",
    "gelf_xlatetom.c",        "libelf_crc32.c",         "libelf_next_prime.c",  "nlist.c",
};

// ---------------------------------------------------------------------- libbpf

const Bpf = struct {
    lib: *std.Build.Step.Compile,
    public_headers: std.Build.LazyPath,
    uapi: std.Build.LazyPath,
};

fn addLibbpf(b: *std.Build, options: Options, zlib_root: std.Build.LazyPath) Bpf {
    const dep = b.dependency("libbpf", .{});
    const lib = newLib(b, "bpf", options);
    const m = lib.root_module;

    m.addIncludePath(dep.path("src"));
    m.addIncludePath(dep.path("include"));
    m.addIncludePath(dep.path("include/uapi"));
    m.addIncludePath(b.path(libelf_dir ++ "/libelf"));
    m.addIncludePath(zlib_root);
    m.addCSourceFiles(.{
        .root = dep.path("src"),
        .files = &libbpf_sources,
        // libbpf's include/linux/kernel.h defines offsetof as &((T *)0)->member, which Zig's
        // Debug undefined-behavior checks report as a null dereference. It is harmless there.
        .flags = &(c_flags ++ .{"-fno-sanitize=undefined"}),
    });

    // libbpf keeps its headers flat in src/, but our code includes them as <bpf/...>.
    const wf = b.addWriteFiles();
    for (libbpf_public_headers) |h| {
        _ = wf.addCopyFile(dep.path(b.fmt("src/{s}", .{h})), b.fmt("bpf/{s}", .{h}));
    }

    return .{ .lib = lib, .public_headers = wf.getDirectory(), .uapi = dep.path("include/uapi") };
}

const libbpf_public_headers = [_][]const u8{
    "bpf.h",           "libbpf.h",         "btf.h",           "libbpf_common.h",
    "libbpf_legacy.h", "libbpf_version.h", "bpf_helpers.h",   "bpf_helper_defs.h",
    "bpf_tracing.h",   "bpf_endian.h",     "bpf_core_read.h", "skel_internal.h",
    "usdt.bpf.h",
};

const libbpf_sources = [_][]const u8{
    "bpf.c",       "btf.c",       "libbpf.c",        "libbpf_errno.c",   "netlink.c",
    "nlattr.c",    "str_error.c", "libbpf_probes.c", "bpf_prog_linfo.c", "btf_dump.c",
    "hashmap.c",   "ringbuf.c",   "strset.c",        "linker.c",         "gen_loader.c",
    "relo_core.c", "usdt.c",      "btf_iter.c",      "btf_relocate.c",   "features.c",
    "elf.c",       "zip.c",
};
