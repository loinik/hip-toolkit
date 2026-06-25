/* shine_compile.c — single TU that compiles all of libshine. */
#ifdef _MSC_VER
#  pragma warning(push, 0)
/* MSVC doesn't support GCC's __attribute__ syntax */
#  define __attribute__(x)
#endif
#if defined(__clang__)
#  pragma clang diagnostic push
#  pragma clang diagnostic ignored "-Weverything"
#elif defined(__GNUC__)
#  pragma GCC diagnostic push
#  pragma GCC diagnostic ignored "-Wall"
#  pragma GCC diagnostic ignored "-Wextra"
#endif

#include "bitstream.c"
#include "huffman.c"
#include "l3bitstream.c"
#include "l3loop.c"
#include "l3mdct.c"
#include "l3subband.c"
#include "layer3.c"
#include "reservoir.c"
#include "tables.c"

#ifdef _MSC_VER
#  pragma warning(pop)
#endif
#if defined(__clang__)
#  pragma clang diagnostic pop
#elif defined(__GNUC__)
#  pragma GCC diagnostic pop
#endif
