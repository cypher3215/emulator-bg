# Part of the Nimrod Gameboy emulator.
# Copyright (C) Dominik Picheta.

import os, strutils, unsigned
import gpu

type
  PMem* = ref object
    rom: string
    gameName*: string
    cartType*, romSize*, ramSize*: char
    bios: array[0 .. 255, int32]    # 255 Bytes
    extRAM: array[0 .. 8191, int32] # 8KB
    workRAM: array[0 .. 8191, int32] # 8KB
    zeroRAM: array[0 .. 127, int32]
    gpu*: PGPU
    
proc hexdump(s: string) =
  for c in s:
    stdout.write(c.ord.BiggestInt.toHex(2) & " ")
  echo("")

const
  NintendoGraphic =
    [
      '\xCE', '\xED', '\x66', '\x66', '\xCC', '\x0D', '\x00', '\x0B',
      '\x03', '\x73', '\x00', '\x83', '\x00', '\x0C', '\x00', '\x0D',
      '\x00', '\x08', '\x11', '\x1F', '\x88', '\x89', '\x00', '\x0E',
      '\xDC', '\xCC', '\x6E', '\xE6', '\xDD', '\xDD', '\xD9', '\x99',
      '\xBB', '\xBB', '\x67', '\x63', '\x6E', '\x0E', '\xEC', '\xCC',
      '\xDD', '\xDC', '\x99', '\x9F', '\xBB', '\xB9', '\x33', '\x3E'
    ]
  bios = [
    0x31'i32, 0xFE, 0xFF, 0xAF, 0x21, 0xFF, 0x9F, 0x32, 0xCB, 0x7C, 0x20, 0xFB, 0x21, 0x26, 0xFF, 0x0E,
    0x11, 0x3E, 0x80, 0x32, 0xE2, 0x0C, 0x3E, 0xF3, 0xE2, 0x32, 0x3E, 0x77, 0x77, 0x3E, 0xFC, 0xE0,
    0x47, 0x11, 0x04, 0x01, 0x21, 0x10, 0x80, 0x1A, 0xCD, 0x95, 0x00, 0xCD, 0x96, 0x00, 0x13, 0x7B,
    0xFE, 0x34, 0x20, 0xF3, 0x11, 0xD8, 0x00, 0x06, 0x08, 0x1A, 0x13, 0x22, 0x23, 0x05, 0x20, 0xF9,
    0x3E, 0x19, 0xEA, 0x10, 0x99, 0x21, 0x2F, 0x99, 0x0E, 0x0C, 0x3D, 0x28, 0x08, 0x32, 0x0D, 0x20,
    0xF9, 0x2E, 0x0F, 0x18, 0xF3, 0x67, 0x3E, 0x64, 0x57, 0xE0, 0x42, 0x3E, 0x91, 0xE0, 0x40, 0x04,
    0x1E, 0x02, 0x0E, 0x0C, 0xF0, 0x44, 0xFE, 0x90, 0x20, 0xFA, 0x0D, 0x20, 0xF7, 0x1D, 0x20, 0xF2,
    0x0E, 0x13, 0x24, 0x7C, 0x1E, 0x83, 0xFE, 0x62, 0x28, 0x06, 0x1E, 0xC1, 0xFE, 0x64, 0x20, 0x06,
    0x7B, 0xE2, 0x0C, 0x3E, 0x87, 0xF2, 0xF0, 0x42, 0x90, 0xE0, 0x42, 0x15, 0x20, 0xD2, 0x05, 0x20,
    0x4F, 0x16, 0x20, 0x18, 0xCB, 0x4F, 0x06, 0x04, 0xC5, 0xCB, 0x11, 0x17, 0xC1, 0xCB, 0x11, 0x17,
    0x05, 0x20, 0xF5, 0x22, 0x23, 0x22, 0x23, 0xC9, 0xCE, 0xED, 0x66, 0x66, 0xCC, 0x0D, 0x00, 0x0B,
    0x03, 0x73, 0x00, 0x83, 0x00, 0x0C, 0x00, 0x0D, 0x00, 0x08, 0x11, 0x1F, 0x88, 0x89, 0x00, 0x0E,
    0xDC, 0xCC, 0x6E, 0xE6, 0xDD, 0xDD, 0xD9, 0x99, 0xBB, 0xBB, 0x67, 0x63, 0x6E, 0x0E, 0xEC, 0xCC,
    0xDD, 0xDC, 0x99, 0x9F, 0xBB, 0xB9, 0x33, 0x3E, 0x3c, 0x42, 0xB9, 0xA5, 0xB9, 0xA5, 0x42, 0x4C,
    0x21, 0x04, 0x01, 0x11, 0xA8, 0x00, 0x1A, 0x13, 0xBE, 0x20, 0xFE, 0x23, 0x7D, 0xFE, 0x34, 0x20,
    0xF5, 0x06, 0x19, 0x78, 0x86, 0x23, 0x05, 0x20, 0xFB, 0x86, 0x20, 0xFE, 0x3E, 0x01, 0xE0, 0x50
  ]
  
proc verifyBytes[R](raw: var string, bytes: array[R, char], start: int): bool =
  result = true
  for i in 0 .. bytes.high:
    if raw[i+start] != bytes[i]:
      return false

proc getBytes(raw: var string, dest: var string, slice: TSlice[int]) =
  assert slice.a < slice.b
  assert slice.a > 0
  let len = slice.b - slice.a
  dest = newString(len)
  for i in 0 .. len:
    dest[i] = raw[slice.a + i]

proc load*(path: string): PMem =
  new result
  result.rom = readFile(path)
  
  # Verify Nintendo graphic
  # TODO: Proper exceptions.
  #doAssert result.rom.verifyBytes(NintendoGraphic, 0x0104)
  
  # Gather meta data.
  result.gameName = result.rom[0x0134 .. 0x0142]
  echo("Game is: " & result.gameName)

  doAssert result.rom[0x0143].ord != 0x80 # 0x80 here means the ROM is for Color GB.
  
  result.cartType = result.rom[0x0147]
  result.romSize  = result.rom[0x0148]
  result.ramSize  = result.rom[0x0149]
  result.bios = bios

  result.GPU = newGPU()

proc reset*(mem: PMem) =
  for i in 0..mem.extRam.len: mem.extRam[i] = 0
  for i in 0..mem.workRam.len: mem.workRam[i] = 0

proc readByte*(mem: PMem, address: int32): int32 =
  if (address in {0x104 .. 0x133}):
    echo("Bios is accessing the location of the nintendo logo: ", address.toHex(4))
  case (address and 0xF000)
  of 0x0000:
    # BIOS
    if address > mem.bios.high: return 0 # TODO: Correct?
    return mem.bios[address]
  of 0x1000, 0x2000, 0x3000:
    return mem.rom[address.int].ord
  of 0x4000, 0x5000, 0x6000, 0x7000:
    # ROM Bank 1
  of 0x8000, 0x9000:
    # VRAM
    return mem.GPU.vram[address and 0x1FFF]
  of 0xF000:
    case address and 0x0F00
    of 0x0F00:
      if address > 0xFF7F:
        return mem.zeroRAM[address and 0x007F]
      else:
        case address
        of 0xFF42:
          # ScrollY
          return mem.gpu.scrollY
        of 0xFF44:
          # LCDC Y-Coordinate
          #echo("0xFF44: (y-line is): ", mem.gpu.line)
          return mem.gpu.line.int32
        else:
          echo("Read ", address.toHex(4))
          assert false
    else:
      assert false
  else:
    echo("Read ", address.toHex(4))
    assert false

proc readWord*(mem: PMem, address: int32): int32 =
  return readByte(mem, address) or (readByte(mem, address+1) shl 8) 

proc writeByte*(mem: PMem, address: int32, b: int32) =
  case (address and 0xF000)
  of 0x8000, 0x9000:
    # VRAM
    # Each pixel is 2 bits. VRAM is the tileset.
    echo("VRAM. Address: 0x", toHex(address, 4), " Value: ", toHex(b, 4))
    mem.GPU.vram[address and 0x1FFF] = b
  
  of 0xF000:
    case address and 0x0F00
    of 0x0F00:
      if address > 0xFF7F:
        #echo("ZeroRam. Address: ", toHex(address, 4), " Value: ", toHex(b, 4))
        mem.zeroRAM[address and 0x007F] = b
        return 
    
      case address
      of 0xFF11:
        # TODO:
        echo("Sound Mode 1 register, Sound length (0xFF11): ", b.toHex(4))
      of 0xFF12:
        # TODO:
        echo("Sound Mode 1 register, Envelope (0xFF12): ", b.toHex(4))
      of 0xFF13:
        # TODO:
        echo("Sound Mode 1 register, Freq lo (0xFF13): ", b.toHex(4))
      of 0xFF24:
        # TODO:
        echo("Channel Control (0xFF24): ", b.toHex(4))
      of 0xFF25:
        # TODO:
        echo("Selection of Sound output terminal (0xFF25): ", b.toHex(4))
      of 0xFF26:
        # TODO:
        echo("Sound on/off (0xFF26): ", b.toHex(4))
      of 0xFF40:
        echo("LCDC (0xFF40): ", b.toHex(4))
        mem.gpu.setLCDC(b)
      of 0xFF42:
        echo("ScrollY = ", b.toHex(4), " ", b)
        mem.gpu.scrollY = b
      of 0xFF47:
        # TODO:
        echo("BG Palette (0xFF47): ", b.toHex(4))
      else:
        echo("Interrupts. Address: 0x", toHex(Address, 4), " Value: ", toHex(b, 4))
        assert false
    else:
      echo("0xF000. Address: 0x", toHex(Address, 4), " Value: ", toHex(b, 4))
  
  else:
    echo("writeByte. Address: 0x", toHex(address, 4), " Value: ", toHex(b, 4))

proc writeWord*(mem: PMem, address: int32, w: int32) =
  mem.writeByte(address, w and 255)
  mem.writeByte(address+1, w shr 8)

when isMainModule:
  var rom = load("/home/dom/code/nimrod/gbemulator/Pokemon_Red.gb")
  
  
  
  
  
  
  
  
  
  
  
  