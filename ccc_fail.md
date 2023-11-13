

```
$ zig build run
run /bin/sh: error: unable to spawn /bin/sh: FileNotFound
Build Summary: 4/9 steps succeeded; 1 failed (disable with --summary none)
run transitive failure
+- run qemu-system-i386 transitive failure
   +- install transitive failure
      +- iso transitive failure
         +- run /bin/sh failure
error: the following build command failed with exit code 1:
D:\ccc\test\xv6-zig\zig-cache\o\519bd1e86cec13f0a1f37a02ed8c4bae\build.exe D:\install\zig-windows-x86_64\zig.exe D:\ccc\test\xv6-zig D:\ccc\test\xv6-zig\zig-cache C:\Users\user\AppData\Local\zig --seed 0xb739282a run
```
