"""
极简 Mach-O 解析 / 改写：给可执行文件追加 LC_LOAD_DYLIB。

设计原则（安全第一）：
  - 只在「头部空隙」（load commands 结束到第一个被占用文件偏移之间）里追加命令，
    不移动任何内容、不改变任何 offset，因此 fat binary 也能安全处理；
  - 空隙不足时直接报错，绝不破坏原文件；
  - 幂等：同一个 dylib 路径已存在时不重复写入。
"""
from __future__ import annotations

import os
import struct
from dataclasses import dataclass, field

MH_MAGIC = 0xFEEDFACE
MH_CIGAM = 0xCEFAEDFE
MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE

MH_EXECUTE = 0x2

FAT_MAGIC = b"\xca\xfe\xba\xbe"
FAT_MAGIC_64 = b"\xca\xfe\xba\xbf"

LC_SEGMENT = 0x01
LC_SYMTAB = 0x02
LC_DYSYMTAB = 0x0B
LC_LOAD_DYLIB = 0x0C
LC_ID_DYLIB = 0x0D
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D
LC_SEGMENT_SPLIT_INFO = 0x1E
LC_REEXPORT_DYLIB = 0x8000001F
LC_LAZY_LOAD_DYLIB = 0x80000020
LC_ENCRYPTION_INFO = 0x21
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x80000022
LC_LOAD_UPWARD_DYLIB = 0x80000023
LC_FUNCTION_STARTS = 0x26
LC_MAIN = 0x80000028
LC_DATA_IN_CODE = 0x29
LC_DYLIB_CODE_SIGN_DRS = 0x2B
LC_ENCRYPTION_INFO_64 = 0x2C
LC_LINKER_OPTIMIZATION_HINT = 0x2E
LC_TWOLEVEL_HINTS = 0x16
LC_NOTE = 0x31
LC_DYLD_EXPORTS_TRIE = 0x80000033
LC_DYLD_CHAINED_FIXUPS = 0x80000034
LC_FILESET_ENTRY = 0x80000035

# 所有「依赖某个 dylib」的 load command
DYLIB_CMDS = (
    LC_LOAD_DYLIB,
    LC_LOAD_WEAK_DYLIB,
    LC_REEXPORT_DYLIB,
    LC_LAZY_LOAD_DYLIB,
    LC_LOAD_UPWARD_DYLIB,
)


class MachOError(RuntimeError):
    pass


@dataclass
class Slice:
    """一个 Mach-O 切片（thin 文件只有一个，fat 文件每个架构一个）。"""

    offset: int  # 切片在文件中的绝对偏移
    size: int
    is64: bool
    endian: str
    arch: str
    filetype: int
    ncmds: int
    sizeofcmds: int
    header_size: int
    limit: int  # 绝对偏移：头部空隙的上界（不可越过）
    dylibs: list[str] = field(default_factory=list)

    @property
    def cmds_end(self) -> int:
        return self.offset + self.header_size + self.sizeofcmds


def _align(value: int, boundary: int) -> int:
    return (value + boundary - 1) // boundary * boundary


_CPU_ARCH_ABI64 = 0x01000000
_CPU_TYPE_ARM = 12
_CPU_TYPE_X86 = 7
_CPU_TYPE_ARM64 = _CPU_ARCH_ABI64 | _CPU_TYPE_ARM
_CPU_TYPE_X86_64 = _CPU_ARCH_ABI64 | _CPU_TYPE_X86


def _arch_name(cputype: int, cpusubtype: int) -> str:
    sub = cpusubtype & 0x00FFFFFF
    if cputype == _CPU_TYPE_ARM64:
        return "arm64e" if sub == 2 else "arm64"
    if cputype == _CPU_TYPE_X86_64:
        return "x86_64"
    return {12: "armv7", 11: "armv7s", 7: "i386"}.get(cputype, f"cpu=0x{cputype:08x}")


def _read_cstr(data: bytes, start: int, end: int) -> str:
    stop = data.find(b"\x00", start, end)
    if stop < 0:
        stop = end
    return data[start:stop].decode("utf-8", "replace")


def _iter_commands(data: bytes, sl_offset: int, header_size: int, ncmds: int, endian: str, is64: bool):
    """遍历 load command，yield (cmd_offset, cmd, cmdsize)。"""
    pos = sl_offset + header_size
    for _ in range(ncmds):
        if pos + 8 > len(data):
            raise MachOError("Mach-O 头部被截断，无法解析 load command")
        cmd, cmdsize = struct.unpack_from(endian + "II", data, pos)
        if cmdsize < 8 or pos + cmdsize > len(data):
            raise MachOError(f"load command 长度异常（cmd=0x{cmd:x}, cmdsize={cmdsize}）")
        yield pos, cmd, cmdsize
        pos += cmdsize


def _occupied_offsets(data: bytes, cmd: int, pos: int, cmdsize: int, endian: str) -> list[int]:
    """
    提取该 load command 里指向切片内部其它区域的偏移量（相对切片起始），
    用来划定「头部空隙」的上界。pos 为命令在文件中的绝对偏移。
    """
    out: list[int] = []

    def u32(rel: int) -> int:
        return struct.unpack_from(endian + "I", data, pos + rel)[0]

    def u64(rel: int) -> int:
        return struct.unpack_from(endian + "Q", data, pos + rel)[0]

    try:
        if cmd == LC_SEGMENT_64 and cmdsize >= 72:
            # cmd(0) cmdsize(4) segname[16] vmaddr(24) vmsize(32) fileoff(40) ...
            fileoff = u64(40)
            nsects = u32(64)
            if fileoff:
                out.append(fileoff)
            sec = pos + 72
            for _ in range(min(nsects, 512)):
                out.append(struct.unpack_from(endian + "I", data, sec + 48)[0])  # section_64.offset
                sec += 80
        elif cmd == LC_SEGMENT and cmdsize >= 56:
            fileoff = u32(32)
            nsects = u32(48)
            if fileoff:
                out.append(fileoff)
            sec = pos + 56
            for _ in range(min(nsects, 512)):
                out.append(struct.unpack_from(endian + "I", data, sec + 40)[0])  # section.offset
                sec += 68
        elif cmd == LC_SYMTAB:
            out += [u32(8), u32(16)]  # symoff / stroff
        elif cmd == LC_DYSYMTAB:
            out += [u32(r) for r in (32, 40, 48, 56, 64, 72)]
        elif cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
            out += [u32(r) for r in (8, 16, 24, 32, 40)]
        elif cmd in (LC_ENCRYPTION_INFO, LC_ENCRYPTION_INFO_64):
            out.append(u32(8))  # cryptoff
        elif cmd in (
            LC_CODE_SIGNATURE, LC_SEGMENT_SPLIT_INFO, LC_FUNCTION_STARTS, LC_DATA_IN_CODE,
            LC_DYLIB_CODE_SIGN_DRS, LC_LINKER_OPTIMIZATION_HINT, LC_DYLD_EXPORTS_TRIE,
            LC_DYLD_CHAINED_FIXUPS, LC_TWOLEVEL_HINTS,
        ):
            out.append(u32(8))  # dataoff
        elif cmd == LC_NOTE and cmdsize >= 40:
            out.append(u64(24))
        elif cmd == LC_FILESET_ENTRY and cmdsize >= 32:
            out.append(u64(16))
    except struct.error:
        pass
    return [v for v in out if v]


def _parse_slice(data: bytes, offset: int, size: int) -> Slice:
    if offset + 4 > len(data):
        raise MachOError("文件被截断")

    magic = struct.unpack_from("<I", data, offset)[0]
    endian = "<"
    if magic in (MH_CIGAM, MH_CIGAM_64):
        endian = ">"
        magic = struct.unpack_from(">I", data, offset)[0]
    if magic not in (MH_MAGIC, MH_MAGIC_64):
        raise MachOError(f"不是 Mach-O 文件（magic=0x{magic:08x}）")

    is64 = magic == MH_MAGIC_64
    header_size = 32 if is64 else 28
    if offset + header_size > len(data):
        raise MachOError("Mach-O 头部被截断")

    _, cputype, cpusubtype, filetype, ncmds, sizeofcmds, _flags = struct.unpack_from(
        endian + "IIIIIII", data, offset
    )
    if offset + header_size + sizeofcmds > len(data):
        raise MachOError("Mach-O 的 sizeofcmds 超出文件范围")

    slice_end = min(len(data), offset + (size or (len(data) - offset)))
    candidates: list[int] = []  # load command 内记录的偏移都相对切片起始，这里统一换算成绝对偏移
    dylibs: list[str] = []
    for pos, cmd, cmdsize in _iter_commands(data, offset, header_size, ncmds, endian, is64):
        if cmd in DYLIB_CMDS and cmdsize >= 24:
            name_off = struct.unpack_from(endian + "I", data, pos + 8)[0]
            start = pos + name_off
            if 0 < name_off < cmdsize:
                dylibs.append(_read_cstr(data, start, pos + cmdsize))
        elif cmd in (LC_ID_DYLIB,):
            name_off = struct.unpack_from(endian + "I", data, pos + 8)[0]
            if 0 < name_off < cmdsize:
                dylibs.append(_read_cstr(data, pos + name_off, pos + cmdsize))
        candidates += [offset + v for v in _occupied_offsets(data, cmd, pos, cmdsize, endian)]

    # 可写上界：所有非零文件偏移里的最小值（通常是第一个 section 的 offset）
    positive = [c for c in candidates if c > 0]
    limit = min(positive) if positive else slice_end

    return Slice(
        offset=offset,
        size=size or (len(data) - offset),
        is64=is64,
        endian=endian,
        arch=_arch_name(cputype, cpusubtype),
        filetype=filetype,
        ncmds=ncmds,
        sizeofcmds=sizeofcmds,
        header_size=header_size,
        limit=max(0, min(limit, slice_end)),
        dylibs=dylibs,
    )


def slices_of(data: bytes) -> list[Slice]:
    """解析文件中的所有 Mach-O 切片（fat / thin 通用）。"""
    if len(data) < 8:
        raise MachOError("文件太小，不是 Mach-O")

    head = data[:4]
    if head in (FAT_MAGIC, FAT_MAGIC_64):
        is64_fat = head == FAT_MAGIC_64
        nfat = struct.unpack_from(">I", data, 4)[0]
        if not 0 < nfat <= 64:
            raise MachOError(f"fat header 里的架构数量异常: {nfat}")
        out: list[Slice] = []
        entry = 32 if is64_fat else 20
        fmt = ">IIQQII" if is64_fat else ">IIIII"
        for i in range(nfat):
            pos = 8 + i * entry
            if pos + entry > len(data):
                raise MachOError("fat header 被截断")
            values = struct.unpack_from(fmt, data, pos)
            if is64_fat:
                _, _, offset, size, _, _ = values
            else:
                _, _, offset, size, _ = values
            out.append(_parse_slice(data, offset, size))
        return out

    return [_parse_slice(data, 0, len(data))]


def _dylib_command_bytes(path: str, is64: bool, endian: str) -> bytes:
    raw = path.encode("utf-8") + b"\x00"
    cmdsize = _align(24 + len(raw), 8 if is64 else 4)
    cmd = struct.pack(
        endian + "IIIIII",
        LC_LOAD_DYLIB,
        cmdsize,
        24,  # name.offset
        0,  # timestamp
        0x10000,  # current_version 1.0.0
        0x10000,  # compatibility_version 1.0.0
    )
    return cmd + raw.ljust(cmdsize - 24, b"\x00")


def read_dylibs(path: str) -> list[str]:
    """读取可执行文件里记录的所有 dylib 依赖路径。"""
    with open(path, "rb") as f:
        data = f.read()
    out: list[str] = []
    for sl in slices_of(data):
        for d in sl.dylibs:
            if d not in out:
                out.append(d)
    return out


def add_dylib(path: str, dylib_path: str, dry_run: bool = False) -> tuple[bool, list[str]]:
    """
    给可执行文件追加一条 LC_LOAD_DYLIB。

    返回 (是否发生写入, 日志行列表)。路径已存在时不重复添加。
    """
    with open(path, "rb") as f:
        data = bytearray(f.read())

    slices = slices_of(bytes(data))
    if not any(sl.filetype == MH_EXECUTE for sl in slices):
        raise MachOError(f"{os.path.basename(path)} 不是可执行文件（MH_EXECUTE），无法注入")

    logs: list[str] = []
    # (slice_index, 写入偏移, 命令字节, 新 ncmds, 新 sizeofcmds)
    patches: list[tuple[int, int, bytes, int, int]] = []

    for index, sl in enumerate(slices):
        if any(d == dylib_path for d in sl.dylibs):
            logs.append(f"{os.path.basename(path)} [{sl.arch}]: 已有 {dylib_path}，"
                        "加载命令不重复添加（同一个库加载两次会出问题）")
            continue

        cmd_bytes = _dylib_command_bytes(dylib_path, sl.is64, sl.endian)
        cmds_end = sl.cmds_end
        available = sl.limit - cmds_end
        if len(cmd_bytes) > available:
            raise MachOError(
                f"{os.path.basename(path)} [{sl.arch}] 头部空隙不足（需要 {len(cmd_bytes)} 字节，"
                f"只有 {max(0, available)} 字节），无法安全注入。"
                "可用 `optool`/`insert_dylib` 等工具处理，或改用可重编译的工程。"
            )
        patches.append((index, cmds_end, cmd_bytes, sl.ncmds + 1, sl.sizeofcmds + len(cmd_bytes)))
        logs.append(
            f"{os.path.basename(path)} [{sl.arch}]: 添加 LC_LOAD_DYLIB -> {dylib_path}"
            f"（使用 {len(cmd_bytes)}/{available} 字节头部空隙）"
        )

    if not patches:
        return False, logs
    if dry_run:
        return True, logs

    for index, cmds_off, cmd_bytes, new_ncmds, new_sizeofcmds in patches:
        sl = slices[index]
        data[cmds_off:cmds_off + len(cmd_bytes)] = cmd_bytes
        struct.pack_into(sl.endian + "I", data, sl.offset + 16, new_ncmds)  # ncmds
        struct.pack_into(sl.endian + "I", data, sl.offset + 20, new_sizeofcmds)  # sizeofcmds

    with open(path, "wb") as f:
        f.write(bytes(data))
    return True, logs
