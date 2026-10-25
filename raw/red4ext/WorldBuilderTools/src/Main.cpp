// WorldBuilderTools - native helpers for the World Builder (entSpawner) CET mod.
//
// Sole purpose: write `SplinePoint.tangents`, which CET cannot.
//
// `SplinePoint.tangents` is a CArrayFixedSize<Vector3> = Red::ERTTIType::StaticArray. CET's Lua
// converter has a case for ERTTIType::Array only, so from Lua the getter yields nothing and the
// setter is a silent no-op - a spline written from Lua ends up with zero tangents, and the NPC
// walking it goes straight between control points.
//
// Rather than marshal a SplinePoint across the boundary (its base is not IScriptable, so how CET
// would pass it is unclear), this takes the `Spline` HANDLE plus flat arrays and builds every
// point natively. Handles and array<Vector3> are both types CET marshals reliably.

#include <RED4ext/RED4ext.hpp>

namespace
{
constexpr auto PluginName = L"WorldBuilderTools";
constexpr auto PluginAuthor = L"Akiway";

// Cached at PostRegisterTypes; all belong to types the game always has.
RED4ext::CClass* s_splineCls = nullptr;
RED4ext::CClass* s_pointCls = nullptr;
RED4ext::CProperty* s_pointsProp = nullptr;
RED4ext::CProperty* s_positionProp = nullptr;
RED4ext::CProperty* s_tangentsProp = nullptr;
RED4ext::CProperty* s_automaticProp = nullptr;
RED4ext::CProperty* s_continuousProp = nullptr;
RED4ext::CProperty* s_idProp = nullptr;

bool s_ready = false;

RED4ext::CProperty* FindProperty(RED4ext::CClass* aClass, RED4ext::CName aName)
{
    if (!aClass)
    {
        return nullptr;
    }

    for (uint32_t i = 0; i < aClass->props.size(); ++i)
    {
        if (aClass->props[i]->name == aName)
        {
            return aClass->props[i];
        }
    }

    return nullptr;
}

void ResolveTypes()
{
    auto* rtti = RED4ext::CRTTISystem::Get();
    if (!rtti)
    {
        return;
    }

    s_splineCls = rtti->GetClass("Spline");
    s_pointCls = rtti->GetClass("SplinePoint");

    s_pointsProp = FindProperty(s_splineCls, "points");
    s_positionProp = FindProperty(s_pointCls, "position");
    s_tangentsProp = FindProperty(s_pointCls, "tangents");
    s_automaticProp = FindProperty(s_pointCls, "automaticTangents");
    s_continuousProp = FindProperty(s_pointCls, "continuousTangents");
    s_idProp = FindProperty(s_pointCls, "id");

    s_ready = s_splineCls && s_pointCls && s_pointsProp && s_positionProp && s_tangentsProp;
}

/// Writes both tangents of one SplinePoint. GetElement is used rather than raw pointer arithmetic
/// so the engine's own idea of element stride applies.
bool WriteTangents(void* aPoint, const RED4ext::Vector3& aIn, const RED4ext::Vector3& aOut)
{
    auto* arrayType = reinterpret_cast<RED4ext::CRTTIBaseArrayType*>(s_tangentsProp->type);
    if (!arrayType)
    {
        return false;
    }

    void* storage = s_tangentsProp->GetValuePtr<void>(aPoint);
    if (!storage)
    {
        return false;
    }

    // The fixed array is 2 wide: [0] = tangentIn, [1] = tangentOut, matching what the exporter
    // writes into a cooked worldSplineNode.
    if (arrayType->GetLength(storage) < 2)
    {
        return false;
    }

    auto* slotIn = reinterpret_cast<RED4ext::Vector3*>(arrayType->GetElement(storage, 0));
    auto* slotOut = reinterpret_cast<RED4ext::Vector3*>(arrayType->GetElement(storage, 1));
    if (!slotIn || !slotOut)
    {
        return false;
    }

    *slotIn = aIn;
    *slotOut = aOut;
    return true;
}

/// WBSetSplinePoints(spline, positions, tangentsIn, tangentsOut, automatic) -> Bool
///
/// Replaces the whole point list of `spline`. Positions are node-local, exactly as they are
/// written into a cooked sector. `automatic` may be shorter than `positions`; missing entries
/// default to false, meaning the supplied tangents are authoritative.
void SetSplinePoints(RED4ext::IScriptable* aContext, RED4ext::CStackFrame* aFrame, bool* aOut, int64_t a4)
{
    RED4EXT_UNUSED_PARAMETER(aContext);
    RED4EXT_UNUSED_PARAMETER(a4);

    RED4ext::Handle<RED4ext::ISerializable> spline;
    RED4ext::DynArray<RED4ext::Vector3> positions;
    RED4ext::DynArray<RED4ext::Vector3> tangentsIn;
    RED4ext::DynArray<RED4ext::Vector3> tangentsOut;
    RED4ext::DynArray<bool> automatic;

    RED4ext::GetParameter(aFrame, &spline);
    RED4ext::GetParameter(aFrame, &positions);
    RED4ext::GetParameter(aFrame, &tangentsIn);
    RED4ext::GetParameter(aFrame, &tangentsOut);
    RED4ext::GetParameter(aFrame, &automatic);
    aFrame->code++; // ParamEnd

    if (aOut)
    {
        *aOut = false;
    }

    if (!s_ready || !spline.instance || positions.size() == 0)
    {
        return;
    }

    // Guard rather than trust: a caller passing a non-Spline handle would otherwise corrupt memory.
    if (!spline.instance->GetNativeType()->IsA(s_splineCls))
    {
        return;
    }

    auto* pointsArrayType = reinterpret_cast<RED4ext::CRTTIBaseArrayType*>(s_pointsProp->type);
    void* pointsStorage = s_pointsProp->GetValuePtr<void>(spline.instance);
    if (!pointsArrayType || !pointsStorage)
    {
        return;
    }

    const uint32_t count = positions.size();
    if (!pointsArrayType->Resize(pointsStorage, count))
    {
        return;
    }

    const RED4ext::Vector3 zero{};

    for (uint32_t i = 0; i < count; ++i)
    {
        void* point = pointsArrayType->GetElement(pointsStorage, i);
        if (!point)
        {
            return;
        }

        s_positionProp->SetValue<RED4ext::Vector3>(point, positions[i]);

        const auto& tangentIn = i < tangentsIn.size() ? tangentsIn[i] : zero;
        const auto& tangentOut = i < tangentsOut.size() ? tangentsOut[i] : zero;
        if (!WriteTangents(point, tangentIn, tangentOut))
        {
            return;
        }

        const bool isAutomatic = i < automatic.size() ? automatic[i] : false;
        if (s_automaticProp)
        {
            s_automaticProp->SetValue<bool>(point, isAutomatic);
        }
        if (s_continuousProp)
        {
            s_continuousProp->SetValue<bool>(point, true);
        }
        if (s_idProp)
        {
            s_idProp->SetValue<uint32_t>(point, i);
        }
    }

    if (aOut)
    {
        *aOut = true;
    }
}

/// WBSplineToolsReady() -> Bool. Lets Lua detect the plugin and fall back to automatic tangents.
void SplineToolsReady(RED4ext::IScriptable* aContext, RED4ext::CStackFrame* aFrame, bool* aOut, int64_t a4)
{
    RED4EXT_UNUSED_PARAMETER(aContext);
    RED4EXT_UNUSED_PARAMETER(a4);

    aFrame->code++; // ParamEnd

    if (aOut)
    {
        *aOut = s_ready;
    }
}
} // namespace

RED4EXT_C_EXPORT void RED4EXT_CALL PostRegisterTypes()
{
    ResolveTypes();

    auto* rtti = RED4ext::CRTTISystem::Get();
    if (!rtti)
    {
        return;
    }

    {
        auto* func = RED4ext::CGlobalFunction::Create("WBSetSplinePoints", "WBSetSplinePoints", &SetSplinePoints);
        func->SetReturnType("Bool");
        func->AddParam("handle:Spline", "spline");
        func->AddParam("array:Vector3", "positions");
        func->AddParam("array:Vector3", "tangentsIn");
        func->AddParam("array:Vector3", "tangentsOut");
        func->AddParam("array:Bool", "automatic");
        rtti->RegisterFunction(func);
    }

    {
        auto* func = RED4ext::CGlobalFunction::Create("WBSplineToolsReady", "WBSplineToolsReady", &SplineToolsReady);
        func->SetReturnType("Bool");
        rtti->RegisterFunction(func);
    }
}

RED4EXT_C_EXPORT bool RED4EXT_CALL Main(RED4ext::v1::PluginHandle aHandle, RED4ext::v1::EMainReason aReason,
                                        const RED4ext::v1::Sdk* aSdk)
{
    RED4EXT_UNUSED_PARAMETER(aHandle);
    RED4EXT_UNUSED_PARAMETER(aSdk);

    if (aReason == RED4ext::v1::EMainReason::Load)
    {
        auto* rtti = RED4ext::CRTTISystem::Get();
        if (rtti)
        {
            rtti->AddPostRegisterCallback(PostRegisterTypes);
        }
    }

    return true;
}

RED4EXT_C_EXPORT void RED4EXT_CALL Query(RED4ext::v1::PluginInfo* aInfo)
{
    aInfo->name = PluginName;
    aInfo->author = PluginAuthor;
    aInfo->version = RED4EXT_V1_SEMVER(1, 1, 0);
    // Pinned: CGlobalFunction and CStackFrame layouts are compiled in and changed in 2.5, so a
    // build for another patch must be refused rather than corrupt the heap.
    aInfo->runtime = RED4EXT_V1_RUNTIME_VERSION_LATEST;
    aInfo->sdk = RED4EXT_V1_SDK_VERSION_CURRENT;
}

RED4EXT_C_EXPORT uint32_t RED4EXT_CALL Supports()
{
    return RED4EXT_API_VERSION_1;
}
