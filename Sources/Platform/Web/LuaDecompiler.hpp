#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace HIPWeb {

/// Decompiles a Lua 5.1 bytecode file with luadec. Returns the source in the
/// game's original single-byte encoding (escapes already turned back into
/// bytes); throws std::runtime_error with luadec's message on failure.
std::vector<uint8_t> decompileLua(const std::string& path);

} // namespace HIPWeb
