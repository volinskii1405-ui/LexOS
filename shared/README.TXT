This folder is shared with LexOS.

`make run` attaches it as a second disk. Inside LexOS:
  hostls              - list what's here
  hostget <n> [new]   - copy a file into the current LexOS folder

Try:  hostget star.trg   then   turtle star.trg
      hostget bounce.ch8  then   chip8 bounce.ch8
      hostget guess.bas   then   basic guess.bas
      hostget catch.bas   then   basic catch.bas

Names show up as DOS-style 8.3 short names (long names get
shortened, e.g. MY-LON~1.TXT). Only files in this top-level
folder can be copied, up to 65535 bytes each. Files added
while QEMU is running appear after the next start.
