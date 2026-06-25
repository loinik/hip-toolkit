/* vorbis_compile.c — single TU that compiles all of libogg + libvorbis.
   Include this one file in any build system instead of listing every .c file.
   Duplicate static symbols across files are disambiguated with #define. */

#ifdef _MSC_VER
#  pragma warning(push, 0)
#endif
#if defined(__clang__)
#  pragma clang diagnostic push
#  pragma clang diagnostic ignored "-Weverything"
#elif defined(__GNUC__)
#  pragma GCC diagnostic push
#  pragma GCC diagnostic ignored "-Wall"
#  pragma GCC diagnostic ignored "-Wextra"
#endif

/* ── libogg ─────────────────────────────────────────────────────────────── */
#include "../../libogg/src/bitwise.c"
#include "../../libogg/src/framing.c"

/* ── libvorbis ──────────────────────────────────────────────────────────── */
#include "analysis.c"
#include "bitrate.c"
#include "block.c"

/* codebook.c has its own static bitreverse — disambiguate from sharedbook.c */
#define bitreverse codebook__bitreverse
#include "codebook.c"
#undef bitreverse

#include "envelope.c"
#include "floor0.c"

/* floor1.c, mapping0.c, psy.c each define their own static FLOOR1_fromdB_LOOKUP */
#define FLOOR1_fromdB_LOOKUP floor1__fromdB_LOOKUP
#include "floor1.c"
#undef FLOOR1_fromdB_LOOKUP

#include "info.c"
#include "lookup.c"
#include "lpc.c"
#include "lsp.c"

#define FLOOR1_fromdB_LOOKUP mapping0__fromdB_LOOKUP
#include "mapping0.c"
#undef FLOOR1_fromdB_LOOKUP

#include "mdct.c"

#define FLOOR1_fromdB_LOOKUP psy__fromdB_LOOKUP
#include "psy.c"
#undef FLOOR1_fromdB_LOOKUP

#include "registry.c"
#include "res0.c"

/* sharedbook.c has its own static bitreverse — already disambiguated above */
#define bitreverse sharedbook__bitreverse
#include "sharedbook.c"
#undef bitreverse

#include "smallft.c"
#include "synthesis.c"
#include "vorbisenc.c"
#include "window.c"

#ifdef _MSC_VER
#  pragma warning(pop)
#endif
#if defined(__clang__)
#  pragma clang diagnostic pop
#elif defined(__GNUC__)
#  pragma GCC diagnostic pop
#endif
