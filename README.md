<p align="center">
  <img src="app/ui/public/nusku.png" alt="Nusku" width="140">
</p>

<h1 align="center">Nusku</h1>

<p align="center">
  <b>See where your program's time actually goes.</b><br>
  A profiler for Linux, built on eBPF and written in Zig. CPU today; off-CPU, memory,<br>
  disk, network, locks and the scheduler next.<br>
  Point it at any process: no rebuild, no code changes, no frame pointers needed.
</p>

<p align="center">
  <img alt="Linux x86_64" src="https://img.shields.io/badge/Linux-x86__64-f5a623">
  <img alt="Zig 0.16" src="https://img.shields.io/badge/Zig-0.16-f7a41d">
  <img alt="eBPF" src="https://img.shields.io/badge/eBPF-powered-2b5797">
  <img alt="License: Apache 2.0" src="https://img.shields.io/badge/license-Apache%202.0-blue">
</p>

---

Your program is slow. You run `top` and see it's at 100% CPU. That tells you nothing about
**why**.

Nusku shows you why. It watches your program while it runs and tells you, function by
function, where the CPU time goes. You get the real names, down to the file and line, through
your code, the libraries it uses and the kernel.


## License

[Apache 2.0](LICENSE).

---

<sub>Why I built this: this is me practicing Zig and systems programming, for real. I'm challenging myself to see how far I can take this. No AI generated slop, no shortcuts, just me, textbooks, and the Linux kernel docs, Back to old days :)</sub>
