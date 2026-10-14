#pragma once

#if defined(OBJFORMAT_PEi386)

#include "ghcplatform.h"
#include "PEi386.h"
#include "linker/InitFini.h"
#include <stdint.h>
#include <stdio.h>

struct SectionFormatInfo {
    char* name;
    size_t alignment;
    COFF_reloc* relocs;
    uint32_t noRelocs;
    uint32_t props;
    uint64_t virtualSize;
    uint64_t virtualAddr;
 };

struct ObjectCodeFormatInfo {
    struct InitFiniList* init; // Freed by ocRunInit_PEi386
    struct InitFiniList* fini; // Freed by ocRunFini_PEi386
    Section* pdata;
    Section* xdata;
    COFF_HEADER_INFO* ch_info; // Freed by ocResolve_PEi386
    COFF_symbol* symbols;      // Freed by ocResolve_PEi386
    char* str_tab;
#if defined(aarch64_HOST_ARCH)
    /* Jump islands, see Note [ARM64 jump islands] in PEi386.c. */
    uint8_t* islands;          // Reserved by ocGetNames_PEi386 (rx_m32)
    uint32_t n_islands;        // Capacity of islands
    uint32_t used_islands;     // Islands handed out so far
    uint8_t** sym_islands;     // Island per symbol index, freed by ocResolve_PEi386
#endif
 };

#endif /* OBJFORMAT_PEi386.  */
