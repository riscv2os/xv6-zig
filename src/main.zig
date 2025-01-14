const std = @import("std");
const bio = @import("bio.zig");
const console = @import("console.zig");
const ide = @import("ide.zig");
const ioapic = @import("ioapic.zig");
const kalloc = @import("kalloc.zig");
const lapic = @import("lapic.zig");
const memlayout = @import("memlayout.zig");
const mmu = @import("mmu.zig");
const mp = @import("mp.zig");
const picirq = @import("picirq.zig");
const spinlock = @import("spinlock.zig");
const trap = @import("trap.zig");
const uart = @import("uart.zig");
const vm = @import("vm.zig");

extern const end: u8;

export fn main() noreturn {
    const end_addr = @intFromPtr(&end);
    kalloc.kinit1(end_addr, memlayout.p2v(4 * 1024 * 1024));

    vm.kvmalloc() orelse asm volatile ("1: jmp 1b");
    mp.mpinit();
    lapic.lapicinit();
    vm.seginit();
    picirq.picinit();
    ioapic.ioapicinit();
    console.consoleinit();
    uart.uartinit();
    trap.tvinit();
    bio.binit();
    // ide.ideinit();
    trap.idtinit();
    // TODO: startothers()
    kalloc.kinit2(memlayout.p2v(4 * 1024 * 1024), memlayout.p2v(memlayout.PHYSTOP));

    console.initialize();

    locktest();

    asm volatile ("sti");
    while (true) {}
}

// The boot page table used in entry.S and entryother.S.
// Page directories (and page tables) must start on page boundaries,
// hence the __aligned__ attribute.
// PTE_PS in a page directory entry enables 4Mbyte pages.
export var entrypgdir: [mmu.NPDENTRIES]u32 align(mmu.PGSIZE) = init: {
    var dir: [mmu.NPDENTRIES]u32 = undefined;
    // Map VA's [0, 4MB) to PA's [0, 4MB)
    dir[0] = (0) | mmu.PTE_P | mmu.PTE_W | mmu.PTE_PS;
    // Map VA's [KERNBASE, KERNBASE+4MB) to PA's [0, 4MB)
    dir[memlayout.KERNBASE >> mmu.PDXSHIFT] = (0) | mmu.PTE_P | mmu.PTE_W | mmu.PTE_PS;
    break :init dir;
};

fn locktest() void {
    var l = spinlock.spinlock.init("hoge");

    l.acquire();
    l.release();
    l.acquire();
    l.release();
    l.acquire();
    l.release();
}
