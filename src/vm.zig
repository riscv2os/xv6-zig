const kalloc = @import("kalloc.zig");
const memlayout = @import("memlayout.zig");
const mmu = @import("mmu.zig");
const mp = @import("mp.zig");
const sh = @import("sh.zig");
const proc = @import("proc.zig");
const x86 = @import("x86.zig");

extern const data: u8; // defined by kernel.ld
pub var kpgdir: [*]mmu.pde_t = undefined;
var count: u32 = 0;

comptime {
    asm (
        \\.global set_segreg;
        \\.type set_segreg, @function;
        \\set_segreg:
        \\  movl $0x10, %eax
        \\  movw %ax, %es
        \\  movw %ax, %ss
        \\  movw %ax, %ds
        \\  movw %ax, %fs
        \\  movw %ax, %gs
        \\  movl $0x08, %eax
        \\  movl $.next, %ecx
        \\  pushw %ax
        \\  pushl %ecx
        \\  lret
        \\.next:
        \\  movl %ebp, %esp
        \\  popl %ebp
        \\  ret
    );
}

extern fn set_segreg() void;

pub fn seginit() void {
    var c = &mp.cpus[proc.cpuid()];
    if (proc.cpuid() == 1) {
        asm volatile ("1: jmp 1b");
    }
    c.*.gdt[mmu.SEG_KCODE] = mmu.segdesc.new(mmu.STA_X | mmu.STA_R, 0, 0xffffffff, mmu.DPL_KERNEL);
    c.*.gdt[mmu.SEG_KDATA] = mmu.segdesc.new(mmu.STA_W, 0, 0xffffffff, mmu.DPL_KERNEL);
    c.*.gdt[mmu.SEG_UCODE] = mmu.segdesc.new(mmu.STA_X | mmu.STA_R, 0, 0xffffffff, mmu.DPL_USER);
    c.*.gdt[mmu.SEG_UDATA] = mmu.segdesc.new(mmu.STA_W, 0, 0xffffffff, mmu.DPL_USER);
    x86.lgdt(@intFromPtr(&c.*.gdt), @sizeOf(@TypeOf(c.*.gdt)));

    set_segreg();
}

// Return the address of the PTE in page table pgdir
// that corresponds to virtual address va.  If alloc is true,
// create any required page table pages.
fn walkpgdir(pgdir: [*]mmu.pde_t, va: usize, alloc: bool) ?*mmu.pte_t {
    var pde = &pgdir[mmu.pdx(va)];
    var pgtab: [*]mmu.pte_t = undefined;
    if (pde.* & mmu.PTE_P != 0) {
        pgtab = @as([*]mmu.pte_t, @ptrFromInt(memlayout.p2v(mmu.pteAddr(pde.*))));
    } else {
        if (!alloc) {
            return null;
        }
        pgtab = @as([*]mmu.pte_t, @ptrFromInt(kalloc.kalloc() orelse return null));
        // Make sure all those PTE_P bits are zero.
        for (@as([*]u8, @ptrCast(pgtab))[0..mmu.PGSIZE]) |*b| {
            b.* = 0;
        }
        // The permissions here are overly generous, but they can
        // be further restricted by the permissions in the page table
        // entries, if necessary.
        pde.* = memlayout.v2p(@intFromPtr(pgtab)) | mmu.PTE_P | mmu.PTE_W | mmu.PTE_U;
    }
    return &pgtab[mmu.ptx(va)];
}

// Create PTEs for virtual addresses starting at va that refer to
// physical addresses starting at pa. va and size might not
// be page-aligned.
fn mappages(pgdir: [*]mmu.pde_t, va: usize, size: usize, pa: usize, perm: usize) bool {
    var virt_addr = mmu.pgrounddown(va);
    var phys_addr = pa;
    var last = mmu.pgrounddown(va +% size -% 1);
    while (true) {
        var pte = walkpgdir(pgdir, virt_addr, true) orelse return false;
        if (pte.* & mmu.PTE_P != 0) {
            sh.panic("remap");
        }
        pte.* = phys_addr | perm | mmu.PTE_P;
        if (virt_addr == last) {
            break;
        }
        virt_addr = virt_addr +% mmu.PGSIZE;
        phys_addr = phys_addr +% mmu.PGSIZE;
    }
    return true;
}

// Set up kernel part of a page table.
fn setupkvm() ?[*]mmu.pde_t {
    var pgdir = @as([*]mmu.pde_t, @ptrFromInt(kalloc.kalloc() orelse return null));
    for (@as([*]u8, @ptrCast(pgdir))[0..mmu.PGSIZE]) |*b| {
        b.* = 0;
    }
    if (memlayout.p2v(memlayout.PHYSTOP) > memlayout.DEVSPACE) {
        sh.panic("PHYSTOP too high");
    }

    const data_addr = @intFromPtr(&data);

    // This table defines the kernel's mappings, which are present in
    // every process's page table.
    const kmap_t = struct {
        virt: usize,
        phys_start: usize,
        phys_end: usize,
        perm: usize,
    };
    const kmap = [4]kmap_t{
        kmap_t{
            .virt = memlayout.KERNBASE,
            .phys_start = 0,
            .phys_end = memlayout.EXTMEM,
            .perm = mmu.PTE_W,
        },
        kmap_t{
            .virt = memlayout.KERNLINK,
            .phys_start = memlayout.v2p(memlayout.KERNLINK),
            .phys_end = memlayout.v2p(data_addr),
            .perm = 0,
        },
        kmap_t{
            .virt = data_addr,
            .phys_start = memlayout.v2p(data_addr),
            .phys_end = memlayout.PHYSTOP,
            .perm = mmu.PTE_W,
        },
        kmap_t{
            .virt = memlayout.DEVSPACE,
            .phys_start = memlayout.DEVSPACE,
            .phys_end = 0,
            .perm = mmu.PTE_W,
        },
    };

    for (&kmap) |*k| {
        const ok = mappages(pgdir, k.virt, k.phys_end -% k.phys_start, k.phys_start, k.perm);
        count += 1;
        if (ok == false) {
            // TODO: freevm(pgdir)
            return null;
        }
    }
    return pgdir;
}

// Allocate one page table for the machine for the kernel address
// space for scheduler processes.
pub fn kvmalloc() ?void {
    kpgdir = setupkvm() orelse return null;
    switchkvm();
}

fn switchkvm() void {
    x86.lcr3(memlayout.v2p(@intFromPtr(kpgdir)));
}
