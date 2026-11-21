#import <Metal/Metal.h>
#include "mtl_shader_compiler.h"
#include "d3d9_metal_types.h"

#include "ir/ir.h"
#include "ir/ir_builder.h"
#include "ir/ir_legalize.h"
#include "ir/ir_serialize.h"
#include "ir/passes/ir_pass_arithmetic.h"
#include "ir/passes/ir_pass_cfg_cleanup.h"
#include "ir/passes/ir_pass_cse.h"
#include "ir/passes/ir_pass_lower_io.h"
#include "ir/passes/ir_pass_remove_unused.h"
#include "ir/passes/ir_pass_ssa.h"
#include "sm3/sm3_converter.h"
#include "spirv/spirv_builder.h"
#include "spirv/spirv_mapping.h"
#include "util/util_byte_stream.h"
#include "util/util_log.h"

#include <spirv_cross/spirv_msl.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fstream>
#include <mutex>
#include <sstream>
#include <sys/stat.h>
#include <unordered_set>
#include <vector>

namespace mtl_d3d9 {

static std::atomic<void (*)(int)> gStallHook{nullptr};

void MtlShaderCompiler::setStallHook(void (*fn)(int)) {
    gStallHook.store(fn, std::memory_order_release);
}

namespace {

static uint64_t fnv1a64(const void *data, size_t bytes, uint64_t seed = 14695981039346656037ull) {
    const uint8_t *p = static_cast<const uint8_t *>(data);
    uint64_t h = seed;
    for (size_t i = 0; i < bytes; i++) {
        h ^= p[i];
        h *= 1099511628211ull;
    }
    return h;
}

class MtlDxbcLogger : public dxbc_spv::util::Logger {
public:
    dxbc_spv::LogLevel getMinimumSeverity() override { return dxbc_spv::LogLevel::eWarn; }
    void message(dxbc_spv::LogLevel severity, const char *msg) override {
        if (severity >= dxbc_spv::LogLevel::eError) {
            fprintf(stderr, "[dxbc-spirv] %s\n", msg);
        }
    }
};

/* Maps dxbc-spirv IR descriptors into clean SPIR-V (set, binding) pairs:
   set 0: CBVs     (binding = regIndex 0..9)
   set 1: Textures (binding = regIndex 0..15)
   set 2: Samplers (binding = regIndex 0..15) */
class MtlSpirvMapping : public dxbc_spv::spirv::ResourceMapping {
public:
    dxbc_spv::spirv::DescriptorBinding mapDescriptor(
        dxbc_spv::ir::ScalarType type,
        uint32_t regSpace,
        uint32_t regIndex) override {
        (void)regSpace;
        switch (type) {
            case dxbc_spv::ir::ScalarType::eCbv:
                return { 0u, regIndex };
            case dxbc_spv::ir::ScalarType::eSrv:
                return { 1u, regIndex };
            case dxbc_spv::ir::ScalarType::eSampler:
                return { 2u, regIndex };
            default:
                return { 3u, regIndex };
        }
    }

    uint32_t mapPushData(dxbc_spv::ir::ShaderStageMask) override {
        return 0u;
    }
};

static uint8_t parseD3dUsageName(const std::string &name) {
    auto eq = [&](const char *s) { return strcasecmp(name.c_str(), s) == 0; };
    if (eq("POSITION"))                         return 0;  /* D3DDECLUSAGE_POSITION */
    if (eq("WEIGHT") || eq("BLENDWEIGHT"))      return 1;  /* D3DDECLUSAGE_BLENDWEIGHT */
    if (eq("BLEND")  || eq("BLENDINDICES"))     return 2;  /* D3DDECLUSAGE_BLENDINDICES */
    if (eq("NORMAL"))                           return 3;  /* D3DDECLUSAGE_NORMAL */
    if (eq("PSIZE"))                            return 4;  /* D3DDECLUSAGE_PSIZE */
    if (eq("TEXCOORD"))                         return 5;  /* D3DDECLUSAGE_TEXCOORD */
    if (eq("TANGENT"))                          return 6;  /* D3DDECLUSAGE_TANGENT */
    if (eq("BINORMAL"))                         return 7;  /* D3DDECLUSAGE_BINORMAL */
    if (eq("TESSFACTOR"))                       return 8;  /* D3DDECLUSAGE_TESSFACTOR */
    if (eq("POSITION_T") || eq("POSITIONT"))    return 9;  /* D3DDECLUSAGE_POSITIONT */
    if (eq("COLOR"))                            return 10; /* D3DDECLUSAGE_COLOR */
    if (eq("FOG"))                              return 11; /* D3DDECLUSAGE_FOG */
    if (eq("DEPTH"))                            return 12; /* D3DDECLUSAGE_DEPTH */
    if (eq("SAMPLE"))                           return 13; /* D3DDECLUSAGE_SAMPLE */
    fprintf(stderr, "RunnerMetal: WARNING unknown VS semantic '%s'\n", name.c_str());
    return 0xFF;
}

static uint64_t hashIoMap(const dxbc_spv::ir::IoMap &ioMap) {
    uint64_t h = 14695981039346656037ull;
    for (uint32_t i = 0; i < ioMap.getCount(); i++) {
        auto loc = ioMap.get(i);
        uint32_t packed = (uint32_t(loc.getType()) << 16) |
                          (uint32_t(loc.getLocationIndex()) << 8) |
                          uint32_t(loc.getComponentMask());
        h = fnv1a64(&packed, sizeof(packed), h);
        auto sem = ioMap.getSemanticForEntry(loc);
        if (sem) {
            h = fnv1a64(sem.name.data(), sem.name.size(), h);
            h = fnv1a64(&sem.index, sizeof(sem.index), h);
        }
    }
    return h;
}

/* Injects D3D9 half-pixel viewport offset (1/vpW, -1/vpH) and clip-space depth bias
   on every vertex shader's BuiltIn::ePosition output right inside dxbc-spirv IR. */
static void injectVertexPosFixup(dxbc_spv::ir::Builder &builder) {
    using namespace dxbc_spv::ir;

    SsaDef entryPoint = {};
    SsaDef posDecl = {};
    auto [da, db] = builder.getDeclarations();
    for (auto it = da; it != db; ++it) {
        if (it->getOpCode() == OpCode::eEntryPoint) {
            entryPoint = it->getDef();
        } else if (it->getOpCode() == OpCode::eDclOutputBuiltIn &&
                   BuiltIn(it->getOperand(it->getFirstLiteralOperandIndex())) == BuiltIn::ePosition) {
            posDecl = it->getDef();
        }
    }
    if (!entryPoint || !posDecl) return;

    /* Find OutputStores to posDecl */
    SsaDef compStore[4] = {};
    SsaDef compVal[4] = {};
    SsaDef vec4Store = {};
    SsaDef vec4Val = {};
    SsaDef lastStore = {};

    auto [ca, cb] = builder.getCode();
    for (auto it = ca; it != cb; ++it) {
        if (it->getOpCode() == OpCode::eOutputStore && SsaDef(it->getOperand(0u)) == posDecl) {
            SsaDef addr = SsaDef(it->getOperand(1u));
            SsaDef val  = SsaDef(it->getOperand(2u));
            if (!addr) {
                vec4Store = it->getDef();
                vec4Val = val;
                lastStore = it->getDef();
            } else {
                const auto &addrOp = builder.getOp(addr);
                if (addrOp.getOpCode() == OpCode::eConstant) {
                    uint32_t idx = uint32_t(addrOp.getOperand(0u));
                    if (idx < 4u) {
                        compStore[idx] = it->getDef();
                        compVal[idx] = val;
                        lastStore = it->getDef();
                    }
                }
            }
        }
    }

    if (!lastStore) return;

    /* Declare PosFixup CBV at regSpace=0, regIndex=9 (Metal VS buffer 23) */
    auto cbvDef = builder.add(Op::DclCbv(Type(ScalarType::eF32, 4u), entryPoint, 0u, 9u, 1u));
    builder.add(Op::DebugName(cbvDef, "pos_fixup"));

    auto insertBefore = lastStore;
    SsaDef valX, valY, valZ, valW;
    if (vec4Store) {
        valX = builder.addBefore(insertBefore, Op::CompositeExtract(ScalarType::eF32, vec4Val, builder.makeConstant(0u)));
        valY = builder.addBefore(insertBefore, Op::CompositeExtract(ScalarType::eF32, vec4Val, builder.makeConstant(1u)));
        valZ = builder.addBefore(insertBefore, Op::CompositeExtract(ScalarType::eF32, vec4Val, builder.makeConstant(2u)));
        valW = builder.addBefore(insertBefore, Op::CompositeExtract(ScalarType::eF32, vec4Val, builder.makeConstant(3u)));
    } else {
        valX = compVal[0] ? compVal[0] : builder.makeConstant(0.0f);
        valY = compVal[1] ? compVal[1] : builder.makeConstant(0.0f);
        valZ = compVal[2] ? compVal[2] : builder.makeConstant(0.0f);
        valW = compVal[3] ? compVal[3] : builder.makeConstant(1.0f);
    }

    auto desc = builder.addBefore(insertBefore, Op::DescriptorLoad(ScalarType::eCbv, cbvDef, builder.makeConstant(0u)));
    auto fixX = builder.addBefore(insertBefore, Op::BufferLoad(ScalarType::eF32, desc, builder.makeConstant(0u), 4u));
    auto fixY = builder.addBefore(insertBefore, Op::BufferLoad(ScalarType::eF32, desc, builder.makeConstant(1u), 4u));
    auto fixB = builder.addBefore(insertBefore, Op::BufferLoad(ScalarType::eF32, desc, builder.makeConstant(3u), 4u));

    auto newX = builder.addBefore(insertBefore, Op::FMad(ScalarType::eF32, fixX, valW, valX));
    auto newY = builder.addBefore(insertBefore, Op::FMad(ScalarType::eF32, fixY, valW, valY));
    auto biasedZ = builder.addBefore(insertBefore, Op::FMad(ScalarType::eF32, fixB, valW, valZ));
    auto zero = builder.makeConstant(0.0f);
    auto geZero = builder.addBefore(insertBefore, Op::FGe(ScalarType::eBool, valZ, zero));
    auto leW = builder.addBefore(insertBefore, Op::FLe(ScalarType::eBool, valZ, valW));
    auto inRange = builder.addBefore(insertBefore, Op::BAnd(ScalarType::eBool, geZero, leW));
    auto clampedZ = builder.addBefore(insertBefore, Op::FClamp(ScalarType::eF32, biasedZ, zero, valW));
    auto newZ = builder.addBefore(insertBefore, Op::Select(ScalarType::eF32, inRange, clampedZ, biasedZ));

    if (vec4Store) {
        auto newVec = builder.addBefore(insertBefore, Op::CompositeConstruct(BasicType(ScalarType::eF32, 4u), newX, newY, newZ, valW));
        builder.rewriteOp(vec4Store, Op::OutputStore(posDecl, SsaDef(), newVec));
    } else {
        /* Emit all 4 stores right at insertBefore (after valX..valW are all defined) and remove old stores */
        builder.addBefore(insertBefore, Op::OutputStore(posDecl, builder.makeConstant(0u), newX));
        builder.addBefore(insertBefore, Op::OutputStore(posDecl, builder.makeConstant(1u), newY));
        builder.addBefore(insertBefore, Op::OutputStore(posDecl, builder.makeConstant(2u), newZ));
        builder.addBefore(insertBefore, Op::OutputStore(posDecl, builder.makeConstant(3u), valW));
        for (int i = 0; i < 4; i++) {
            if (compStore[i]) builder.remove(compStore[i]);
        }
    }
}

/* Removes BuiltIn::eDepth output if the render pass has no depth attachment (Metal rejects PSO mismatch). */
static void stripDepthOutput(dxbc_spv::ir::Builder &builder) {
    using namespace dxbc_spv::ir;
    SsaDef depthDecl = {};
    auto [da, db] = builder.getDeclarations();
    for (auto it = da; it != db; ++it) {
        if (it->getOpCode() == OpCode::eDclOutputBuiltIn &&
            BuiltIn(it->getOperand(it->getFirstLiteralOperandIndex())) == BuiltIn::eDepth) {
            depthDecl = it->getDef();
            break;
        }
    }
    if (!depthDecl) return;

    std::vector<SsaDef> toRemove;
    auto [ca, cb] = builder.getCode();
    for (auto it = ca; it != cb; ++it) {
        if (it->getOpCode() == OpCode::eOutputStore && SsaDef(it->getOperand(0u)) == depthDecl) {
            toRemove.push_back(it->getDef());
        }
    }
    for (auto d : toRemove) builder.remove(d);
    builder.remove(depthDecl);
    RemoveUnusedPass::runPass(builder);
}

static bool detectClipSpacePassthroughVs(
    const dxbc_spv::ir::Builder &builder,
    const std::vector<MtlVertexInputSemantic> &vsInputs) {
    using namespace dxbc_spv;
    int posLoc = -1;
    for (const auto &vis : vsInputs) {
        if (vis.usage == 0 && vis.usageIndex == 0) {
            posLoc = int(vis.location);
            break;
        }
    }
    if (posLoc < 0) return false;

    ir::SsaDef posDecl;
    auto [da, db] = builder.getDeclarations();
    for (auto it = da; it != db; ++it) {
        if (it->getOpCode() == ir::OpCode::eDclOutputBuiltIn &&
            ir::BuiltIn(it->getOperand(it->getFirstLiteralOperandIndex())) == ir::BuiltIn::ePosition) {
            posDecl = it->getDef();
            break;
        }
    }
    if (!posDecl) return false;

    auto isPosAttrComp = [&](ir::SsaDef valDef, uint32_t expectedComp) -> bool {
        const ir::Op &valOp = builder.getOp(valDef);
        if (valOp.getOpCode() != ir::OpCode::eInputLoad) return false;
        const ir::Op &inDecl = builder.getOpForOperand(valOp, 0u);
        if (inDecl.getOpCode() != ir::OpCode::eDclInput) return false;
        if (uint32_t(inDecl.getOperand(1u)) != uint32_t(posLoc)) return false;
        uint32_t comp = inDecl.getType().isScalarType()
            ? uint32_t(inDecl.getOperand(2u))
            : uint32_t(builder.getOpForOperand(valOp, 1u).getOperand(0u));
        return comp == expectedComp;
    };

    bool seenX = false, seenY = false;
    auto [ca, cb] = builder.getCode();
    for (auto it = ca; it != cb; ++it) {
        if (it->getOpCode() != ir::OpCode::eOutputStore ||
            ir::SsaDef(it->getOperand(0u)) != posDecl) {
            continue;
        }
        const ir::Op &addrOp = builder.getOpForOperand(*it, 1u);
        if (!addrOp.isConstant()) return false;
        uint32_t comp = uint32_t(addrOp.getOperand(0u));
        ir::SsaDef valDef(it->getOperand(2u));
        if (comp == 0u) {
            if (seenX || !isPosAttrComp(valDef, 0u)) return false;
            seenX = true;
        } else if (comp == 1u) {
            if (seenY || !isPosAttrComp(valDef, 1u)) return false;
            seenY = true;
        } else if (comp == 3u) {
            const ir::Op &wOp = builder.getOp(valDef);
            bool wOne = wOp.isConstant() && float(wOp.getOperand(0u)) == 1.0f;
            if (!wOne && !isPosAttrComp(valDef, 3u)) return false;
        }
    }
    return seenX && seenY;
}

static bool isHalfCandidateOpcode(dxbc_spv::ir::OpCode op) {
    namespace ir = dxbc_spv::ir;
    switch (op) {
        case ir::OpCode::eFAbs:
        case ir::OpCode::eFNeg:
        case ir::OpCode::eFAdd:
        case ir::OpCode::eFSub:
        case ir::OpCode::eFMul:
        case ir::OpCode::eFMulLegacy:
        case ir::OpCode::eFMad:
        case ir::OpCode::eFMadLegacy:
        case ir::OpCode::eFMin:
        case ir::OpCode::eFMax:
        case ir::OpCode::eFClamp:
        case ir::OpCode::eSelect:
        case ir::OpCode::ePhi:
            return true;
        default:
            return false;
    }
}

static bool isFragUnsafeMathSource(dxbc_spv::ir::OpCode op) {
    namespace ir = dxbc_spv::ir;
    switch (op) {
        case ir::OpCode::eFDiv:
        case ir::OpCode::eFRcp:
        case ir::OpCode::eFRsq:
        case ir::OpCode::eFSqrt:
        case ir::OpCode::eFExp2:
        case ir::OpCode::eFLog2:
        case ir::OpCode::eFLog2Legacy:
        case ir::OpCode::eFPow:
        case ir::OpCode::eFPowLegacy:
            return true;
        default:
            return false;
    }
}

/* Promotes safe fragment scalar color/blend ALU (and Phis) to FP16 (half) while keeping
 * UVs, depth, comparisons, transcendental/reciprocal math, and out-of-range constants in FP32. */
static void promoteFragmentHalfPass(dxbc_spv::ir::Builder &builder) {
    using namespace dxbc_spv;
    std::unordered_set<uint32_t> candidates;
    std::unordered_set<uint32_t> mustF32;
    std::vector<ir::SsaDef> worklist;

    auto markMustF32 = [&](ir::SsaDef def) {
        if (def && candidates.count(def.getId()) && mustF32.insert(def.getId()).second) {
            worklist.push_back(def);
        }
    };

    auto [ca, cb] = builder.getCode();
    for (auto it = ca; it != cb; ++it) {
        if (it->getType() != ir::Type(ir::ScalarType::eF32) || !isHalfCandidateOpcode(it->getOpCode())) {
            continue;
        }
        bool ok = true;
        uint32_t firstLit = it->getFirstLiteralOperandIndex();
        for (uint32_t i = 0u; i < firstLit; ++i) {
            if (it->getOpCode() == ir::OpCode::eSelect && i == 0u) continue;
            if (it->getOpCode() == ir::OpCode::ePhi && (i % 2u) == 0u) continue;
            ir::SsaDef argDef(it->getOperand(i));
            const ir::Op &argOp = builder.getOp(argDef);
            if (argOp.isConstant() && argOp.getType() == ir::Type(ir::ScalarType::eF32)) {
                float v = float(argOp.getOperand(0u));
                if (!std::isfinite(v) || std::fabs(v) > 512.0f || (v != 0.0f && std::fabs(v) < 1e-4f)) {
                    ok = false;
                    break;
                }
            } else if ((it->getOpCode() == ir::OpCode::eFMin ||
                        it->getOpCode() == ir::OpCode::eFMax ||
                        it->getOpCode() == ir::OpCode::eFClamp) &&
                       isFragUnsafeMathSource(argOp.getOpCode())) {
                /* Guard clamps on div/rsq/pow/log2 must execute in FP32 */
                ok = false;
                break;
            }
        }
        if (ok) {
            candidates.insert(it->getDef().getId());
        }
    }
    if (candidates.empty()) return;

    for (auto it = ca; it != cb; ++it) {
        if (candidates.count(it->getDef().getId())) continue;
        ir::OpCode opc = it->getOpCode();
        if (opc == ir::OpCode::eConvertFtoF && it->getType() == ir::Type(ir::ScalarType::eF16)) {
            continue;
        }
        bool isColorOutputStore = (opc == ir::OpCode::eOutputStore &&
            builder.getOpForOperand(*it, 0u).getOpCode() == ir::OpCode::eDclOutput);
        uint32_t firstLit = it->getFirstLiteralOperandIndex();
        for (uint32_t i = 0u; i < firstLit; ++i) {
            if (isColorOutputStore && i == 2u) continue;
            markMustF32(ir::SsaDef(it->getOperand(i)));
        }
    }

    auto drainWorklist = [&]() {
        while (!worklist.empty()) {
            ir::SsaDef cur = worklist.back();
            worklist.pop_back();
            const ir::Op &curOp = builder.getOp(cur);
            uint32_t firstLit = curOp.getFirstLiteralOperandIndex();
            for (uint32_t i = 0u; i < firstLit; ++i) {
                if (curOp.getOpCode() == ir::OpCode::eSelect && i == 0u) continue;
                if (curOp.getOpCode() == ir::OpCode::ePhi && (i % 2u) == 0u) continue;
                markMustF32(ir::SsaDef(curOp.getOperand(i)));
            }
        }
    };
    drainWorklist();

    /* Ensure no promoted Phi mixes unpromoted F32 inputs and no promoted op feeds an unpromoted Phi */
    std::vector<ir::SsaDef> phiDefs;
    for (auto it = ca; it != cb; ++it) {
        if (it->getOpCode() == ir::OpCode::ePhi && candidates.count(it->getDef().getId())) {
            phiDefs.push_back(it->getDef());
        }
    }
    bool changed = !phiDefs.empty();
    while (changed) {
        changed = false;
        for (ir::SsaDef pDef : phiDefs) {
            const ir::Op &pOp = builder.getOp(pDef);
            uint32_t firstLit = pOp.getFirstLiteralOperandIndex();
            if (!mustF32.count(pDef.getId())) {
                for (uint32_t i = 1u; i < firstLit; i += 2u) {
                    ir::SsaDef argDef(pOp.getOperand(i));
                    const ir::Op &argOp = builder.getOp(argDef);
                    if (!argOp.isConstant() && !argOp.isUndef() &&
                        argOp.getType() != ir::Type(ir::ScalarType::eF16) &&
                        (!candidates.count(argDef.getId()) || mustF32.count(argDef.getId()))) {
                        markMustF32(pDef);
                        changed = true;
                        break;
                    }
                }
            }
            if (mustF32.count(pDef.getId())) {
                for (uint32_t i = 1u; i < firstLit; i += 2u) {
                    ir::SsaDef argDef(pOp.getOperand(i));
                    if (candidates.count(argDef.getId()) && !mustF32.count(argDef.getId())) {
                        markMustF32(argDef);
                        changed = true;
                    }
                }
            }
        }
        drainWorklist();
    }

    std::vector<ir::SsaDef> promotedOps;
    std::unordered_set<uint32_t> promotedSet;
    for (auto it = ca; it != cb; ++it) {
        uint32_t id = it->getDef().getId();
        if (candidates.count(id) && !mustF32.count(id)) {
            promotedOps.push_back(it->getDef());
            promotedSet.insert(id);
        }
    }
    if (promotedOps.empty()) return;

    for (ir::SsaDef def : promotedOps) {
        ir::Op oldOp = builder.getOp(def);
        ir::Op newOp(oldOp.getOpCode(), ir::Type(ir::ScalarType::eF16));
        newOp.setFlags(oldOp.getFlags());
        uint32_t firstLit = oldOp.getFirstLiteralOperandIndex();
        for (uint32_t i = 0u; i < firstLit; ++i) {
            ir::SsaDef argDef(oldOp.getOperand(i));
            bool passthrough = (oldOp.getOpCode() == ir::OpCode::eSelect && i == 0u) ||
                               (oldOp.getOpCode() == ir::OpCode::ePhi && (i % 2u) == 0u);
            if (!passthrough) {
                const ir::Op &argOp = builder.getOp(argDef);
                if (argOp.isConstant() && argOp.getType() == ir::Type(ir::ScalarType::eF32)) {
                    argDef = builder.makeConstant(ir::float16_t(float(argOp.getOperand(0u))));
                } else if (argOp.isUndef() && argOp.getType() == ir::Type(ir::ScalarType::eF32)) {
                    argDef = builder.makeUndef(ir::ScalarType(ir::ScalarType::eF16));
                } else if (argOp.getType() != ir::Type(ir::ScalarType::eF16) &&
                           !promotedSet.count(argDef.getId())) {
                    argDef = builder.addBefore(def, ir::Op::ConvertFtoF(ir::ScalarType::eF16, argDef));
                }
            }
            newOp.addOperand(argDef);
        }
        for (uint32_t i = firstLit; i < oldOp.getOperandCount(); ++i) {
            newOp.addOperand(oldOp.getOperand(i));
        }
        builder.rewriteOp(def, std::move(newOp));
    }

    std::vector<ir::SsaDef> users;
    for (ir::SsaDef def : promotedOps) {
        users.clear();
        builder.getUses(def, users);
        std::sort(users.begin(), users.end());
        users.erase(std::unique(users.begin(), users.end()), users.end());
        for (ir::SsaDef uDef : users) {
            if (promotedSet.count(uDef.getId())) continue;
            ir::Op uOp = builder.getOp(uDef);
            if (uOp.getOpCode() == ir::OpCode::eConvertFtoF &&
                uOp.getType() == ir::Type(ir::ScalarType::eF16)) {
                builder.rewriteDef(uDef, def);
                continue;
            }
            ir::SsaDef up = builder.addBefore(uDef, ir::Op::ConvertFtoF(ir::ScalarType::eF32, def));
            ir::Op newU(uOp.getOpCode(), uOp.getType());
            newU.setFlags(uOp.getFlags());
            uint32_t firstLit = uOp.getFirstLiteralOperandIndex();
            for (uint32_t i = 0u; i < firstLit; ++i) {
                ir::SsaDef argDef(uOp.getOperand(i));
                newU.addOperand(argDef == def ? up : argDef);
            }
            for (uint32_t i = firstLit; i < uOp.getOperandCount(); ++i) {
                newU.addOperand(uOp.getOperand(i));
            }
            builder.rewriteOp(uDef, std::move(newU));
        }
    }
}

/* Folds AlphaTest (when disabled), PointSprite mode, and static SamplerState flags directly into
   IR constants so Metal gets branchless texture sampling, no gl_PointCoord selects, and clean Early-Z. */
static void specializePsBuiltIns(
    dxbc_spv::ir::Builder &builder,
    bool alphaTestEnable,
    bool pointSpriteEnable,
    uint16_t depthCmpMask,
    uint16_t nullMask,
    uint16_t projMask,
    uint16_t gatherMask) {
    using namespace dxbc_spv::ir;

    SsaDef alphaTestDecl = {};
    SsaDef pointArgsDecl = {};
    SsaDef sampStateDecl = {};
    MtlSamplerTexKind sampKinds[16] = {};

    auto [da, db] = builder.getDeclarations();
    for (auto it = da; it != db; ++it) {
        if (it->getOpCode() == OpCode::eDclInputBuiltIn) {
            auto bi = BuiltIn(it->getOperand(it->getFirstLiteralOperandIndex()));
            if (bi == BuiltIn::eLegacyAlphaTest)    alphaTestDecl = it->getDef();
            if (bi == BuiltIn::eLegacyPointArgs)    pointArgsDecl = it->getDef();
            if (bi == BuiltIn::eLegacySamplerState) sampStateDecl = it->getDef();
        } else if (it->getOpCode() == OpCode::eDclSrv) {
            uint32_t regIdx = uint32_t(it->getOperand(2u));
            auto kind = ResourceKind(it->getOperand(4u));
            if (regIdx < 16u) {
                if (kind == ResourceKind::eImage3D)        sampKinds[regIdx] = MtlSamplerTexKind::Tex3D;
                else if (kind == ResourceKind::eImageCube) sampKinds[regIdx] = MtlSamplerTexKind::TexCube;
                else                                       sampKinds[regIdx] = MtlSamplerTexKind::Tex2D;
            }
        }
    }

    if (!alphaTestEnable && alphaTestDecl) {
        dxbc_spv::util::small_vector<SsaDef, 16u> uses;
        builder.getUses(alphaTestDecl, uses);
        SsaDef alphaTestFn = {};
        for (SsaDef u : uses) {
            const auto &op = builder.getOp(u);
            if (op.getOpCode() != OpCode::eInputLoad) continue;
            if (!alphaTestFn) {
                /* Find enclosing alphaTest helper so we can fold its call site(s) directly to true */
                auto iter = builder.iter(u);
                while (iter != builder.begin()) {
                    --iter;
                    if (iter->getOpCode() == OpCode::eFunction) {
                        if (iter->getType().getBaseType(0u) == BasicType(ScalarType::eBool)) {
                            alphaTestFn = iter->getDef();
                        }
                        break;
                    }
                }
            }
            SsaDef addr = SsaDef(op.getOperand(1u));
            if (!addr) continue;
            const auto &addrOp = builder.getOp(addr);
            if (addrOp.getOpCode() == OpCode::eConstant &&
                uint32_t(addrOp.getOperand(0u)) == uint32_t(LegacyAlphaTestLayout::eAlphaCompareOp)) {
                builder.rewriteDef(u, builder.makeConstant(7u)); /* AlphaTestComparisonMode::eAlways */
            }
        }
        if (alphaTestFn) {
            dxbc_spv::util::small_vector<SsaDef, 8u> fnUses;
            builder.getUses(alphaTestFn, fnUses);
            for (SsaDef u : fnUses) {
                const auto &op = builder.getOp(u);
                if (op.getOpCode() == OpCode::eFunctionCall && SsaDef(op.getOperand(0u)) == alphaTestFn) {
                    builder.rewriteDef(u, builder.makeConstant(true));
                }
            }
        }
    }

    if (pointArgsDecl) {
        dxbc_spv::util::small_vector<SsaDef, 16u> uses;
        builder.getUses(pointArgsDecl, uses);
        for (SsaDef u : uses) {
            const auto &op = builder.getOp(u);
            if (op.getOpCode() != OpCode::eInputLoad) continue;
            SsaDef addr = SsaDef(op.getOperand(1u));
            if (!addr) continue;
            const auto &addrOp = builder.getOp(addr);
            if (addrOp.getOpCode() == OpCode::eConstant &&
                uint32_t(addrOp.getOperand(0u)) == uint32_t(LegacyPointArgsLayout::eIsPointSprite)) {
                builder.rewriteDef(u, builder.makeConstant(pointSpriteEnable));
            }
        }
    }

    if (sampStateDecl) {
        dxbc_spv::util::small_vector<SsaDef, 64u> uses;
        builder.getUses(sampStateDecl, uses);
        for (SsaDef u : uses) {
            const auto &op = builder.getOp(u);
            if (op.getOpCode() != OpCode::eInputLoad) continue;
            SsaDef addr = SsaDef(op.getOperand(1u));
            if (!addr) continue;
            const auto &addrOp = builder.getOp(addr);
            if (addrOp.getOpCode() != OpCode::eConstant ||
                addrOp.getType().computeFlattenedScalarCount() != 2u) {
                continue;
            }
            uint32_t s = uint32_t(addrOp.getOperand(0u));
            uint32_t m = uint32_t(addrOp.getOperand(1u));
            if (s >= 16u) continue;
            uint16_t bit = uint16_t(1u << s);
            switch (LegacySamplerStateLayout(m)) {
                case LegacySamplerStateLayout::eTextureType:
                    builder.rewriteDef(u, builder.makeConstant(uint32_t(sampKinds[s])));
                    break;
                case LegacySamplerStateLayout::eUseDepthCompare:
                    builder.rewriteDef(u, builder.makeConstant(uint32_t((depthCmpMask & bit) ? 1u : 0u)));
                    break;
                case LegacySamplerStateLayout::eUseProjection:
                    builder.rewriteDef(u, builder.makeConstant(uint32_t((projMask & bit) ? 1u : 0u)));
                    break;
                case LegacySamplerStateLayout::eIsNull:
                    builder.rewriteDef(u, builder.makeConstant(uint32_t((nullMask & bit) ? 1u : 0u)));
                    break;
                case LegacySamplerStateLayout::eUseGather:
                    builder.rewriteDef(u, builder.makeConstant(uint32_t((gatherMask & bit) ? 1u : 0u)));
                    break;
                case LegacySamplerStateLayout::eDrefClamp:
                    builder.rewriteDef(u, builder.makeConstant(1u));
                    break;
                case LegacySamplerStateLayout::eDrefScale:
                    builder.rewriteDef(u, builder.makeConstant(1.0f));
                    break;
                default:
                    break;
            }
        }
    }
}

/* Shrinks static LegacyConstFloat array declarations to the highest referenced float4 register + 1
   so Metal shaders declare compact structs and CPU uploads/binds only active registers. */
static void shrinkConstFloatDecl(dxbc_spv::ir::Builder &builder) {
    using namespace dxbc_spv::ir;

    SsaDef cfDecl = {};
    auto [da, db] = builder.getDeclarations();
    for (auto it = da; it != db; ++it) {
        if (it->getOpCode() == OpCode::eDclInputBuiltIn &&
            BuiltIn(it->getOperand(it->getFirstLiteralOperandIndex())) == BuiltIn::eLegacyConstFloat) {
            cfDecl = it->getDef();
            break;
        }
    }
    if (!cfDecl) return;

    const Op &declOp = builder.getOp(cfDecl);
    Type oldType = declOp.getType();
    if (oldType.getArrayDimensions() != 1u) return;
    uint32_t fullCount = oldType.getArraySize(0u);

    uint32_t maxIdx = 0u;
    bool hasAnyUse = false;
    bool hasDynamic = false;

    dxbc_spv::util::small_vector<SsaDef, 64u> uses;
    builder.getUses(cfDecl, uses);
    for (SsaDef u : uses) {
        const auto &op = builder.getOp(u);
        if (op.getOpCode() != OpCode::eInputLoad) continue;
        hasAnyUse = true;
        SsaDef addr = SsaDef(op.getOperand(1u));
        if (!addr) continue;
        const auto &addrOp = builder.getOp(addr);
        if (addrOp.getOpCode() == OpCode::eConstant) {
            maxIdx = std::max(maxIdx, uint32_t(addrOp.getOperand(0u)));
        } else if (addrOp.getOpCode() == OpCode::eCompositeConstruct) {
            const auto &firstOp = builder.getOp(SsaDef(addrOp.getOperand(0u)));
            if (firstOp.getOpCode() == OpCode::eConstant) {
                maxIdx = std::max(maxIdx, uint32_t(firstOp.getOperand(0u)));
            } else {
                hasDynamic = true;
                break;
            }
        } else {
            hasDynamic = true;
            break;
        }
    }

    if (!hasDynamic && hasAnyUse && maxIdx + 1u < fullCount) {
        Type newType(oldType.getBaseType(0u));
        newType.addArrayDimension(maxIdx + 1u);
        builder.rewriteOp(cfDecl, Op(declOp).setType(newType));
    }
}

static bool useSafeMath() {
    static int cached = -1;
    if (cached < 0) {
        const char *e = getenv("ME_PC_SAFE_MATH");
        cached = (e && *e == '1') ? 1 : 0;
    }
    return cached != 0;
}

static bool compileMslToLibrary(id<MTLDevice> device, const std::string &msl, MtlCompiledShader &out,
                                bool notifyStallHook) {
    @autoreleasepool {
        const bool safeMath = useSafeMath();
        NSError *err = nil;
        MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
        opts.languageVersion = MTLLanguageVersion2_4;
        opts.preserveInvariance = YES;
        if (@available(macOS 15.0, *)) {
            opts.mathMode = safeMath ? MTLMathModeSafe : MTLMathModeFast;
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            opts.fastMathEnabled = safeMath ? NO : YES;
#pragma clang diagnostic pop
        }
        NSString *src = [NSString stringWithUTF8String:msl.c_str()];
        auto hook = notifyStallHook ? gStallHook.load(std::memory_order_acquire) : nullptr;
        if (hook) hook(1);
        id<MTLLibrary> lib = [device newLibraryWithSource:src options:opts error:&err];
        if (hook) hook(0);
        if (!lib) {
            fprintf(stderr, "RunnerMetal: Metal shader compile failed: %s\n",
                    err ? [[err localizedDescription] UTF8String] : "unknown error");
            return false;
        }
        id<MTLFunction> fn = [lib newFunctionWithName:@"main0"];
        if (!fn) {
            NSArray<NSString *> *names = [lib functionNames];
            if (names.count > 0) {
                fn = [lib newFunctionWithName:names[0]];
            }
        }
        if (!fn) {
            fprintf(stderr, "RunnerMetal: compiled MTLLibrary has no entry function\n");
            return false;
        }
        out.library = lib;
        out.function = fn;
        out.mslSource = msl;
        return true;
    }
}

} // anonymous namespace

struct MtlParsedShader::Impl {
    dxbc_spv::ir::IoMap vsOutMap;
    dxbc_spv::ir::IoMap psInMap;
    std::mutex variantsMu;
};

static inline uint64_t shaderMemKey(uint64_t hash, bool isVertex) {
    return hash ^ (isVertex ? 0x9e3779b97f4a7c15ull : 0ull);
}

struct IrDiskHeader {
    uint32_t magic;
    uint32_t isVertex : 1;
    uint32_t vsClipSpacePos : 1;
    uint32_t psUsesDiscard : 1;
    uint32_t psHasTexkill : 1;
    uint32_t psWritesDepth : 1;
    uint32_t vsInputCount : 8;
    uint32_t psDeclaredSamplerMask : 16;
    uint8_t  psDeclaredSamplerKind[16];
    uint64_t bytecodeHash;
    uint64_t vsOutputIoHash;
    uint32_t serializedIrBytes;
};

static uint32_t expectedIrMagic() {
    return useSafeMath() ? 0x4D49523Au : 0x4D495239u;
}

static const char *expectedMslMetaTag(bool emuDref) {
    return useSafeMath() ? (emuDref ? "// MTLMETA9SE " : "// MTLMETA9S ")
                         : (emuDref ? "// MTLMETA9E "  : "// MTLMETA9 ");
}

static std::shared_ptr<MtlParsedShader> loadParsedShaderFromDisk(
    const std::string &path, bool expectedVert, uint64_t expectedHash) {
    std::ifstream ifs(path, std::ios::binary);
    if (!ifs.good()) return nullptr;
    IrDiskHeader hdr = {};
    if (!ifs.read(reinterpret_cast<char *>(&hdr), sizeof(hdr))) return nullptr;
    if (hdr.magic != expectedIrMagic() ||
        bool(hdr.isVertex) != expectedVert ||
        hdr.bytecodeHash != expectedHash ||
        hdr.vsInputCount > 64u ||
        hdr.serializedIrBytes == 0u || hdr.serializedIrBytes > (16u << 20)) {
        return nullptr;
    }

    auto parsed = std::make_shared<MtlParsedShader>();
    parsed->isVertex = expectedVert;
    parsed->bytecodeHash = hdr.bytecodeHash;
    parsed->vsOutputIoHash = hdr.vsOutputIoHash;
    parsed->vsClipSpacePos = (hdr.vsClipSpacePos != 0);
    parsed->psUsesDiscard = (hdr.psUsesDiscard != 0);
    parsed->psHasTexkill = (hdr.psHasTexkill != 0);
    parsed->psWritesDepth = (hdr.psWritesDepth != 0);
    parsed->psDeclaredSamplerMask = uint16_t(hdr.psDeclaredSamplerMask);
    for (int i = 0; i < 16; i++) {
        parsed->psDeclaredSamplerKind[i] = static_cast<MtlSamplerTexKind>(hdr.psDeclaredSamplerKind[i]);
    }
    if (hdr.vsInputCount > 0u) {
        parsed->vsInputs.resize(hdr.vsInputCount);
        if (!ifs.read(reinterpret_cast<char *>(parsed->vsInputs.data()),
                      std::streamsize(hdr.vsInputCount * sizeof(MtlVertexInputSemantic)))) {
            return nullptr;
        }
    }
    parsed->serializedIr.resize(hdr.serializedIrBytes);
    if (!ifs.read(reinterpret_cast<char *>(parsed->serializedIr.data()),
                  std::streamsize(hdr.serializedIrBytes))) {
        return nullptr;
    }

    dxbc_spv::ir::Builder builder;
    dxbc_spv::ir::Deserializer deser(parsed->serializedIr.data(), parsed->serializedIr.size());
    if (!deser.deserialize(builder)) return nullptr;
    if (expectedVert) {
        parsed->impl->vsOutMap = dxbc_spv::ir::IoMap::forOutputs(builder, 0u);
    } else {
        parsed->impl->psInMap = dxbc_spv::ir::IoMap::forInputs(builder);
    }
    return parsed;
}

static void saveParsedShaderToDisk(const std::string &path, const MtlParsedShader &parsed) {
    if (parsed.serializedIr.empty() || parsed.vsInputs.size() > 64u) return;
    IrDiskHeader hdr = {};
    hdr.magic                 = expectedIrMagic();
    hdr.isVertex              = parsed.isVertex ? 1u : 0u;
    hdr.vsClipSpacePos        = parsed.vsClipSpacePos ? 1u : 0u;
    hdr.psUsesDiscard         = parsed.psUsesDiscard ? 1u : 0u;
    hdr.psHasTexkill          = parsed.psHasTexkill ? 1u : 0u;
    hdr.psWritesDepth         = parsed.psWritesDepth ? 1u : 0u;
    hdr.vsInputCount          = uint32_t(parsed.vsInputs.size());
    hdr.psDeclaredSamplerMask = parsed.psDeclaredSamplerMask;
    for (int i = 0; i < 16; i++) {
        hdr.psDeclaredSamplerKind[i] = uint8_t(parsed.psDeclaredSamplerKind[i]);
    }
    hdr.bytecodeHash      = parsed.bytecodeHash;
    hdr.vsOutputIoHash    = parsed.vsOutputIoHash;
    hdr.serializedIrBytes = uint32_t(parsed.serializedIr.size());

    std::string tmpPath = path + ".tmp";
    {
        std::ofstream ofs(tmpPath, std::ios::binary | std::ios::trunc);
        if (!ofs.good()) return;
        ofs.write(reinterpret_cast<const char *>(&hdr), sizeof(hdr));
        if (!parsed.vsInputs.empty()) {
            ofs.write(reinterpret_cast<const char *>(parsed.vsInputs.data()),
                      std::streamsize(parsed.vsInputs.size() * sizeof(MtlVertexInputSemantic)));
        }
        ofs.write(reinterpret_cast<const char *>(parsed.serializedIr.data()),
                  std::streamsize(parsed.serializedIr.size()));
        if (!ofs.good()) return;
    }
    std::rename(tmpPath.c_str(), path.c_str());
}

static bool parseCachedMslMetadata(const std::string &firstLine, const char *metaTag, MtlCompiledShader &out) {
    if (firstLine.rfind(metaTag, 0) != 0) return false;
    uint32_t cbvMask = 0, sampMask = 0, writesDepth = 0, colorMask = 0, kindsPacked = 0, cfVecs = 0, usesDiscard = 0;
    if (sscanf(firstLine.c_str() + std::strlen(metaTag), "%x %x %u %x %x %u %u",
               &cbvMask, &sampMask, &writesDepth, &colorMask, &kindsPacked, &cfVecs, &usesDiscard) != 7) {
        return false;
    }
    out.usedCbvMask        = cbvMask;
    out.usedSamplerMask    = sampMask;
    out.constFloatVecCount = uint16_t(cfVecs);
    out.writesDepth        = (writesDepth != 0);
    out.usesDiscard        = (usesDiscard != 0);
    out.colorOutputMask    = uint8_t(colorMask);
    for (int i = 0; i < 16; i++) {
        out.samplerKind[i] = static_cast<MtlSamplerTexKind>((kindsPacked >> (i * 2)) & 3u);
    }
    return true;
}

MtlParsedShader::MtlParsedShader() : impl(std::make_unique<Impl>()) {}
MtlParsedShader::~MtlParsedShader() = default;

MtlShaderCompiler::MtlShaderCompiler(id<MTLDevice> device)
    : device_(device) {
    const char *envCache = getenv("ME_PC_SHADER_CACHE");
    cacheDir_ = (envCache && *envCache) ? envCache : "work/metal_shader_cache";
    mkdir("work", 0755);
    mkdir(cacheDir_.c_str(), 0755);

    /* Background async pre-warm of previously cached .msl libraries so cold gameplay draws hit RAM */
    prewarmThread_ = std::thread([this]() {
        DIR *dir = opendir(cacheDir_.c_str());
        if (!dir) return;
        auto tPre = std::chrono::steady_clock::now();
        uint32_t preCount = 0;
        uint32_t irPreCount = 0;
        static const bool emuDref = ([] { const char *e = getenv("ME_PC_EMULATE_DREF"); return e && *e == '1'; })();
        const char *metaTag = expectedMslMetaTag(emuDref);
        const char *irExt = emuDref ? ".ir8e" : ".ir8";
        const size_t irExtLen = strlen(irExt);
        std::vector<std::string> irFiles;
        struct dirent *ent = nullptr;
        while (!stopPrewarm_.load(std::memory_order_relaxed) && (ent = readdir(dir)) != nullptr) {
            const char *name = ent->d_name;
            size_t len = strlen(name);
            if (len > 3 + irExtLen && strcmp(name + len - irExtLen, irExt) == 0 &&
                (strncmp(name, "vs_", 3) == 0 || strncmp(name, "ps_", 3) == 0)) {
                irFiles.emplace_back(name);
                continue;
            }
            bool isVert = false;
            if (strncmp(name, "vs_", 3) == 0) isVert = true;
            else if (strncmp(name, "ps_", 3) == 0) isVert = false;
            else continue;

            if (len < 8 || strcmp(name + len - 4, ".msl") != 0) continue;

            char *endp = nullptr;
            uint64_t h = strtoull(name + 3, &endp, 16);
            if (!endp || strcmp(endp, ".msl") != 0) continue;

            uint64_t memKey = shaderMemKey(h, isVert);
            {
                std::lock_guard<std::mutex> lk(libCacheMu_);
                if (prewarmedLibs_.find(memKey) != prewarmedLibs_.end()) continue;
            }

            std::string fullPath = cacheDir_ + "/" + name;
            std::ifstream ifs(fullPath);
            if (!ifs.good()) continue;
            std::string firstLine;
            if (!std::getline(ifs, firstLine)) continue;

            MtlCompiledShader out = {};
            out.shaderHash = h;
            if (!parseCachedMslMetadata(firstLine, metaTag, out)) continue;

            std::stringstream ss;
            ss << ifs.rdbuf();
            std::string cachedMsl = ss.str();
            if (cachedMsl.empty()) continue;

            if (compileMslToLibrary(device_, cachedMsl, out, false)) {
                preCount++;
                std::lock_guard<std::mutex> lk(libCacheMu_);
                prewarmedLibs_.emplace(memKey, std::move(out));
            }
        }
        closedir(dir);

        for (const std::string &name : irFiles) {
            if (stopPrewarm_.load(std::memory_order_relaxed)) break;
            bool isVert = (strncmp(name.c_str(), "vs_", 3) == 0);
            char *endp = nullptr;
            uint64_t h = strtoull(name.c_str() + 3, &endp, 16);
            if (!endp || strcmp(endp, irExt) != 0) continue;
            uint64_t memKey = shaderMemKey(h, isVert);
            {
                std::lock_guard<std::mutex> lk(parsedCacheMu_);
                if (parsedCache_.find(memKey) != parsedCache_.end()) continue;
            }
            auto parsed = loadParsedShaderFromDisk(cacheDir_ + "/" + name, isVert, h);
            if (!parsed) continue;
            if (isVert) {
                std::lock_guard<std::mutex> lk(libCacheMu_);
                auto it = prewarmedLibs_.find(memKey);
                if (it != prewarmedLibs_.end()) {
                    parsed->defaultCompiled = it->second;
                }
            }
            std::lock_guard<std::mutex> lk(parsedCacheMu_);
            if (parsedCache_.emplace(memKey, std::move(parsed)).second) {
                irPreCount++;
            }
        }
        if (getenv("ME_PC_LOG_STALLS") && *getenv("ME_PC_LOG_STALLS") == '1') {
            double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - tPre).count();
            fprintf(stderr, "STALL_LOG: prewarm %u msl + %u ir in %.1f ms\n", preCount, irPreCount, ms);
        }
    });
}

MtlShaderCompiler::~MtlShaderCompiler() {
    stopPrewarm_.store(true, std::memory_order_relaxed);
    if (prewarmThread_.joinable()) {
        prewarmThread_.join();
    }
}

static size_t measureBytecodeDwordsImpl(const uint32_t *tokens, bool *outHasTexkill) {
    if (outHasTexkill) *outHasTexkill = false;
    if (!tokens) return 0;
    uint32_t ver = tokens[0];
    uint32_t major = (ver >> 8) & 0xFFu;
    size_t i = 1;
    while (i < 65536) {
        uint32_t tok = tokens[i];
        uint32_t op = tok & 0xFFFFu;
        if (op == 0xFFFFu) { /* D3DSIO_END */
            return i + 1;
        }
        if (op == 0xFFFEu) { /* D3DSIO_COMMENT */
            uint32_t commentLen = (tok >> 16) & 0x7FFFu;
            i += 1 + commentLen;
            continue;
        }
        if (op == 0x0041u /* D3DSIO_TEXKILL */ && outHasTexkill) {
            *outHasTexkill = true;
        }
        if (major >= 2) {
            uint32_t instLen = (tok >> 24) & 0x0Fu;
            i += 1 + instLen;
        } else {
            /* SM 1.x: step 1 and skip operand tokens (bit 31 set) */
            i++;
            while (i < 65536 && (tokens[i] & 0x80000000u)) i++;
        }
    }
    return i;
}

size_t MtlShaderCompiler::measureBytecodeDwords(const uint32_t *tokens) {
    return measureBytecodeDwordsImpl(tokens, nullptr);
}

std::shared_ptr<MtlParsedShader> MtlShaderCompiler::compileFromBytecode(const uint32_t *tokens, bool isVertex) {
    bool hasTexkill = false;
    size_t count = measureBytecodeDwordsImpl(tokens, &hasTexkill);
    if (count < 2) return nullptr;

    uint64_t bytecodeHash = fnv1a64(tokens, count * sizeof(uint32_t));
    uint64_t memKey = shaderMemKey(bytecodeHash, isVertex);
    {
        std::lock_guard<std::mutex> lk(parsedCacheMu_);
        auto it = parsedCache_.find(memKey);
        if (it != parsedCache_.end()) {
            if (it->second->rawBytecode.empty()) {
                it->second->rawBytecode.assign(tokens, tokens + count);
            }
            if (isVertex && !it->second->defaultCompiled.function) {
                lowerAndCompileToMetal(it->second->serializedIr, true, it->second->bytecodeHash,
                                       nullptr, 0xFu, true, false, false, false, 0, 0, 0, 0,
                                       it->second->defaultCompiled);
            }
            return it->second;
        }
    }

    static const bool emuDref = ([] { const char *e = getenv("ME_PC_EMULATE_DREF"); return e && *e == '1'; })();
    char irPath[512];
    snprintf(irPath, sizeof(irPath), "%s/%s_%016llx%s",
             cacheDir_.c_str(), isVertex ? "vs" : "ps", (unsigned long long)bytecodeHash,
             emuDref ? ".ir8e" : ".ir8");
    if (auto diskParsed = loadParsedShaderFromDisk(irPath, isVertex, bytecodeHash)) {
        diskParsed->rawBytecode.assign(tokens, tokens + count);
        if (isVertex) {
            if (!lowerAndCompileToMetal(diskParsed->serializedIr, true, diskParsed->bytecodeHash,
                                        nullptr, 0xFu, true, false, false, false, 0, 0, 0, 0,
                                        diskParsed->defaultCompiled)) {
                return nullptr;
            }
        }
        std::lock_guard<std::mutex> lk(parsedCacheMu_);
        auto [it, ok] = parsedCache_.emplace(memKey, std::move(diskParsed));
        return it->second;
    }

    static bool logStalls = (getenv("ME_PC_LOG_STALLS") && *getenv("ME_PC_LOG_STALLS") == '1');
    auto tParseStart = logStalls ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point{};

    auto parsed = std::make_shared<MtlParsedShader>();
    parsed->isVertex = isVertex;
    parsed->psHasTexkill = !isVertex && hasTexkill;
    parsed->rawBytecode.assign(tokens, tokens + count);
    parsed->bytecodeHash = bytecodeHash;

    MtlDxbcLogger logger;

    dxbc_spv::ir::Builder builder;
    dxbc_spv::util::ByteReader reader(tokens, count * sizeof(uint32_t));

    dxbc_spv::sm3::Converter::Options opts = {};
    opts.name = "main0";
    opts.includeDebugNames = false;
    opts.isSWVP = false;
    opts.fastFloatEmulation = !useSafeMath();
    opts.forceDynamicTextureType = false;
    opts.emulateDepthCompare = emuDref; /* Hardware depth2d::sample_compare by default; override via ME_PC_EMULATE_DREF=1 */

    dxbc_spv::sm3::Converter converter(reader, opts);
    if (!converter.convertShader(builder)) {
        fprintf(stderr, "RunnerMetal: sm3::Converter failed for %s #%016llx\n",
                isVertex ? "VS" : "PS", (unsigned long long)parsed->bytecodeHash);
        return nullptr;
    }

    dxbc_spv::ir::CompileOptions compileOpts = {};
    /* Desktop D3D9 ignores SM3 _pp partial precision; lowering eMinF16 to FP16 overflows
     * dot(L, L) above 65504 (~255.94 cm) on normalizations, zeroing point lighting. */
    compileOpts.min16Options.enableFloat16 = false;
    compileOpts.cseOptions.relocateDescriptorLoad = true;
    compileOpts.descriptorIndexing.optimizeDescriptorIndexing = true;
    dxbc_spv::ir::legalizeIr(builder, compileOpts);

    if (isVertex) {
        auto inMap = dxbc_spv::ir::IoMap::forInputs(builder);
        for (uint32_t i = 0; i < inMap.getCount(); i++) {
            auto loc = inMap.get(i);
            if (loc.getType() != dxbc_spv::ir::IoEntryType::ePerVertex) continue;
            auto sem = inMap.getSemanticForEntry(loc);
            MtlVertexInputSemantic vis = {};
            vis.location = loc.getLocationIndex();
            vis.usage = sem ? parseD3dUsageName(sem.name) : 0;
            vis.usageIndex = sem ? uint8_t(sem.index) : 0;
            parsed->vsInputs.push_back(vis);
        }
        parsed->impl->vsOutMap = dxbc_spv::ir::IoMap::forOutputs(builder, 0u);
        parsed->vsOutputIoHash = hashIoMap(parsed->impl->vsOutMap);
        parsed->vsClipSpacePos = detectClipSpacePassthroughVs(builder, parsed->vsInputs);
    } else {
        parsed->impl->psInMap = dxbc_spv::ir::IoMap::forInputs(builder);
        auto [da, db] = builder.getDeclarations();
        for (auto it = da; it != db; ++it) {
            if (it->getOpCode() == dxbc_spv::ir::OpCode::eDclSrv) {
                uint32_t regIdx = uint32_t(it->getOperand(2u));
                auto kind = dxbc_spv::ir::ResourceKind(it->getOperand(4u));
                if (regIdx < 16u) {
                    parsed->psDeclaredSamplerMask |= uint16_t(1u << regIdx);
                    if (kind == dxbc_spv::ir::ResourceKind::eImageCube) parsed->psDeclaredSamplerKind[regIdx] = MtlSamplerTexKind::TexCube;
                    else if (kind == dxbc_spv::ir::ResourceKind::eImage3D) parsed->psDeclaredSamplerKind[regIdx] = MtlSamplerTexKind::Tex3D;
                    else parsed->psDeclaredSamplerKind[regIdx] = MtlSamplerTexKind::Tex2D;
                }
            } else if (it->getOpCode() == dxbc_spv::ir::OpCode::eDclOutputBuiltIn &&
                       dxbc_spv::ir::BuiltIn(it->getOperand(it->getFirstLiteralOperandIndex())) == dxbc_spv::ir::BuiltIn::eDepth) {
                parsed->psWritesDepth = true;
            }
        }
        auto [ca, cb] = builder.getCode();
        for (auto it = ca; it != cb; ++it) {
            if (it->getOpCode() == dxbc_spv::ir::OpCode::eDemote) {
                parsed->psUsesDiscard = true;
                break;
            }
        }
    }

    /* Serialize legalized IR so PS variants (or VS compile) can be lowered cleanly */
    dxbc_spv::ir::Serializer serializer(builder);
    parsed->serializedIr.resize(serializer.computeSerializedSize());
    if (!serializer.serialize(parsed->serializedIr.data(), parsed->serializedIr.size())) {
        fprintf(stderr, "RunnerMetal: ir::Serializer failed\n");
        return nullptr;
    }

    saveParsedShaderToDisk(irPath, *parsed);

    if (isVertex) {
        if (!lowerAndCompileToMetal(parsed->serializedIr, true, parsed->bytecodeHash,
                                    nullptr, 0xFu, true, false, false, false, 0, 0, 0, 0, parsed->defaultCompiled)) {
            return nullptr;
        }
    }

    if (logStalls) {
        double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - tParseStart).count();
        if (ms > 2.0) {
            fprintf(stderr, "STALL_LOG: compileFromBytecode %s #%016llx %.2f ms\n",
                    isVertex ? "VS" : "PS", (unsigned long long)parsed->bytecodeHash, ms);
        }
    }

    {
        std::lock_guard<std::mutex> lk(parsedCacheMu_);
        auto [it, ok] = parsedCache_.emplace(memKey, parsed);
        return it->second;
    }
}

const MtlCompiledShader *MtlShaderCompiler::getOrCompilePsVariant(
    MtlParsedShader &ps,
    const MtlParsedShader *vs,
    uint8_t activeRtMask,
    bool hasDepthAttach,
    bool flatShade,
    bool alphaTestEnable,
    bool pointSpriteEnable,
    uint16_t samplerDepthCmpMask,
    uint16_t samplerNullMask,
    uint16_t samplerProjMask,
    uint16_t samplerGatherMask) {
    uint16_t usedMask = ps.psDeclaredSamplerMask;
    MtlShaderVariantKey key = {};
    key.vsIoHash            = vs ? vs->vsOutputIoHash : 0;
    key.colorWriteMask      = activeRtMask;
    key.hasDepthAttach      = hasDepthAttach;
    key.flatShade           = flatShade;
    key.alphaTestEnable     = alphaTestEnable;
    key.pointSpriteEnable   = pointSpriteEnable;
    key.samplerDepthCmpMask = samplerDepthCmpMask & usedMask;
    key.samplerNullMask     = samplerNullMask & usedMask;
    key.samplerProjMask     = samplerProjMask & usedMask;
    key.samplerGatherMask   = samplerGatherMask & usedMask;

    {
        std::lock_guard<std::mutex> lk(ps.impl->variantsMu);
        auto it = ps.psVariants.find(key);
        if (it != ps.psVariants.end()) {
            return &it->second;
        }
    }

    uint64_t variantHash = ps.bytecodeHash;
    variantHash = fnv1a64(&key.vsIoHash, sizeof(key.vsIoHash), variantHash);
    variantHash = fnv1a64(&key.colorWriteMask, sizeof(key.colorWriteMask), variantHash);
    uint8_t flags = (hasDepthAttach ? 1u : 0u) | (flatShade ? 2u : 0u) |
                    (alphaTestEnable ? 4u : 0u) | (pointSpriteEnable ? 8u : 0u);
    variantHash = fnv1a64(&flags, sizeof(flags), variantHash);
    uint16_t masks[4] = {
        key.samplerDepthCmpMask, key.samplerNullMask, key.samplerProjMask, key.samplerGatherMask
    };
    variantHash = fnv1a64(masks, sizeof(masks), variantHash);

    MtlCompiledShader compiled = {};
    if (!lowerAndCompileToMetal(ps.serializedIr, false, variantHash,
                                vs, activeRtMask, hasDepthAttach, flatShade,
                                alphaTestEnable, pointSpriteEnable,
                                key.samplerDepthCmpMask, key.samplerNullMask,
                                key.samplerProjMask, key.samplerGatherMask, compiled)) {
        return nullptr;
    }

    std::lock_guard<std::mutex> lk(ps.impl->variantsMu);
    auto [ins, ok] = ps.psVariants.emplace(key, std::move(compiled));
    return &ins->second;
}

bool MtlShaderCompiler::lowerAndCompileToMetal(
    const std::vector<uint8_t> &serializedIr,
    bool isVertex,
    uint64_t cacheKeyHash,
    const MtlParsedShader *vsForIoMatch,
    uint8_t activeRtMask,
    bool hasDepthAttach,
    bool flatShade,
    bool alphaTestEnable,
    bool pointSpriteEnable,
    uint16_t samplerDepthCmpMask,
    uint16_t samplerNullMask,
    uint16_t samplerProjMask,
    uint16_t samplerGatherMask,
    MtlCompiledShader &out) {
    using namespace dxbc_spv;

    out.shaderHash = cacheKeyHash;

    /* Fast path 1: check prewarmed / in-memory MTLLibrary cache */
    uint64_t memKey = shaderMemKey(cacheKeyHash, isVertex);
    {
        std::lock_guard<std::mutex> lk(libCacheMu_);
        auto it = prewarmedLibs_.find(memKey);
        if (it != prewarmedLibs_.end()) {
            out = it->second;
            return true;
        }
    }

    static const bool emuDref = ([] { const char *e = getenv("ME_PC_EMULATE_DREF"); return e && *e == '1'; })();
    const char *metaTag = expectedMslMetaTag(emuDref);
    /* Fast path 2: check disk cache BEFORE deserializing IR */
    char cachePath[512];
    snprintf(cachePath, sizeof(cachePath), "%s/%s_%016llx.msl",
             cacheDir_.c_str(), isVertex ? "vs" : "ps", (unsigned long long)cacheKeyHash);
    {
        std::ifstream ifs(cachePath);
        if (ifs.good()) {
            std::string firstLine;
            if (std::getline(ifs, firstLine) && parseCachedMslMetadata(firstLine, metaTag, out)) {
                std::stringstream ss;
                ss << ifs.rdbuf();
                std::string cachedMsl = ss.str();
                static bool logStalls = (getenv("ME_PC_LOG_STALLS") && *getenv("ME_PC_LOG_STALLS") == '1');
                auto tDisk = logStalls ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point{};
                if (!cachedMsl.empty() && compileMslToLibrary(device_, cachedMsl, out, false)) {
                    if (logStalls) {
                        double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - tDisk).count();
                        if (ms > 2.0) {
                            fprintf(stderr, "STALL_LOG: diskMsl %s #%016llx %.2f ms\n",
                                    isVertex ? "VS" : "PS", (unsigned long long)cacheKeyHash, ms);
                        }
                    }
                    std::lock_guard<std::mutex> lk(libCacheMu_);
                    prewarmedLibs_.emplace(memKey, out);
                    return true;
                }
            }
        }
    }

    /* Cold miss: hide long DXBC->SPIR-V->MSL->Metal compile stalls from guest game clocks */
    struct StallGuard {
        void (*hook)(int) = nullptr;
        explicit StallGuard() {
            hook = gStallHook.load(std::memory_order_acquire);
            if (hook) hook(1);
        }
        ~StallGuard() { if (hook) hook(0); }
    } stallGuard;

    static bool logStalls = (getenv("ME_PC_LOG_STALLS") && *getenv("ME_PC_LOG_STALLS") == '1');
    auto tCold = logStalls ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point{};

    ir::Builder builder;
    ir::Deserializer deserializer(serializedIr.data(), serializedIr.size());
    if (!deserializer.deserialize(builder)) {
        fprintf(stderr, "RunnerMetal: ir::Deserializer failed\n");
        return false;
    }

    /* Vertex shader: inject D3D9 half-pixel viewport offset & clip-space depth bias */
    if (isVertex) {
        injectVertexPosFixup(builder);
    } else {
        ir::LowerIoPass ioPass(builder);

        /* Match PS input locations & missing varyings against bound VS output IoMap */
        if (vsForIoMatch && vsForIoMatch->impl) {
            const auto &vsOut = vsForIoMatch->impl->vsOutMap;
            ioPass.resolveSemanticIo(vsOut);
            if (!ir::IoMap::checkCompatibility(ir::ShaderStage::eVertex, vsOut,
                                               ir::ShaderStage::ePixel,
                                               ir::IoMap::forInputs(builder), false)) {
                ioPass.resolveMismatchedIo(ir::ShaderStage::eVertex, vsOut);
            }
        }

        /* Strip unused color outputs (critical for NULL shadow targets & MRTs) */
        ir::IoMap consumedOutputs;
        for (uint32_t rt = 0; rt < 4u; rt++) {
            if (activeRtMask & (1u << rt)) {
                consumedOutputs.add(ir::IoLocation(ir::IoEntryType::ePerVertex, uint8_t(rt), 0xFu), {});
            }
        }
        if (hasDepthAttach) {
            consumedOutputs.add(ir::IoLocation(ir::BuiltIn::eDepth, 0x1u), {});
        }
        ioPass.resolveUnusedOutputs(consumedOutputs);

        if (!hasDepthAttach) {
            stripDepthOutput(builder);
        }

        if (flatShade) {
            /* Mark COLOR0 / COLOR1 (locations 9 and 10 in s_ffLocations) as flat */
            ioPass.enableFlatInterpolation((1u << 9u) | (1u << 10u));
        }

        specializePsBuiltIns(builder, alphaTestEnable, pointSpriteEnable,
                             samplerDepthCmpMask, samplerNullMask,
                             samplerProjMask, samplerGatherMask);

        /* Fold constant AlphaTest/PointSprite/SamplerState branches and eliminate dead paths */
        ir::CompileOptions optCfg = {};
        optCfg.cseOptions.relocateDescriptorLoad = true;
        for (int pass = 0; pass < 4; pass++) {
            bool progress = false;
            progress |= ir::ArithmeticPass::runPass(builder, optCfg.arithmeticOptions);
            progress |= ir::CsePass::runPass(builder, optCfg.cseOptions);
            progress |= ir::CleanupControlFlowPass::runPass(builder);
            progress |= ir::SsaConstructionPass::runResolveTrivialPhiPass(builder);
            if (!progress) break;
        }
    }

    ir::RemoveUnusedPass::runPass(builder);
    shrinkConstFloatDecl(builder);

    /* Lower any remaining legacy built-in inputs to fixed CBV register indices 0..8 */
    {
        ir::LowerIoPass lowerPass(builder);
        lowerPass.lowerSampleCountToSpecConstant(0u);
        lowerPass.lowerLegacyBuiltInToCbv(ir::BuiltIn::eLegacyConstFloat,   0u, 0u);
        lowerPass.lowerLegacyBuiltInToCbv(ir::BuiltIn::eLegacyConstInt,     0u, 1u);
        lowerPass.lowerLegacyBuiltInToCbv(ir::BuiltIn::eLegacyConstBool,    0u, 2u);
        lowerPass.lowerLegacyBuiltInToCbv(ir::BuiltIn::eLegacyAlphaTest,    0u, 3u);
        lowerPass.lowerLegacyBuiltInToCbv(ir::BuiltIn::eLegacyFog,          0u, 4u);
        lowerPass.lowerLegacyBuiltInToCbv(ir::BuiltIn::eLegacyClipPlanes,   0u, 5u);
        lowerPass.lowerLegacyBuiltInToCbv(ir::BuiltIn::eLegacyPointArgs,    0u, 6u);
        lowerPass.lowerLegacyBuiltInToCbv(ir::BuiltIn::eLegacySamplerState, 0u, 7u);
        lowerPass.lowerLegacyBuiltInToCbv(ir::BuiltIn::eLegacyTextureStage, 0u, 8u);
    }

    ir::RemoveUnusedPass::runPass(builder);
    if (!isVertex && !useSafeMath()) {
        promoteFragmentHalfPass(builder);
    }
    out.usedCbvMask = 0;
    out.usedSamplerMask = 0;
    out.constFloatVecCount = 0;
    out.writesDepth = false;
    out.usesDiscard = false;
    out.colorOutputMask = 0;
    for (int i = 0; i < 16; i++) out.samplerKind[i] = MtlSamplerTexKind::Tex2D;

    auto [da, db] = builder.getDeclarations();
    for (auto it = da; it != db; ++it) {
        switch (it->getOpCode()) {
            case ir::OpCode::eDclCbv: {
                uint32_t regIdx = uint32_t(it->getOperand(2u));
                if (regIdx < 32u) out.usedCbvMask |= (1u << regIdx);
                if (regIdx == 0u && it->getType().getArrayDimensions() > 0u) {
                    out.constFloatVecCount = uint16_t(it->getType().getArraySize(0u));
                }
                break;
            }
            case ir::OpCode::eDclSrv: {
                uint32_t regIdx = uint32_t(it->getOperand(2u));
                auto kind = ir::ResourceKind(it->getOperand(4u));
                if (regIdx < 16u) {
                    out.usedSamplerMask |= (1u << regIdx);
                    if (kind == ir::ResourceKind::eImageCube) out.samplerKind[regIdx] = MtlSamplerTexKind::TexCube;
                    else if (kind == ir::ResourceKind::eImage3D) out.samplerKind[regIdx] = MtlSamplerTexKind::Tex3D;
                    else out.samplerKind[regIdx] = MtlSamplerTexKind::Tex2D;
                }
                break;
            }
            case ir::OpCode::eDclOutputBuiltIn: {
                if (ir::BuiltIn(it->getOperand(it->getFirstLiteralOperandIndex())) == ir::BuiltIn::eDepth) {
                    out.writesDepth = true;
                }
                break;
            }
            case ir::OpCode::eDclOutput: {
                if (!isVertex) {
                    uint32_t loc = uint32_t(it->getOperand(1u));
                    if (loc < 4u) out.colorOutputMask |= uint8_t(1u << loc);
                }
                break;
            }
            default: break;
        }
    }
    if (!isVertex) {
        auto [ca, cb] = builder.getCode();
        for (auto it = ca; it != cb; ++it) {
            if (it->getOpCode() == ir::OpCode::eDemote) {
                out.usesDiscard = true;
                break;
            }
        }
    }

    /* Build SPIR-V binary */
    MtlSpirvMapping mapping;
    spirv::SpirvBuilder::Options spvOpts = {};
    spvOpts.includeDebugNames = false;
    spvOpts.floatControls2 = false;
    spvOpts.maxCbvSize = 0u;
    spvOpts.maxCbvCount = -1;
    spvOpts.allowFloatContraction = !useSafeMath();

    spirv::SpirvBuilder spvBuilder(builder, mapping, spvOpts);
    spvBuilder.buildSpirvBinary();
    std::vector<uint32_t> spvWords = spvBuilder.getSpirvBinary();

    /* Cross-compile SPIR-V -> MSL via SPIRV-Cross */
    std::string msl;
    try {
        spirv_cross::CompilerMSL mslCompiler(std::move(spvWords));

        spirv_cross::CompilerMSL::Options mslOpts;
        mslOpts.set_msl_version(2, 4);
        mslOpts.platform = spirv_cross::CompilerMSL::Options::macOS;
        mslOpts.enable_point_size_builtin = true;
        mslOpts.enable_clip_distance_user_varying = false;
        mslOpts.pad_fragment_output_components = true;
        mslOpts.invariant_float_math = false;
        mslCompiler.set_msl_options(mslOpts);
        auto commonOpts = mslCompiler.get_common_options();
        commonOpts.vertex.flip_vert_y = false; /* D3D9 and Metal both use +Y up clip space */
        mslCompiler.set_common_options(commonOpts);

        spv::ExecutionModel model = isVertex ? spv::ExecutionModelVertex : spv::ExecutionModelFragment;

        /* Bind CBVs (set 0, binding 0..9) -> Metal VS buffer(16..25), PS buffer(0..9) */
        for (uint32_t i = 0; i < 12; i++) {
            spirv_cross::MSLResourceBinding rb = {};
            rb.stage = model;
            rb.desc_set = 0;
            rb.binding = i;
            rb.msl_buffer = isVertex ? (16u + i) : i;
            mslCompiler.add_msl_resource_binding(rb);
        }
        /* Bind Textures (set 1, binding 0..15) -> Metal texture(0..15) */
        for (uint32_t i = 0; i < 16; i++) {
            spirv_cross::MSLResourceBinding rb = {};
            rb.stage = model;
            rb.desc_set = 1;
            rb.binding = i;
            rb.msl_texture = i;
            mslCompiler.add_msl_resource_binding(rb);
        }
        /* Bind Samplers (set 2, binding 0..15) -> Metal sampler(0..15) */
        for (uint32_t i = 0; i < 16; i++) {
            spirv_cross::MSLResourceBinding rb = {};
            rb.stage = model;
            rb.desc_set = 2;
            rb.binding = i;
            rb.msl_sampler = i;
            mslCompiler.add_msl_resource_binding(rb);
        }

        /* Spec constant 0 (SampleCount) -> default to 1 */
        auto specConsts = mslCompiler.get_specialization_constants();
        for (const auto &sc : specConsts) {
            if (sc.constant_id == 0) {
                mslCompiler.get_constant(sc.id).m.c[0].r[0].u32 = 1u;
            }
        }

        msl = mslCompiler.compile();
    } catch (const std::exception &ex) {
        fprintf(stderr, "RunnerMetal: SPIRV-Cross failed (%s #%016llx): %s\n",
                isVertex ? "VS" : "PS", (unsigned long long)cacheKeyHash, ex.what());
        return false;
    }

    if (!compileMslToLibrary(device_, msl, out, false)) {
        fprintf(stderr, "--- Failed MSL (%s #%016llx) ---\n%s\n---\n",
                isVertex ? "VS" : "PS", (unsigned long long)cacheKeyHash, msl.c_str());
        return false;
    }

    {
        std::lock_guard<std::mutex> lk(libCacheMu_);
        prewarmedLibs_.emplace(memKey, out);
    }
    if (logStalls) {
        double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - tCold).count();
        if (ms > 2.0) {
            fprintf(stderr, "STALL_LOG: coldShader %s #%016llx %.2f ms\n",
                    isVertex ? "VS" : "PS", (unsigned long long)cacheKeyHash, ms);
        }
    }

    /* Persist MSL + reflection header to disk cache */
    {
        uint32_t kindsPacked = 0;
        for (int i = 0; i < 16; i++) {
            kindsPacked |= (uint32_t(out.samplerKind[i]) & 3u) << (i * 2);
        }
        char hdr[128];
        snprintf(hdr, sizeof(hdr), "%s%x %x %u %x %x %u %u\n",
                 metaTag, out.usedCbvMask, out.usedSamplerMask, out.writesDepth ? 1u : 0u,
                 uint32_t(out.colorOutputMask), kindsPacked, uint32_t(out.constFloatVecCount),
                 out.usesDiscard ? 1u : 0u);
        std::ofstream ofs(cachePath, std::ios::trunc);
        if (ofs.good()) ofs << hdr << msl;
    }
    return true;
}

} // namespace mtl_d3d9
