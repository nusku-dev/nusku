pub const clibs = @cImport({
    @cInclude("errno.h");
    @cInclude("unistd.h");
    @cInclude("bpf/bpf.h");
    @cInclude("bpf/libbpf.h");
    @cInclude("fcntl.h");
    @cInclude("sys/syscall.h");
    @cInclude("sys/ioctl.h");
});
