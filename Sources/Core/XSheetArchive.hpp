#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace XSheet {

/// Raw .xsheet binary body → JSON string.
/// Returns empty string if `body` is not a valid XSheet binary.
std::string toJson(const std::vector<uint8_t>& body);

/// JSON string → raw .xsheet binary body.
/// Returns empty vector if `json` is not a valid XSheet JSON (structured or legacy).
std::vector<uint8_t> fromJson(const std::string& json);

} // namespace XSheet
