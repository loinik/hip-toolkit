//
//  LuaDecompiler.cpp
//  HIP Toolkit — Web (WebAssembly)
//
//  Lua 5.1 bytecode → source, the web counterpart of the desktop apps'
//  luadec binary. luadec (viruscamp/luadec, the revision the desktop apps
//  bundle) is compiled into the module with `main` renamed to luadec_main
//  and `exit` to hip_luadec_exit, so a failing decompile unwinds back here
//  instead of tearing the module down. Its stdout/stderr are redirected to
//  MEMFS files for the duration of a call.
//

#include "LuaDecompiler.hpp"

#include "CIFArchive.hpp"

#include <csetjmp>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

extern "C" int luadec_main(int argc, char* argv[]);

namespace {

std::jmp_buf* exitJump = nullptr;
int exitCode = 0;

std::string slurp(const char* path) {
    std::string out;
    if (FILE* f = std::fopen(path, "rb")) {
        char buf[8192];
        size_t n;
        while ((n = std::fread(buf, 1, sizeof buf, f)) > 0) out.append(buf, n);
        std::fclose(f);
    }
    std::remove(path);
    return out;
}

} // namespace

extern "C" void hip_luadec_exit(int code) {
    exitCode = code;
    if (exitJump) std::longjmp(*exitJump, 1);
    std::abort();
}

namespace HIPWeb {

std::vector<uint8_t> decompileLua(const std::string& path) {
    static const char* OUT = "/tmp/.luadec.out";
    static const char* ERR = "/tmp/.luadec.err";

    std::fflush(stdout);
    std::fflush(stderr);
    if (!std::freopen(OUT, "w", stdout) || !std::freopen(ERR, "w", stderr))
        throw std::runtime_error("luadec: cannot redirect output");

    std::string arg0 = "luadec", arg1 = path;
    char* argv[] = { arg0.data(), arg1.data(), nullptr };

    std::jmp_buf jump;
    exitJump = &jump;
    exitCode = 0;
    int status;
    if (setjmp(jump) == 0) {
        status = luadec_main(2, argv);
    } else {
        status = exitCode;  // luadec called exit()
    }
    exitJump = nullptr;

    std::fflush(stdout);
    std::fflush(stderr);
    std::freopen("/dev/stdout", "w", stdout);
    std::freopen("/dev/stderr", "w", stderr);

    std::string out = slurp(OUT);
    std::string err = slurp(ERR);
    if (status != 0) {
        while (!err.empty() && (err.back() == '\n' || err.back() == '\r')) err.pop_back();
        throw std::runtime_error("Decompilation failed" + (err.empty() ? std::string() : ": " + err));
    }
    if (out.empty()) throw std::runtime_error("Decompilation failed: empty output");

    // Turn luadec's "\ddd" escapes back into the game's single-byte text,
    // exactly like the desktop apps.
    const std::string readable = CIF::luaDecompiledToReadable(out);
    return std::vector<uint8_t>(readable.begin(), readable.end());
}

} // namespace HIPWeb
