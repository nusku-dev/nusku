pub const clibs = @cImport({
    @cInclude("errno.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/syscall.h");
    @cInclude("sys/ioctl.h");
});
