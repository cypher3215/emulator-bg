# Part of the Nimrod Gameboy emulator.
# Copyright (C) Dominik Picheta.
import mem, gpu
import strutils, os
type
  # m (machine cycles), t (time cycles).
  # Ref: http://www.zilog.com/docs/z80/um0080.pdf
  TClock = tuple[m, t: int]

  PRegister = ref object
    pc, sp: int32 # 16-bit
    a, b, c, d, e, H, L, f: int32 # 8-bit
    clock: TClock

  PCPU = ref object
    clock: TClock
    r: PRegister
    mem: PMem
    trace: seq[tuple[a: int32, opc: int32, r: string]]
    stopAfter: int

  TFlagState = enum
    FUnchanged, FSet, FUnset

const
  BitZ = 1 shl 7
  BitN = 1 shl 6
  BitH = 1 shl 5
  BitC = 1 shl 4

## Flags
## -----
## 0x80 (1 shl 7) - (Zero|Z) Last result was zero.
## 0x40 (1 shl 6) - (Operation|N) Set if last operation was a subtraction
## 0x20 (1 shl 5) - (Half carry|H)
## 0x10 (1 shl 4) - (Carry|C)
## 0x08 (1 shl 3) - (Sign flag|S)               NOT USED IN GB's Z80
## 0x04 (1 shl 2) - (Parity/Overflow Flag|P/V)  NOT USED IN GB's Z80

proc newCPU(mem: PMem): PCPU =
  new(result)
  new(result.r)
  result.mem = mem
  result.trace = @[]
  result.stopAfter = -1

proc `$`(r: PRegister): string =
  result = ""
  result.add("pc: 0x$# sp: 0x$# a: 0x$# b: 0x$# c: 0x$# d: 0x$# e: 0x$# H: 0x$#, L: 0x$# f: 0x$#" % 
             [r.pc.toHex(4), r.sp.toHex(4), r.a.toHex(4), r.b.toHex(2),
              r.c.toHex(2), r.d.toHex(2), r.e.toHex(2), r.H.toHex(2),
              r.L.toHex(2), r.f.toHex(2)])

proc doTrace(cpu: PCPU) {.deprecated.} =
  #if cpu.trace.len > 10000:
  #  for i in 0..5000:
  #    cpu.trace.delete(0)
  if cpu.stopAfter == 0:
    cpu.stopAfter = -1
    #echo("Stop now!")
    #sleep(500)
  if cpu.mem.fiveInstr:
    if cpu.stopAfter < 0:
      cpu.trace.add((cpu.r.pc, cpu.mem.readByte(cpu.r.pc), "line is 144."))
      cpu.stopAfter = 10
      cpu.mem.fiveInstr = false
  #cpu.trace.add((cpu.r.pc, cpu.mem.readByte(cpu.r.pc), $cpu.r))
  if cpu.stopAfter > 0: cpu.stopAfter.dec

template changeFlag(f: var int32, state: TFlagState, bit: int32)  =
  case state
  of FSet:
    f = f or bit
  of FUnset:
    f = f and (not bit)
  else: assert false

template changeFlags(cpu: PCPU, Z = FUnchanged, N = FUnchanged,
                     H = FUnchanged, C = FUnchanged) =
  if Z != FUnchanged: changeFlag(cpu.r.f, Z, BitZ)
  if N != FUnchanged: changeFlag(cpu.r.f, N, BitN)
  if H != FUnchanged: changeFlag(cpu.r.f, H, BitH)
  if C != FUnchanged: changeFlag(cpu.r.f, C, BitC)

template isFSet(cpu: PCPU, bit: int32): bool = (cpu.r.f and bit) != 0

proc `>>`(b: bool): TFlagState =
  if b: return FSet
  else: return FUnset

proc checkOverflow(cpu: PCPU) =
  assert cpu.r.pc <= high(uint16).int32
  assert cpu.r.sp <= high(uint16).int32
  assert cpu.r.a <= high(uint8).int32
  assert cpu.r.b <= high(uint8).int32
  assert cpu.r.c <= high(uint8).int32
  assert cpu.r.d <= high(uint8).int32
  assert cpu.r.e <= high(uint8).int32
  assert cpu.r.H <= high(uint8).int32
  assert cpu.r.L <= high(uint8).int32
  assert cpu.r.f <= high(uint8).int32

template LDrn(cpu: PCPU, register: expr) {.immediate.} =
  cpu.r.register = cpu.mem.readByte(cpu.r.pc)
  inc(cpu.r.pc)
  cpu.r.clock.m = 2

template PUSHqq(cpu: PCPU, r1, r2: expr) {.immediate.} =
  cpu.r.sp.dec
  cpu.mem.writeByte(cpu.r.sp, cpu.r.r1)
  cpu.r.sp.dec
  cpu.mem.writeByte(cpu.r.sp, cpu.r.r2)
  cpu.r.clock.m = 3

template POPqq(cpu: PCPU, r1, r2: expr) {.immediate.} =
  ## r1 = High, r2 = Low
  cpu.r.r2 = cpu.mem.readByte(cpu.r.sp)
  cpu.r.sp.inc
  cpu.r.r1 = cpu.mem.readByte(cpu.r.sp)
  cpu.r.sp.inc
  cpu.r.clock.m = 3

template RLr(cpu: PCPU, register: expr) {.immediate.} =
  let bit7 = (cpu.r.register shr 7) and 1
  let prevCarry = cpu.isFSet(BitC)
  cpu.r.register = (cpu.r.register shl 1) or (if prevCarry: 1 else: 0)
  cpu.r.register = cpu.r.register and 0xFF # Mask to 8-bits
  #if prevCarry: cpu.r.register = cpu.r.register or 1 # Set Bit 0
  #else: cpu.r.register = cpu.r.register and (not 1) # Unset bit 0
  cpu.changeFlags(Z = >>(cpu.r.register == 0), H = FUnset, N = FUnset,
                  C = >>(bit7 == 1))
  cpu.r.clock.m = 2

template INCrr(cpu: PCPU, r1, r2: expr, flags = false) {.immediate.} =
  let x = ((cpu.r.r1 shl 8) or cpu.r.r2) + 1
  let (hi, low) = (x shr 8 and 0xFF, x and 0xFF)
  cpu.r.r2 = low; cpu.r.r1 = hi
  if flags:
    cpu.changeFlags(Z = >>(x == 0), H = >>((x and 0xF) == 0), N = FUnset)
    cpu.r.clock.m = 3

template INCr(cpu: PCPU, register: expr) {.immediate.} =
  cpu.r.register = (cpu.r.register + 1) and 0xFF
  cpu.r.clock.m = 1
  cpu.changeFlags(Z = >>(cpu.r.register == 0),
                  H = >>((cpu.r.register and 0xF) == 0),
                  N = FUnset)

template DECr(cpu: PCPU, register: expr) {.immediate.} =
  cpu.r.register = (cpu.r.register - 1) and 0xFF
  cpu.changeFlags(Z = >>(cpu.r.register == 0),
                  H = >>((cpu.r.register and 0xF) == 0xF),
                  N = FSet)
  
  cpu.r.clock.m = 1

proc LDSimple(cpu: PCPU, opcode: int32) =
  ## All (simple) variants of the LD opcodes end up here.
  ## Essentially what we want is a register to be copied to another register.
  # TODO: Use macros to shorten code?
  case opcode
  of 0x40 .. 0x45:
    # LD B, B .. LD B, L
    # Copy register (r) into register B.
    case opcode
    of 0x40:
      # LD B, B
      cpu.r.b = cpu.r.b
    of 0x41:
      # LD B, C
      cpu.r.b = cpu.r.c
    of 0x42:
      # LD B, D
      cpu.r.b = cpu.r.d
    of 0x43:
      # LD B, E
      cpu.r.b = cpu.r.e
    of 0x44:
      # LD B, H
      cpu.r.b = cpu.r.H
    of 0x45:
      # LD B, L
      cpu.r.b = cpu.r.L
    else:
      assert false
  of 0x50 .. 0x55:
    # LD D, B .. LD D, L
    case opcode
    of 0x50:
      # LD D, B
      cpu.r.d = cpu.r.b
    of 0x51:
      # LD D, C
      cpu.r.d = cpu.r.c
    of 0x52:
      # LD D, D
      cpu.r.d = cpu.r.d
    of 0x53:
      # LD D, E
      cpu.r.d = cpu.r.e
    of 0x54:
      # LD D, H
      cpu.r.d = cpu.r.H
    of 0x55:
      # LD D, L
      cpu.r.d = cpu.r.L
    else:
      assert false
  of 0x60 .. 0x65:
    # LD H, B .. LD H, L
    case opcode
    of 0x60:
      # LD H, B
      cpu.r.h = cpu.r.b
    of 0x61:
      # LD H, C
      cpu.r.h = cpu.r.c
    of 0x62:
      # LD H, D
      cpu.r.h = cpu.r.d
    of 0x63:
      # LD H, E
      cpu.r.h = cpu.r.e
    of 0x64:
      # LD H, H
      cpu.r.h = cpu.r.H
    of 0x65:
      # LD H, L
      cpu.r.h = cpu.r.L
    else:
      assert false
  of 0x47 .. 0x4D:
    case opcode
    of 0x47:
      cpu.r.b = cpu.r.a
    of 0x48:
      cpu.r.c = cpu.r.b
    of 0x49:
      cpu.r.c = cpu.r.c
    of 0x4A:
      cpu.r.c = cpu.r.d
    of 0x4B:
      cpu.r.c = cpu.r.e
    of 0x4C:
      cpu.r.c = cpu.r.H
    of 0x4D:
      cpu.r.c = cpu.r.L
    else: assert false
  of 0x57 .. 0x5D:
    case opcode
    of 0x57:
      cpu.r.d = cpu.r.a
    of 0x58:
      cpu.r.e = cpu.r.b
    of 0x59:
      cpu.r.e = cpu.r.c
    of 0x5A:
      cpu.r.e = cpu.r.d
    of 0x5B:
      cpu.r.e = cpu.r.e
    of 0x5C:
      cpu.r.e = cpu.r.H
    of 0x5D:
      cpu.r.e = cpu.r.L
    else: assert false
  of 0x67 .. 0x6D:
    case opcode
    of 0x67:
      cpu.r.H = cpu.r.a
    of 0x68:
      cpu.r.L = cpu.r.b
    of 0x69:
      cpu.r.L = cpu.r.c
    of 0x6A:
      cpu.r.L = cpu.r.d
    of 0x6B:
      cpu.r.L = cpu.r.e
    of 0x6C:
      cpu.r.L = cpu.r.H
    of 0x6D:
      cpu.r.L = cpu.r.L
    else: assert false
  of 0x78 .. 0x7D:
    case opcode
    of 0x78:
      cpu.r.a = cpu.r.b
    of 0x79:
      cpu.r.a = cpu.r.c
    of 0x7A:
      cpu.r.a = cpu.r.d
    of 0x7B:
      cpu.r.a = cpu.r.e
    of 0x7C:
      cpu.r.a = cpu.r.H
    of 0x7D:
      cpu.r.a = cpu.r.L
    else: assert false
  of 0x4F: cpu.r.c = cpu.r.a
  of 0x5F: cpu.r.e = cpu.r.a
  of 0x6F: cpu.r.L = cpu.r.a
  of 0x7F: cpu.r.a = cpu.r.a    
  else: assert false
  # TODO: Check times.
  cpu.r.clock.m = 1

proc exec(cpu: PCPU) =
  ## Executes the next instruction
  doTrace(cpu)
  let opcode = cpu.mem.readByte(cpu.r.pc)
  #echo("0x", toHex(opcode, 2), " | ", $cpu.r)
  cpu.r.pc.inc()
  case opcode
  of 0x06:
    # LD B, n
    # Load 8-bit immediate into B
    LDrn(cpu, b)
  of 0x0E:
    # LD C, n
    # Load 8-bit immediate into C.
    LDrn(cpu, c)
  of 0x16:
    # LD D, n
    LDrn(cpu, d)
  of 0x1E:
    # LD E, n
    LDrn(cpu, e)
  of 0x26:
    # LD H, n
    LDrn(cpu, H)
  of 0x2E:
    # LD L, n
    LDrn(cpu, L)
  of 0x3E:
    # LD A, n
    # Load 8-bit immediate into A.
    LDrn(cpu, a)

  of 0x04:
    # INC b
    INCr(cpu, b)
  of 0x14:
    # INC d
    INCr(cpu, d)
  of 0x24:
    # INC H
    INCr(cpu, h)
  of 0x0C:
    # INC c
    # Increment C
    INCr(cpu, c)
  of 0x03:
    # INC BC
    INCrr(cpu, b, c, true)
  of 0x13:
    # INC DE
    INCrr(cpu, d, e, true)
  of 0x23:
    # INC HL
    # Increment 16-bit HL
    INCrr(cpu, H, L, true)
  
  of 0x05:
    # DEC B
    # Decrement B
    DECr(cpu, b)
  of 0x0D:
    # DEC C
    DECr(cpu, c)
  of 0x15:
    # DEC D
    DECr(cpu, d)
  of 0x1D:
    # DEC E
    DECr(cpu, e)
  of 0x25:
    # DEC H
    DECr(cpu, H)
  of 0x2D:
    # DEC L
    DECr(cpu, L)
  of 0x3D:
    # DEC A
    DECr(cpu, a)

  of 0x11:
    # LD DE, nn
    # Load 16-bit immediate into DE
    cpu.r.e = cpu.mem.readByte(cpu.r.pc)
    cpu.r.d = cpu.mem.readByte(cpu.r.pc+1)
    cpu.r.pc.inc(2)
    cpu.r.clock.m = 3
  
  of 0x17:
    # RL A
    # Rotate A left.
    RLr(cpu, a)
  
  of 0x1A:
    # LD A, (DE)
    # Load A from address pointed to by DE
    cpu.r.a = cpu.mem.readByte((cpu.r.d shl 8) or cpu.r.e)
    cpu.r.clock.m = 2
    
  of 0x20, 0x28:
    # (0x20) JR NZ, n; Relative jump by signed immediate if last result was not zero
    # (0x28) JR Z, n; Same as above, but when last result *was* zero.
    var x = cpu.mem.readByte(cpu.r.pc)
    if x > 127: x = -(((not x) + 1) and 255)
    cpu.r.pc.inc
    cpu.r.clock.m = 2
    if (opcode == 0x20 and (not isFSet(cpu, BitZ))) or
       (opcode == 0x28 and isFSet(cpu, BitZ)):
      cpu.r.pc.inc(x); cpu.r.clock.m.inc 
  of 0x18:
    # JR n
    # Relative jump by signed immediate
    var x = cpu.mem.readByte(cpu.r.pc)
    if x > 127: x = -(((not x) + 1) and 255)
    cpu.r.pc.inc
    cpu.r.pc.inc(x)
    cpu.r.clock.m = 3
 
  of 0x21:
    # LD HL, nn
    # Load 16-bit immediate into (registers) H and L
    cpu.r.L = cpu.mem.readByte(cpu.r.pc)
    cpu.r.H = cpu.mem.readByte(cpu.r.pc+1)
    cpu.r.pc.inc(2)
    cpu.r.clock.m = 3
  of 0x22:
    # LDI (HL), A
    # Save A to address pointed by HL and increment HL.
    cpu.mem.writeByte((cpu.r.h shl 8) or cpu.r.l, cpu.r.a)
    INCrr(cpu, H, L)
    # TODO: Should flags be changed? (Z80 ref says they should.)
    # cpu.changeFlags(H = FUnset, N = FUnset)
    cpu.r.clock.m = 2
  
  of 0x31:
    # LD SP, nn
    # Load 16-bit immediate into (register) SP
    cpu.r.sp = cpu.mem.readWord(cpu.r.pc)
    cpu.r.pc.inc(2)
    cpu.r.clock.m = 3
  of 0x32:
    # LDD (HL), A
    # Save A to address pointed by HL, and decrement HL
    cpu.mem.writeByte((cpu.r.h shl 8) or cpu.r.l, cpu.r.a)
    let x = ((cpu.r.h shl 8) or cpu.r.l) - 1
    let (hi, low) = (x shr 8 and 0xFF, x and 0xFF)
    cpu.r.L = low; cpu.r.H = hi
    # TODO: Should flags be changed? (Z80 ref says they should.)
    cpu.r.clock.m = 2
  
    #of 0x4F:
    #  # LD C, A
    #  # Copy A into C.
    #  cpu.r.a = cpu.r.c
    #  cpu.r.clock.m = 1
    #of 0x7B:
    #  # LD A, E; Copy E into A
    #  cpu.r.a = cpu.r.e
    #  cpu.r.clock.m = 1
      
  of 0x77:
    # LD (HL), A
    # Copy A to address pointed by HL
    let HL = ((cpu.r.h shl 8) or cpu.r.L)
    cpu.mem.writeByte(HL, cpu.r.a)
    cpu.r.clock.m = 2
  
  of 0x90:
    # SUB A, B
    var sum = cpu.r.a - cpu.r.b
    cpu.changeFlags(Z = >>(sum == 0), H = >>((sum and 0xF) > (cpu.r.a and 0xF)),
                    C = >>(sum < 0), N = FSet)
    cpu.r.a = sum and 0xFF
    cpu.r.clock.m = 1
  
  of 0xAF:
    # XOR A
    # Logical XOR against (register) A
    cpu.r.a = (cpu.r.a xor cpu.r.a) and 255 # If result is bigger than 255, will be set to 0
    cpu.changeFlags(Z = >>(cpu.r.a == 0), H = FUnset, C = FUnset)
    cpu.r.clock.m = 1
  
  of 0xC1:
    # POP BC
    # Pop 16-bit value into BC
    POPqq(cpu, b, c)
  of 0xD1:
    # POP DE
    POPqq(cpu, d, e)
  of 0xE1:
    # POP HL
    POPqq(cpu, H, L)
  of 0xF1:
    # POP AF
    POPqq(cpu, a, f)
  of 0xC5:
    # PUSH BC
    # Push 16-bit BC onto stack.
    PUSHqq(cpu, b, c)
  of 0xD5:
    # PUSH DE
    PUSHqq(cpu, d, e)
  of 0xE5:
    # PUSH HL
    PUSHqq(cpu, H, L)
  of 0xF5:
    # PUSH AF
    PUSHqq(cpu, a, f)
  
  of 0xC9:
    # RET
    # Return to calling routine.
    cpu.r.pc = cpu.mem.readWord(cpu.r.sp)
    cpu.r.sp.inc(2)
    cpu.r.clock.m = 3
  
  of 0xCB:
    # Extended Ops
    let extop = cpu.mem.readByte(cpu.r.pc)
    cpu.r.pc.inc
    case extop
    of 0x11:
      # RL C
      # Rotate C left.
      RLr(cpu, c)
    of 0x7C:
      # BIT 7, H
      # Test whether bit 7 of H is zero
      cpu.changeFlags(Z = >>((cpu.r.h and (1 shl 7)) == 0), H = FSet, N = FUnset)
      cpu.r.clock.m = 2
    else:
      echo "Unknown extended op: 0x", extop.toHex(2)
      assert false
  
  of 0xCD:
    # CALL nn
    # Call routine at 16-bit location
    cpu.r.sp.dec(2)
    
    # We pushing pc+2 onto the stack because the next two bits are used. Below next line.
    cpu.mem.writeWord(cpu.r.sp, cpu.r.pc+2)
    cpu.r.pc = cpu.mem.readWord(cpu.r.pc)
    cpu.r.clock.m = 5
  of 0xE0:
    # LDH (0xFF00 + n), A
    # Save A at address pointed to by (0xFF00 + 8-bit immediate).
    cpu.mem.writeByte(0xFF00 + cpu.mem.readByte(cpu.r.pc), cpu.r.a)
    cpu.r.pc.inc
    cpu.r.clock.m = 3
  
  of 0xE2:
    # LDH (0xFF00 + C), A
    # Save A at address pointed to by 0xFF00+C
    cpu.mem.writeByte(0xFF00 + cpu.r.c, cpu.r.a)
    cpu.r.clock.m = 2
  
  of 0xF0:
    # LDH A, (0xFF00 + n)
    # Load A from address pointed to by (0xFF00 + 8-bit immediate)
    cpu.r.a = cpu.mem.readByte(0xFF00 + cpu.mem.readByte(cpu.r.pc))
    cpu.r.clock.m = 2
  
  of 0xFE:
    # CP n; compare 8-bit immediate against A.
    # TODO: This may be wrong. Review.
    
    var n = cpu.mem.readByte(cpu.r.pc)
    var sum = cpu.r.a - n
    let isNegative = sum < 0
    sum = sum and 0xFF
    
    cpu.r.pc.inc
    cpu.changeFlags(C = >>isNegative, Z = >>(sum == 0), N = FSet, 
                    H = >>((sum and 0xF) > (cpu.r.a and 0xF)))
    cpu.r.clock.m = 2
  
  of 0xEA:
    # LD (nn), A; Save A at given 16-bit address.
    cpu.mem.writeByte(cpu.mem.readWord(cpu.r.pc), cpu.r.a)
    cpu.r.pc.inc(2)
    cpu.r.clock.m = 4
  
  of 0x40 .. 0x45, 0x50 .. 0x55, 0x60 .. 0x65, 0x47 .. 0x4D, 0x57 .. 0x5D,
     0x67 .. 0x6D, 0x78 .. 0x7D, 0x4F, 0x5F, 0x6F, 0x7F:
    # Simple LD instructions. (Copy register1 to register2)
    LDSimple(cpu, opcode)
  
  of 0xF2:
    # Operation removed from GB's CPU. NOOP.
    cpu.r.clock.m = 1
  else:
    echo "Unknown opcode: 0x", opcode.toHex(2)
    assert false

proc next*(cpu: PCPU) =
  cpu.exec()
  checkOverflow(cpu)
  cpu.mem.gpu.next(cpu.r.clock.m)


when isMainModule:
  var cpu = newCpu(mem.load("/home/dom/code/nimrod/gbemulator/Pokemon_Red.gb"))
  
  proc CtrlCHook() {.noconv.} =
    echo("Ctrl+C")
    for i in countdown(min(100, cpu.trace.len), 1):
      let t = cpu.trace[cpu.trace.len-i]
      echo("  0x", t.opc.toHex(4), " @ 0x", t.a.toHex(4), "(", t.a, ") ", t.r, " ", cpu.trace.len-i)
    quit(1)
  #setControlCHook(CtrlCHook)
  while True:
    cpu.next()
















