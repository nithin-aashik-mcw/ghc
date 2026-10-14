test('T7289',
     [extra_files(['fp.c']), unless(opsys('mingw32'), skip),
      # fp.c reads the x87 FPU control word.
      unless(arch('x86_64') or arch('i386'), skip),
      only_ways(['threaded1'])],
     compile_and_run, ['fp.c'])
