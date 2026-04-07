#include "CiftreeArchive.hpp"
#include "CIFArchive.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <cstring>
#include <stdexcept>

namespace CIF {

namespace {

static constexpr std::array<uint8_t, 28> CIFTREE_MAGIC = {
    0x43, 0x49, 0x46, 0x20, 0x46, 0x49, 0x4C, 0x45, 0x20,
    0x48, 0x65, 0x72, 0x49, 0x6E, 0x74, 0x65, 0x72, 0x61,
    0x63, 0x74, 0x69, 0x76, 0x65,
    0x00, 0x03, 0x00, 0x00, 0x00
};

static constexpr size_t MAGIC_SIZE = 28;
static constexpr size_t NAME_BYTES = 64;  // used only when packing (our own archives)
static constexpr size_t TAIL_PAD   = 0;   // original tool writes no trailing bytes after indexesSize

void writeLE32v(std::vector<uint8_t>& v, uint32_t value) {
    v.push_back(static_cast<uint8_t>(value));
    v.push_back(static_cast<uint8_t>(value >> 8));
    v.push_back(static_cast<uint8_t>(value >> 16));
    v.push_back(static_cast<uint8_t>(value >> 24));
}

uint32_t readLE32p(const uint8_t* p) {
    return static_cast<uint32_t>(p[0])
         | static_cast<uint32_t>(p[1]) << 8
         | static_cast<uint32_t>(p[2]) << 16
         | static_cast<uint32_t>(p[3]) << 24;
}

std::string trimName(const uint8_t* field, size_t fieldLen) {
    size_t len = 0;
    for (size_t i = 0; i < fieldLen; ++i)
        if (field[i] != 0x00) len = i + 1;
    return std::string(reinterpret_cast<const char*>(field), len);
}

} // anonymous namespace


// ── Pack (entries overload) ───────────────────────────────────────────────

std::vector<uint8_t> packCiftree(const std::vector<CiftreeEntry>& entries) {
    if (entries.empty())
        throw std::runtime_error("Ciftree: no entries to pack");

    const uint32_t fileCount   = static_cast<uint32_t>(entries.size());
    const uint32_t entrySize   = static_cast<uint32_t>(NAME_BYTES + 4);
    const uint32_t titlesBytes = fileCount * entrySize;
    const uint32_t indexesSize = titlesBytes + 4;

    // Compute absolute offsets
    std::vector<uint32_t> offsets;
    offsets.reserve(fileCount);
    uint32_t cursor = static_cast<uint32_t>(MAGIC_SIZE);
    for (const auto& e : entries) {
        offsets.push_back(cursor);
        cursor += static_cast<uint32_t>(e.cifData.size());
    }

    std::vector<uint8_t> out;
    out.reserve(MAGIC_SIZE + (cursor - MAGIC_SIZE) + 4 + titlesBytes + 4 + TAIL_PAD);

    out.insert(out.end(), CIFTREE_MAGIC.begin(), CIFTREE_MAGIC.end());
    for (const auto& e : entries)
        out.insert(out.end(), e.cifData.begin(), e.cifData.end());

    writeLE32v(out, fileCount);
    for (size_t i = 0; i < entries.size(); ++i) {
        std::array<uint8_t, NAME_BYTES> field{};
        size_t copyLen = std::min(entries[i].name.size(), NAME_BYTES);
        std::memcpy(field.data(), entries[i].name.data(), copyLen);
        out.insert(out.end(), field.begin(), field.end());
        writeLE32v(out, offsets[i]);
    }
    writeLE32v(out, indexesSize);
    for (size_t i = 0; i < TAIL_PAD; ++i) out.push_back(0x00);
    return out;
}

// ── Pack (paths overload) ─────────────────────────────────────────────────

std::vector<uint8_t> packCiftree(const std::vector<std::filesystem::path>& cifPaths) {
    if (cifPaths.empty())
        throw std::runtime_error("Ciftree: no files to pack");

    std::vector<CiftreeEntry> entries;
    entries.reserve(cifPaths.size());
    for (const auto& path : cifPaths)
        entries.push_back({path.stem().string(), readFile(path)});
    return packCiftree(entries);
}


// ── Unpack ────────────────────────────────────────────────────────────────
//
// Layout (from the C# tool and original game archives):
//
//   [magic:28] [bodies:Σ] [count:4] [titles:N*entrySize] [indexesSize:4] [zeros:0-4]
//
// Key points:
//   - Offsets in the title table are ABSOLUTE from byte 0 (first file starts at 28)
//   - entrySize is derived dynamically: titlesBytes / fileCount
//   - Trailing zero padding may or may not be present — we probe both positions

std::vector<CiftreeEntry> unpackCiftree(const std::filesystem::path& datPath) {
    const auto data  = readFile(datPath);
    const size_t total = data.size();

    if (total < MAGIC_SIZE + 4 + 4 + 4)
        throw std::runtime_error("Ciftree: file too small");

    if (std::memcmp(data.data(), CIFTREE_MAGIC.data(), MAGIC_SIZE) != 0)
        throw std::runtime_error("Ciftree: invalid magic");

    // ── Step 1: find indexesSize
    // Try with 4 trailing zeros (our tool and most original archives),
    // then without (some older archives omit the padding).
    uint32_t indexesSize = 0;
    size_t   trailingZeros = 0;

    auto tryAt = [&](size_t pos) -> bool {
        if (pos + 4 > total) return false;
        uint32_t candidate = readLE32p(data.data() + pos);
        // Sanity: must be at least 8 (1 file = count(4) + 1 entry(≥4))
        // and must not exceed half the file size
        if (candidate < 8 || candidate > total / 2) return false;
        indexesSize  = candidate;
        return true;
    };

    // Try TAIL_PAD=0 first (matches original tool output), then TAIL_PAD=4 (older tool versions).
    if      (tryAt(total - 4)) { trailingZeros = 0; }
    else if (tryAt(total - 8)) { trailingZeros = 4; }
    else
        throw std::runtime_error("Ciftree: cannot locate index section");

    if (indexesSize < 8)
        throw std::runtime_error("Ciftree: index section too small");

    // titlesBytes does NOT include the 4-byte count field
    const uint32_t titlesBytes = indexesSize - 4;

    // ── Step 2: locate the count field and read fileCount
    //
    // From the end: [zeros:trailingZeros][indexesSize:4][titles:titlesBytes][count:4]...
    const size_t indexesSizeOffset = total - trailingZeros - 4;
    if (titlesBytes > indexesSizeOffset)
        throw std::runtime_error("Ciftree: titles section extends before magic");

    const size_t titlesOffset = indexesSizeOffset - titlesBytes;
    if (titlesOffset < 4)
        throw std::runtime_error("Ciftree: no room for count field");

    const size_t countOffset = titlesOffset - 4;
    const uint32_t fileCount = readLE32p(data.data() + countOffset);

    if (fileCount == 0) return {};
    if (titlesBytes % fileCount != 0)
        throw std::runtime_error(
            "Ciftree: titles section (" + std::to_string(titlesBytes) +
            " bytes) is not evenly divisible by file count (" +
            std::to_string(fileCount) + ")");

    const size_t entrySize = titlesBytes / fileCount;
    if (entrySize < 5)  // need at least 1 name byte + 4 offset bytes
        throw std::runtime_error("Ciftree: entry size too small: " + std::to_string(entrySize));

    const size_t nameBytes  = entrySize - 4;
    const size_t contentsEnd = countOffset;  // bodies end where count field begins

    // ── Step 3: parse title table
    struct TitleEntry { std::string name; uint32_t absOffset; };
    std::vector<TitleEntry> titles;
    titles.reserve(fileCount);

    for (uint32_t i = 0; i < fileCount; ++i) {
        const uint8_t* entry = data.data() + titlesOffset + i * entrySize;
        TitleEntry t;
        t.name      = trimName(entry, nameBytes);
        t.absOffset = readLE32p(entry + nameBytes);  // absolute from byte 0
        titles.push_back(std::move(t));
    }

    // ── Step 4: sort by offset to compute slice boundaries
    std::vector<size_t> order(fileCount);
    for (size_t i = 0; i < fileCount; ++i) order[i] = i;
    std::sort(order.begin(), order.end(),
              [&](size_t a, size_t b){ return titles[a].absOffset < titles[b].absOffset; });

    // ── Step 5: extract CIF data
    std::vector<CiftreeEntry> result(fileCount);

    for (size_t rank = 0; rank < fileCount; ++rank) {
        const size_t idx   = order[rank];
        const size_t start = titles[idx].absOffset;          // absolute
        const size_t end   = (rank + 1 < fileCount)
                                 ? titles[order[rank + 1]].absOffset
                                 : contentsEnd;

        if (start < MAGIC_SIZE || start > end || end > total)
            throw std::runtime_error(
                "Ciftree: bad offset for entry \"" + titles[idx].name + "\""
                " (start=" + std::to_string(start) +
                " end=" + std::to_string(end) + ")");

        result[idx].name    = titles[idx].name;
        result[idx].cifData = std::vector<uint8_t>(
            data.begin() + static_cast<std::ptrdiff_t>(start),
            data.begin() + static_cast<std::ptrdiff_t>(end)
        );
    }

    return result;
}


// ── packFolder ────────────────────────────────────────────────────────────

std::vector<uint8_t> packFolder(const std::filesystem::path& folderPath,
                                 const PackOptions& opts) {
    namespace fs = std::filesystem;

    std::vector<fs::path> filePaths;
    for (const auto& entry : fs::recursive_directory_iterator(
            folderPath, fs::directory_options::skip_permission_denied)) {
        if (entry.is_regular_file())
            filePaths.push_back(entry.path());
    }
    std::sort(filePaths.begin(), filePaths.end());

    std::vector<CiftreeEntry> entries;
    entries.reserve(filePaths.size());

    for (const auto& path : filePaths) {
        std::string rawExt = path.extension().string();
        std::string ext;
        ext.reserve(rawExt.size());
        for (unsigned char c : rawExt)
            ext.push_back(static_cast<char>(std::tolower(c)));

        std::string stem = path.stem().string();
        if (opts.capitalizeNames) {
            std::string up;
            up.reserve(stem.size());
            for (unsigned char c : stem)
                up.push_back(static_cast<char>(std::toupper(c)));
            stem = std::move(up);
        }

        try {
            std::vector<uint8_t> cifData;
            if (ext == ".cif") {
                cifData = readFile(path);
            } else if (ext == ".png") {
                FileType ft = opts.useOVLForPNG ? FileType::OVL : FileType::PNG;
                cifData = encodePNG(path, ft);
            } else if (ext == ".lua") {
                cifData = encodeLua(path, opts.compileLua);
            } else if (ext == ".xsheet") {
                cifData = encodeXSheet(path);
            } else {
                continue;  // unsupported — skip silently
            }
            entries.push_back({std::move(stem), std::move(cifData)});
        } catch (const std::exception&) {
            continue;  // encoding failed — skip silently
        }
    }

    return packCiftree(entries);
}


// ── unpackToFolder ────────────────────────────────────────────────────────

void unpackToFolder(const std::filesystem::path& datPath,
                    const std::filesystem::path& outDir,
                    const UnpackOptions& opts) {
    auto entries = unpackCiftree(datPath);
    std::filesystem::create_directories(outDir);

    for (const auto& entry : entries) {
        if (!opts.extractContents) {
            writeFile(outDir / (entry.name + ".cif"), entry.cifData);
            continue;
        }

        if (entry.cifData.size() < HEADER_SIZE) {
            writeFile(outDir / (entry.name + ".cif"), entry.cifData);
            continue;
        }

        std::string ext = ".cif";
        try {
            auto hdr = readHeaderFromBytes(entry.cifData);
            switch (hdr.type) {
                case FileType::PNG:
                case FileType::OVL:    ext = ".png";    break;
                case FileType::Lua:    ext = ".lua";    break;
                case FileType::XSheet: ext = ".xsheet"; break;
                default:               ext = ".cif";    break;
            }
        } catch (...) { ext = ".cif"; }

        if (ext == ".cif") {
            writeFile(outDir / (entry.name + ".cif"), entry.cifData);
        } else {
            writeFile(outDir / (entry.name + ext), decodeFromBytes(entry.cifData));
        }
    }
}

} // namespace CIF
