//
//  LegacySceneArchive.cpp
//  HIP Toolkit
//

#include "LegacySceneArchive.hpp"

#ifdef _MSC_VER
#pragma warning(push, 0)
#endif
#include "nlohmann_json.hpp"
#ifdef _MSC_VER
#pragma warning(pop)
#endif

#include "CIFArchive.hpp"   // readFile

#include <algorithm>
#include <array>
#include <cstring>
#include <stdexcept>

namespace CIF {
namespace Legacy {

using json = nlohmann::ordered_json;

namespace {

// ── byte helpers ────────────────────────────────────────────────────────────
uint32_t rU32BE(const uint8_t* p) {
    return uint32_t(p[0])<<24 | uint32_t(p[1])<<16 | uint32_t(p[2])<<8 | uint32_t(p[3]);
}
void wU32BE(std::vector<uint8_t>& o, uint32_t v) {
    o.push_back(uint8_t(v>>24)); o.push_back(uint8_t(v>>16));
    o.push_back(uint8_t(v>>8));  o.push_back(uint8_t(v));
}
uint16_t rU16LE(const uint8_t* p) { return uint16_t(p[0]) | uint16_t(p[1])<<8; }
uint32_t rU32LE(const uint8_t* p) {
    return uint32_t(p[0]) | uint32_t(p[1])<<8 | uint32_t(p[2])<<16 | uint32_t(p[3])<<24;
}

// The games' text is Windows-1252/Latin-1, not UTF-8 — bytes like 0x92 (curly
// apostrophe) are invalid UTF-8 and make nlohmann::dump() throw. We transcode
// every string that enters JSON as Latin-1 → UTF-8 (a 1:1 byte↔codepoint map
// for 0x00-0xFF, so it's lossless) and reverse it on the way back out, keeping
// the on-disk bytes byte-exact.
std::string latin1ToUtf8(const std::string& s) {
    std::string o; o.reserve(s.size());
    for (unsigned char c : s) {
        if (c < 0x80) o.push_back(char(c));
        else { o.push_back(char(0xC0 | (c >> 6))); o.push_back(char(0x80 | (c & 0x3F))); }
    }
    return o;
}
std::string utf8ToLatin1(const std::string& s) {
    std::string o; o.reserve(s.size());
    for (size_t i=0; i<s.size(); ) {
        unsigned char c = s[i];
        if (c < 0x80) { o.push_back(char(c)); ++i; }
        else if ((c & 0xE0)==0xC0 && i+1<s.size() && (uint8_t(s[i+1])&0xC0)==0x80) {
            o.push_back(char(((c & 0x1F) << 6) | (uint8_t(s[i+1]) & 0x3F))); i+=2;
        } else { o.push_back(char(c)); ++i; }   // passthrough (shouldn't happen for our data)
    }
    return o;
}

// Read a NUL-terminated fixed field as a JSON-safe (UTF-8) string.
std::string cstr(const uint8_t* p, size_t maxLen) {
    size_t n=0; while (n<maxLen && p[n]!=0) ++n;
    return latin1ToUtf8(std::string(reinterpret_cast<const char*>(p), n));
}

// ── base64 ──────────────────────────────────────────────────────────────────
const char* kB64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
std::string b64encode(const std::vector<uint8_t>& in) {
    std::string out; out.reserve((in.size()+2)/3*4);
    size_t i=0;
    for (; i+3<=in.size(); i+=3) {
        uint32_t v=(in[i]<<16)|(in[i+1]<<8)|in[i+2];
        out += kB64[(v>>18)&63]; out += kB64[(v>>12)&63];
        out += kB64[(v>>6)&63];  out += kB64[v&63];
    }
    size_t rem=in.size()-i;
    if (rem==1){ uint32_t v=in[i]<<16; out+=kB64[(v>>18)&63]; out+=kB64[(v>>12)&63]; out+="=="; }
    else if (rem==2){ uint32_t v=(in[i]<<16)|(in[i+1]<<8); out+=kB64[(v>>18)&63]; out+=kB64[(v>>12)&63]; out+=kB64[(v>>6)&63]; out+="="; }
    return out;
}
std::vector<uint8_t> b64decode(const std::string& s) {
    std::vector<uint8_t> out; out.reserve(s.size()*3/4);
    int val=0, bits=-8;
    for (unsigned char c : s) {
        const char* p = std::strchr(kB64, c);
        if (!p || c=='\0') { if (c=='=') break; continue; }
        val=(val<<6)+int(p-kB64); bits+=6;
        if (bits>=0){ out.push_back(uint8_t(val>>bits)); bits-=8; }
    }
    return out;
}

std::string toHex(const uint8_t* p, size_t n) {
    static const char* h="0123456789abcdef";
    std::string s; s.reserve(n*2);
    for (size_t i=0;i<n;++i){ s+=h[p[i]>>4]; s+=h[p[i]&15]; }
    return s;
}
std::vector<uint8_t> fromHex(const std::string& s) {
    auto nib=[](char c)->int{
        if(c>='0'&&c<='9')return c-'0';
        if(c>='a'&&c<='f')return c-'a'+10;
        if(c>='A'&&c<='F')return c-'A'+10;
        return 0;
    };
    std::vector<uint8_t> o; o.reserve(s.size()/2);
    for (size_t i=0;i+1<s.size();i+=2) o.push_back(uint8_t(nib(s[i])<<4|nib(s[i+1])));
    return o;
}

// ── chunk walk ──────────────────────────────────────────────────────────────
struct Chunk { std::string tag; size_t start, end; };  // payload [start,end)
std::vector<Chunk> walk(const std::vector<uint8_t>& d, size_t s, size_t e) {
    std::vector<Chunk> out; size_t off=s;
    while (off+8<=e) {
        std::string tag(reinterpret_cast<const char*>(d.data()+off), 4);
        while (!tag.empty() && tag.back()=='\0') tag.pop_back();
        uint32_t sz=rU32BE(d.data()+off+4);
        size_t ps=off+8, pe=ps+sz;
        if (pe>e) break;
        out.push_back({tag, ps, pe});
        off = pe + (sz&1);
    }
    return out;
}

// ── binary span <-> readable numbers (lossless) ─────────────────────────────
// A non-text span is shown as a u16 number array when its length is even
// (the dominant field width in this format — scene ids, coords, volumes,
// flags), else as a raw byte/hex span. No semantic labels are invented:
// these are just the bytes shown as numbers instead of a hex string.
json emitBin(const uint8_t* p, size_t n) {
    if (n>0 && (n%2)==0) {
        json arr = json::array();
        for (size_t k=0;k<n;k+=2) arr.push_back(rU16LE(p+k));
        return json{{"u16", arr}};
    }
    return json{{"bytes", toHex(p, n)}};
}
std::vector<uint8_t> readBin(const json& t) {
    std::vector<uint8_t> out;
    if (t.contains("u16")) {
        for (const auto& v : t["u16"]) { uint16_t x=uint16_t(v.get<int>()); out.push_back(uint8_t(x)); out.push_back(uint8_t(x>>8)); }
    } else if (t.contains("u32")) {
        for (const auto& v : t["u32"]) { uint32_t x=v.get<uint32_t>(); for(int s=0;s<32;s+=8) out.push_back(uint8_t(x>>s)); }
    } else if (t.contains("bytes")) {
        out = fromHex(t.value("bytes", std::string{}));
    } else if (t.contains("hex")) {              // backward compat
        out = fromHex(t.value("hex", std::string{}));
    }
    return out;
}

// ── ACT payload token model (lossless) ──────────────────────────────────────
// parts = ordered list of text slots and numeric/byte spans.
json tokenize(const uint8_t* p, size_t n) {
    json parts = json::array();
    size_t i=0;
    while (i<n) {
        size_t j=i;
        while (j<n && p[j]>=0x20 && p[j]<=0x7E) ++j;
        if (j-i>=4) {
            size_t k=j; while (k<n && p[k]==0) ++k;
            // "width" is the slot's fixed byte size (text + NUL padding).
            // detokenize() always writes exactly this many bytes, so an edit
            // never changes a record's size — matching the engine-validated
            // fixed-layout behaviour (an over-long edit is truncated to fit).
            parts.push_back({{"text", std::string(reinterpret_cast<const char*>(p+i), j-i)},
                             {"width", k-i}});
            i=k;
        } else {
            // accumulate a binary span until the next >=4 printable run
            size_t start=i;
            while (i<n) {
                size_t j2=i;
                while (j2<n && p[j2]>=0x20 && p[j2]<=0x7E) ++j2;
                if (j2-i>=4) break;
                i = (j2>i)? j2 : i+1;
            }
            parts.push_back(emitBin(p+start, i-start));
        }
    }
    return parts;
}
std::vector<uint8_t> detokenize(const json& parts) {
    std::vector<uint8_t> out;
    for (const auto& t : parts) {
        if (t.contains("text")) {
            std::string s = t.value("text", std::string{});
            // width = fixed slot size; truncate or NUL-pad the (possibly
            // edited) text to exactly that many bytes so record sizes never
            // shift. Falls back to text-length for legacy "pad"-style parts.
            size_t width = t.contains("width") ? t.value("width", size_t{0})
                                               : s.size() + t.value("pad", size_t{0});
            if (s.size() > width) s.resize(width);
            out.insert(out.end(), s.begin(), s.end());
            out.insert(out.end(), width - s.size(), uint8_t{0});
        } else {
            auto b = readBin(t);
            out.insert(out.end(), b.begin(), b.end());
        }
    }
    return out;
}

// ── ACT type labels (by AT_ code = low byte of the type word; from the
//    engine source Gameflow.h AT_* defines) ────────────────────────────────
const char* typeLabel(uint8_t at) {
    switch (at) {
        case 10: return "sceneChange";           // AT_HOT_1FR_SCENE_CHANGE
        case 11: return "sceneChangeHS";         // AT_HOT_MULTIFRAME_SCENE_CHANGE
        case 12: return "sceneChangeNoHS";       // AT_SCENE_CHANGE
        case 13: return "multiSceneChange";      // AT_HOT_MULTIFRAME_MULTISCENE_CHANGE
        case 14: return "exitSceneChange";
        case 15: return "forwardSceneChange";
        case 16: return "backSceneChange";
        case 17: return "upSceneChange";
        case 18: return "downSceneChange";
        case 19: return "forwardSceneChangeHS";
        case 20: return "upSceneChangeHS";
        case 21: return "downSceneChangeHS";
        case 22: return "leftSceneChange";
        case 23: return "rightSceneChange";
        case 24: return "multiSceneCursorChange";
        case 30: return "stopScrolling";
        case 31: return "startScrolling";
        case 40: return "specialEffect";
        case 51: return "secondaryVideoCh0";
        case 52: return "secondaryVideoCh1";
        case 53: return "secondaryMovie";
        case 54: return "overlay";
        case 57: return "conversationCel";
        case 58: return "conversationSound";
        case 75: return "textBoxWrite";
        case 76: return "textBoxClear";
        case 100: return "bumpClock";
        case 101: return "saveContinue";
        case 102: return "renderOff";
        case 103: return "renderOn";
        case 104: return "startTimer";
        case 105: return "stopTimer";
        case 106: return "eventFlagsHS";
        case 107: return "eventFlags";
        case 108: return "orderingPuzzle";
        case 109: return "loseGame";
        case 110: return "pushScene";
        case 111: return "popScene";
        case 112: return "winGame";
        case 113: return "difficultyLevel";
        case 114: return "rotatingLockPuzzle";
        case 115: return "leverPuzzle";
        case 116: return "telephone";
        case 117: return "sliderPuzzle";
        case 118: return "passwordPuzzle";
        case 120: return "addInventory";
        case 121: return "removeInventory";
        case 122: return "showInventory";
        case 123: return "inventorySoundOverride";
        case 150: return "playDigiSound";
        case 151: return "playStreamSound";
        case 152: return "playSoundFrameAnchor";
        case 153: return "playSoundMultiHS";
        case 154: return "stopSound";
        case 155: return "stopUnloadSound";
        case 156: return "update3DSound";
        case 160: return "hintSystem";
        case 170: return "setPlayerClock";
        case 200: return "soundEqualizerPuzzle";
        case 201: return "towerPuzzle";
        case 202: return "bombPuzzle";
        case 203: return "rippedLetterPuzzle";
        case 204: return "overrideLockPuzzle";
        case 205: return "riddlePuzzle";
        case 206: return "raycastPuzzle";
        case 207: return "tangramPuzzle";
        case 208: return "pianoPuzzle";
        case 209: return "turningPuzzle";
        case 210: return "safeDialPuzzle";
        case 211: return "collisionPuzzle";
        case 212: return "orderItemsPuzzle";
        default:  return "action";
    }
}

// ── pack(1) struct descriptors (from engine Globals.h; the engine writes
//    these byte-packed, no alignment padding — verified against the corpus).
//    Each ACT payload = [type struct][dependency tree]; we decode the struct
//    into named fields and keep the trailing dependency bytes as `deps`. A
//    per-record re-encode check guarantees this is byte-exact, else the
//    record falls back to the generic token model. ─────────────────────────
enum FK { F_B, F_S16, F_U16, F_S32, F_RECT, F_CSTR, F_EFLAGS, F_FHS };
struct Field { const char* name; FK kind; int n; };

// Returns the field list for an AT_ code, or nullptr if not modelled here.
const std::vector<Field>* fieldsForAT(uint8_t at) {
    static const std::vector<Field> sceneChange1Fr = {
        {"scene",F_S16,1},{"frame",F_S16,1},{"top",F_S16,1},{"soundPlayFlag",F_S16,1},
        {"listenerX",F_S32,1},{"listenerY",F_S32,1},{"listenerZ",F_S32,1},
        {"hsFrame",F_S16,1},{"rect",F_RECT,1}};
    static const std::vector<Field> sceneChange = {
        {"scene",F_S16,1},{"frame",F_S16,1},{"top",F_S16,1},{"soundPlayFlag",F_S16,1},
        {"listenerX",F_S32,1},{"listenerY",F_S32,1},{"listenerZ",F_S32,1}};
    static const std::vector<Field> eventFlags = {{"eventFlags",F_EFLAGS,10}};
    // multi-frame variants end in NumFrameHotSpots(i16) + FRAMEHOTSPOT[] (F_FHS).
    static const std::vector<Field> eventFlagsMultiHS = {
        {"eventFlags",F_EFLAGS,10},{"hotSpots",F_FHS,0}};
    static const std::vector<Field> sceneChangeMultiFr = {
        {"scene",F_S16,1},{"frame",F_S16,1},{"top",F_S16,1},{"soundPlayFlag",F_S16,1},
        {"listenerX",F_S32,1},{"listenerY",F_S32,1},{"listenerZ",F_S32,1},{"hotSpots",F_FHS,0}};
    // "Nothing" payloads (1 byte) shared by timer/render/save/scroll/lose/push/pop/win.
    static const std::vector<Field> nothing = {{"nothing",F_B,1}};
    static const std::vector<Field> difficulty = {
        {"difficultyLevel",F_S16,1},{"eventFlag",F_S16,1},{"state",F_S16,1}};
    static const std::vector<Field> bumpClock = {
        {"type",F_B,1},{"hours",F_S16,1},{"minutes",F_S16,1}};
    static const std::vector<Field> playDigiSound = {
        {"soundThemeFile",F_CSTR,33},{"channel",F_S16,1},{"soundPlaySource",F_S16,1},
        {"soundPlayMode",F_S16,1},{"numLoops",F_S32,1},{"leftVolume",F_S16,1},{"rightVolume",F_S16,1},
        {"minTimeDelay",F_S32,1},{"maxTimeDelay",F_S32,1},
        {"minX",F_S32,1},{"maxX",F_S32,1},{"minY",F_S32,1},{"maxY",F_S32,1},{"minZ",F_S32,1},{"maxZ",F_S32,1},
        {"fixedX",F_S32,1},{"fixedY",F_S32,1},{"fixedZ",F_S32,1},{"moveTime",F_S32,1},{"totalMoveSteps",F_S32,1},
        {"startX",F_S32,1},{"endX",F_S32,1},{"startY",F_S32,1},{"endY",F_S32,1},{"startZ",F_S32,1},{"endZ",F_S32,1},
        {"startCircleX",F_S32,1},{"startCircleY",F_S32,1},{"startCircleZ",F_S32,1},{"rotationAxis",F_B,1},
        {"minDistance",F_S32,1},{"maxDistance",F_S32,1},
        {"scene",F_S16,1},{"frame",F_S16,1},{"top",F_S16,1},{"soundPlayFlag",F_S16,1},
        {"listenerX",F_S32,1},{"listenerY",F_S32,1},{"listenerZ",F_S32,1},
        {"eventLabel",F_S16,1},{"eventState",F_B,1},{"renderingFlag",F_S16,1}};
    switch (at) {
        case 10: case 14: case 15: case 16: case 17: case 18: case 22: case 23: return &sceneChange1Fr;
        case 12: return &sceneChange;
        case 11: case 19: case 20: case 21: return &sceneChangeMultiFr;
        case 107: return &eventFlags;
        case 106: return &eventFlagsMultiHS;
        case 113: return &difficulty;
        case 100: return &bumpClock;
        case 150: case 151: case 152: return &playDigiSound;
        case 30: case 31: case 101: case 102: case 103: case 104: case 105:
        case 109: case 110: case 111: case 112: return &nothing;
        default: return nullptr;
    }
}

// decode struct fields from p[0..plen); returns false if it doesn't fit.
bool decodeStruct(const uint8_t* p, size_t plen, const std::vector<Field>& fs,
                  json& out, size_t& used) {
    size_t o=0;
    auto need=[&](size_t n){ return o+n<=plen; };
    for (const auto& f : fs) {
        switch (f.kind) {
            case F_B:    if(!need(1))return false; out[f.name]=p[o]; o+=1; break;
            case F_S16:  if(!need(2))return false; out[f.name]=(int16_t)rU16LE(p+o); o+=2; break;
            case F_U16:  if(!need(2))return false; out[f.name]=rU16LE(p+o); o+=2; break;
            case F_S32:  if(!need(4))return false; out[f.name]=(int32_t)rU32LE(p+o); o+=4; break;
            case F_RECT: if(!need(16))return false; {
                json r=json::array(); for(int i=0;i<4;++i) r.push_back((int32_t)rU32LE(p+o+i*4));
                out[f.name]=r; o+=16; } break;
            case F_CSTR: if(!need((size_t)f.n))return false;
                out[f.name]=cstr(p+o,f.n); o+=f.n; break;
            case F_EFLAGS: if(!need((size_t)f.n*4))return false; {
                json arr=json::array();
                for(int i=0;i<f.n;++i){ arr.push_back({{"flag",(int16_t)rU16LE(p+o)},
                                                       {"state",(int16_t)rU16LE(p+o+2)}}); o+=4; }
                out[f.name]=arr; } break;
            case F_FHS: { if(!need(2))return false;       // NumFrameHotSpots + FRAMEHOTSPOT[]
                int cnt=(int16_t)rU16LE(p+o); o+=2;
                if(cnt<0) return false;
                json arr=json::array();
                for(int i=0;i<cnt;++i){ if(!need(18))return false;
                    json r=json::array(); for(int k=0;k<4;++k) r.push_back((int32_t)rU32LE(p+o+2+k*4));
                    arr.push_back({{"frame",(int16_t)rU16LE(p+o)},{"rect",r}}); o+=18; }
                out[f.name]=arr; } break;
        }
    }
    used=o; return true;
}

std::vector<uint8_t> encodeStruct(const json& in, const std::vector<Field>& fs) {
    std::vector<uint8_t> out;
    auto pB=[&](uint8_t v){ out.push_back(v); };
    auto pU16=[&](uint16_t v){ out.push_back(uint8_t(v)); out.push_back(uint8_t(v>>8)); };
    auto pU32=[&](uint32_t v){ for(int s=0;s<32;s+=8) out.push_back(uint8_t(v>>s)); };
    for (const auto& f : fs) {
        switch (f.kind) {
            case F_B:    pB(uint8_t(in.value(f.name,0))); break;
            case F_S16:  pU16(uint16_t(in.value(f.name,0))); break;
            case F_U16:  pU16(uint16_t(in.value(f.name,0))); break;
            case F_S32:  pU32(uint32_t(in.value(f.name,0))); break;
            case F_RECT: { auto r=in.value(f.name,json::array());
                for(int i=0;i<4;++i) pU32(uint32_t(i<(int)r.size()? r[i].get<int32_t>():0)); } break;
            case F_CSTR: { std::string s=utf8ToLatin1(in.value(f.name,std::string{}));
                for(int i=0;i<f.n;++i) out.push_back(i<(int)s.size()? uint8_t(s[i]):0); } break;
            case F_EFLAGS: { auto a=in.value(f.name,json::array());
                for(int i=0;i<f.n;++i){ if(i<(int)a.size()){ pU16(uint16_t(a[i].value("flag",0)));
                    pU16(uint16_t(a[i].value("state",0))); } else { pU16(0); pU16(0); } } } break;
            case F_FHS: { auto a=in.value(f.name,json::array());
                pU16(uint16_t(a.size()));
                for(auto& fh:a){ pU16(uint16_t(fh.value("frame",0)));
                    auto r=fh.value("rect",json::array());
                    for(int k=0;k<4;++k) pU32(uint32_t(k<(int)r.size()? r[k].get<int32_t>():0)); } } break;
        }
    }
    return out;
}

// ── SSUM (SCENESUMMARYCHUNK, Globals.h) — confirmed named fields ─────────────
constexpr size_t SSUM_SIZE = 165;
const std::vector<Field>& ssumFields() {
    static const std::vector<Field> f = {
        {"description",F_CSTR,50},{"backgroundFile",F_CSTR,33},
        {"videoPlaySource",F_S16,1},{"videoFileFormat",F_S16,1},
        {"soundThemeFile",F_CSTR,33},
        {"soundPlaySource",F_S16,1},{"soundPlayFormat",F_S16,1},{"themeChannel",F_S16,1},
        {"soundPlayMode",F_S16,1},{"numberOfLoops",F_S32,1},
        {"leftVolume",F_S16,1},{"rightVolume",F_S16,1},
        {"panType",F_S16,1},{"degreesPerFrame",F_S16,1},
        {"startPosX",F_S32,1},{"startPosY",F_S32,1},{"startPosZ",F_S32,1},
        {"xAxisUnitMovement",F_S16,1},{"yAxisUnitMovement",F_S16,1},
        {"xScrollTolerance",F_S16,1},{"yScrollTolerance",F_S16,1},
        {"slowScrollDelay",F_S16,1},{"fastScrollDelay",F_S16,1},
        {"requiredCDRom",F_B,1}};
    return f;
}
json decodeSSUM(const uint8_t* b) {
    json s; size_t used=0;
    decodeStruct(b, SSUM_SIZE, ssumFields(), s, used);
    return s;
}
std::vector<uint8_t> encodeSSUM(const json& s) {
    auto b = encodeStruct(s, ssumFields());
    b.resize(SSUM_SIZE, 0);
    return b;
}

// ── ACT decode/encode ───────────────────────────────────────────────────────
// Each ACT payload = [type-specific struct][dependency tree]. Modelled types
// (see fieldsForAT) decode to named `fields`; the trailing dependency bytes
// become `deps`. Unmodelled types fall back to the generic token `parts`.
constexpr uint8_t AT_TEXTBOX_WRITE = 75;

json decodeACT(const std::vector<uint8_t>& d, size_t s, size_t e) {
    const uint8_t* rec = d.data()+s; size_t len=e-s;
    json a;
    a["name"] = cstr(rec, 48);
    uint8_t at = len>=49 ? rec[48] : 0;
    uint8_t execType = len>=50 ? rec[49] : 0;
    a["type"] = at;
    a["typeName"] = typeLabel(at);
    a["execType"] = execType;

    const size_t plen = len>50 ? len-50 : 0;
    const uint8_t* pl = rec+50;

    // 1. Modelled fixed-layout struct types (verified byte-exact per record).
    if (const auto* fs = fieldsForAT(at)) {
        json fields; size_t used=0;
        if (decodeStruct(pl, plen, *fs, fields, used)) {
            auto re = encodeStruct(fields, *fs);
            if (re.size()==used && std::memcmp(re.data(), pl, used)==0) {
                a["fields"] = fields;
                if (used < plen) a["deps"] = tokenize(pl+used, plen-used);
                return a;
            }
        }
    }
    // 2. TextBoxWrite: short NumTextBoxChars + char Text[count].
    if (at == AT_TEXTBOX_WRITE && plen >= 2) {
        int cnt = (int16_t)rU16LE(pl);
        if (cnt >= 0 && (size_t)(2+cnt) <= plen) {
            a["fields"] = json{{"text", latin1ToUtf8(std::string(reinterpret_cast<const char*>(pl+2), cnt))}};
            if ((size_t)(2+cnt) < plen) a["deps"] = tokenize(pl+2+cnt, plen-2-cnt);
            return a;
        }
    }
    // 3. Fallback: generic lossless token model.
    a["parts"] = plen ? tokenize(pl, plen) : json::array();
    return a;
}

std::vector<uint8_t> encodeACT(const json& a) {
    uint8_t at = uint8_t(a.value("type", 0));
    uint8_t execType = uint8_t(a.value("execType", 0));

    std::vector<uint8_t> payload;
    bool built = false;
    if (a.contains("fields")) {
        if (const auto* fs = fieldsForAT(at)) {
            payload = encodeStruct(a["fields"], *fs); built = true;
        } else if (at == AT_TEXTBOX_WRITE) {
            std::string t = utf8ToLatin1(a["fields"].value("text", std::string{}));
            payload.push_back(uint8_t(t.size())); payload.push_back(uint8_t(t.size()>>8));
            payload.insert(payload.end(), t.begin(), t.end()); built = true;
        }
    }
    if (!built) payload = detokenize(a.value("parts", json::array()));
    if (a.contains("deps")) {
        auto deps = detokenize(a["deps"]);
        payload.insert(payload.end(), deps.begin(), deps.end());
    }

    std::vector<uint8_t> rec(48, 0);
    std::string nm = utf8ToLatin1(a.value("name", std::string{}));
    std::memcpy(rec.data(), nm.data(), std::min<size_t>(nm.size(), 48));
    rec.push_back(at); rec.push_back(execType);
    rec.insert(rec.end(), payload.begin(), payload.end());
    return rec;
}

// ── whole-scene model decode/encode ─────────────────────────────────────────
json decodeModel(const std::vector<uint8_t>& raw) {
    if (raw.size()<8 || std::memcmp(raw.data(),"DATA",4)!=0)
        throw std::runtime_error("LegacyScene: not a DATA container");
    uint32_t size=rU32BE(raw.data()+4);
    size_t ps=8, pe=ps+size;
    if (pe>raw.size()) pe=raw.size();
    json m;
    m["form"] = cstr(raw.data()+ps, 4);
    json acts = json::array();
    json others = json::array();
    bool haveSummary=false;
    for (const auto& c : walk(raw, ps+4, pe)) {
        if (c.tag=="SSUM" && c.end-c.start==SSUM_SIZE) {
            m["summary"] = decodeSSUM(raw.data()+c.start);
            haveSummary=true;
        } else if (c.tag=="ACT") {
            acts.push_back(decodeACT(raw, c.start, c.end));
        } else {
            // any other chunk (BOOT tables, or unexpected) -> tag + lossless parts
            others.push_back({{"tag", c.tag},
                              {"parts", tokenize(raw.data()+c.start, c.end-c.start)}});
        }
    }
    if (haveSummary) { /* summary already set */ }
    m["actions"] = acts;
    if (!others.empty()) m["chunks"] = others;
    return m;
}

void appendChunk(std::vector<uint8_t>& inner, const std::string& tag,
                 const std::vector<uint8_t>& body) {
    char t[4]={' ',' ',' ',' '};
    for (size_t i=0;i<4 && i<tag.size();++i) t[i]=tag[i];
    // tags shorter than 4 are NUL-padded in the original (e.g. "ACT\0")
    for (size_t i=tag.size();i<4;++i) t[i]='\0';
    inner.insert(inner.end(), t, t+4);
    wU32BE(inner, uint32_t(body.size()));
    inner.insert(inner.end(), body.begin(), body.end());
    if (body.size()&1) inner.push_back(0);
}

std::vector<uint8_t> encodeModel(const json& m) {
    std::vector<uint8_t> inner;
    std::string form = m.value("form", std::string("SCEN"));
    char f[4]={' ',' ',' ',' '};
    for (size_t i=0;i<4 && i<form.size();++i) f[i]=form[i];
    for (size_t i=form.size();i<4;++i) f[i]='\0';
    inner.insert(inner.end(), f, f+4);

    if (m.contains("summary")) appendChunk(inner, "SSUM", encodeSSUM(m["summary"]));
    for (const auto& a : m.value("actions", json::array()))
        appendChunk(inner, "ACT", encodeACT(a));
    for (const auto& c : m.value("chunks", json::array()))
        appendChunk(inner, c.value("tag", std::string{}), detokenize(c.value("parts", json::array())));

    std::vector<uint8_t> out;
    out.insert(out.end(), {'D','A','T','A'});
    wU32BE(out, uint32_t(inner.size()));
    out.insert(out.end(), inner.begin(), inner.end());
    if (inner.size()&1) out.push_back(0);
    return out;
}

} // anonymous namespace

// ── public API ──────────────────────────────────────────────────────────────

std::string sceneToEditableJson(const std::vector<uint8_t>& raw, const std::string& gameVersion) {
    json model = decodeModel(raw);          // throws if not a DATA container

    // Verify the structural model reproduces the input byte-for-byte. If so,
    // ship clean JSON; if not (an unseen construct), keep a base64 _raw so
    // packing is still exact.
    bool clean = false;
    try { clean = (encodeModel(model) == raw); } catch (...) { clean = false; }

    json out;
    out["container"] = "WayneSikes.Scene";
    if (!gameVersion.empty()) out["version"] = gameVersion;
    out["form"] = model.value("form", std::string("SCEN"));
    if (model.contains("summary")) out["summary"] = model["summary"];
    out["actions"] = model.value("actions", json::array());
    if (model.contains("chunks")) out["chunks"] = model["chunks"];
    if (!clean) out["_raw"] = b64encode(raw);
    try {
        return out.dump(2);
    } catch (const std::exception&) {
        // Last-resort safety: if some byte still isn't valid UTF-8, never fail
        // the unpack — emit a minimal _raw-only document (still round-trips).
        json fb;
        fb["container"] = "WayneSikes.Scene";
        if (!gameVersion.empty()) fb["version"] = gameVersion;
        fb["form"] = model.value("form", std::string("SCEN"));
        fb["_raw"] = b64encode(raw);
        return fb.dump(2);
    }
}

std::vector<uint8_t> sceneFromEditableJson(const std::string& jsonStr) {
    json j = json::parse(jsonStr, nullptr, false);
    if (j.is_discarded() || j.value("container", std::string{}) != "WayneSikes.Scene")
        throw std::runtime_error("LegacyScene: not a WayneSikes.Scene document");
    if (j.contains("_raw"))
        return b64decode(j.value("_raw", std::string{}));
    // reconstruct from the structured model
    json model;
    model["form"]     = j.value("form", std::string("SCEN"));
    if (j.contains("summary")) model["summary"] = j["summary"];
    model["actions"]  = j.value("actions", json::array());
    if (j.contains("chunks")) model["chunks"] = j["chunks"];
    return encodeModel(model);
}

} // namespace Legacy
} // namespace CIF
