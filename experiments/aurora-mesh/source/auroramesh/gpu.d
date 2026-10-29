module auroramesh.gpu;

/**
 * Offscreen Vulkan renderer for the 3D viewport.
 *
 * Aurora's window renderer only understands a 2D draw list, so the 3D scene is
 * rendered on the GPU into its own colour target and then handed back as an
 * image. The result has the same shape as the software rasterizer's output, so
 * the editor can swap backends without changing anything else.
 *
 * The scene is drawn with one pipeline for shaded triangles (textured, lit in
 * the vertex stage) and one for lines (wireframe, grid, selection) that reuses
 * the same vertex shader and a flat-colour fragment shader.
 */
import auroramesh.camera : Camera;
import auroramesh.mesh : MaterialSlot, Mesh, Vec2, Vec3, dot;
import auroramesh.mesh_shaders : flatFragmentSpirv, meshFragmentSpirv,
    constantFragmentSpirv, meshVertexPassthroughSpirv, meshVertexPositionSpirv,
    meshVertexClipSpirv, meshVertexConstantSpirv, meshVertexSpirv,
    meshVertexTintSpirv, indexTriangleSpirv;
import auroramesh.renderer : GpuTriangle, RgbFrame, RenderOptions;
import aurora.image : RgbaImage;
import aurora.vulkan.api;
import core.time : MonoTime;
import std.algorithm : max, min;
import std.array : join;
import std.conv : to;
import std.file : append;
import std.format : format;
import std.math : cos, sin, sqrt, tan;
import std.stdio : stderr;
import std.string : toStringz;

// Declarations Aurora's minimal binding does not carry, spelled out here.
private enum int FormatDepth32 = 126; // VK_FORMAT_D32_SFLOAT
private enum int FormatRgb32 = 106; // VK_FORMAT_R32G32B32_SFLOAT
private enum int LayoutDepthAttachment = 3;
private enum int LayoutTransferSrc = 6;
private enum uint UsageDepthStencil = 0x00000020;
private enum uint UsageTransferSrc = 0x00000004;
private enum uint AccessDepthStencilWrite = 0x00000400;
private enum uint StageEarlyFragmentTests = 0x00000100;
private enum uint StageLateFragmentTests = 0x00000200;
private enum uint AccessTransferRead = 0x00000800;
private enum int CompareLessOrEqual = 3;
private enum int PolygonModeLine = 1;
private enum int PolygonModePoint = 2;
private enum int PolygonModeFill = 0;
private enum int TopologyPointList = 0;
private enum int TopologyLineList = 1;
/// The offscreen colour target. BGRA is the common native layout for render
/// targets, and the readback converts it back to RGB.
private enum int TargetFormat = VK_FORMAT_B8G8R8A8_UNORM;
private enum bool TargetIsBgra = TargetFormat == VK_FORMAT_B8G8R8A8_UNORM;
private enum uint CullBackFace = 0x00000002;
private enum uint DescriptorUniformBuffer = 6;
private enum uint UsageUniformBuffer = 0x00000010;
private enum int StTypePipelineDepthStencil = 25;
// VK_SUBPASS_CONTENTS_INLINE. Passing a load op here makes the driver wait for
// secondary command buffers and ignore every inline draw.
private enum int SubpassContentsInline = 0;
private enum int StTypePipelineTessellation = 21;

private struct DescriptorBufferInfo
{
    VkBuffer buffer;
    VkDeviceSize offset;
    VkDeviceSize range;
}

/// The leading fields of VkPhysicalDeviceProperties plus spare room, because
/// the driver writes the whole structure including the limits.
private struct DevicePropertiesPrefix
{
    uint apiVersion;
    uint driverVersion;
    uint vendorId;
    uint deviceId;
    uint deviceType;
    char[256] deviceName;
    ubyte[768] remainder;
}

private alias PFN_vkGetPhysicalDeviceProperties = extern(System) void function(
    VkPhysicalDevice, DevicePropertiesPrefix*);

private struct PushConstantRange
{
    uint stageFlags;
    uint offset;
    uint size;
}

/// Same layout as VkPipelineDepthStencilStateCreateInfo.
private struct DepthStencilState
{
    int sType;
    const(void)* pNext;
    VkFlags flags;
    VkBool32 depthTestEnable;
    VkBool32 depthWriteEnable;
    int depthCompareOp;
    VkBool32 depthBoundsTestEnable;
    VkBool32 stencilTestEnable;
    uint[7] front;
    uint[7] back;
    float minDepthBounds;
    float maxDepthBounds;
}

/// One vertex as the GPU sees it: padded position, padded normal, and uv.
/// Three-component 32-bit attributes are optional in Vulkan, so the padding
/// keeps the layout portable.
private struct GpuVertex
{
    float[10] values;
}

private struct Buffer
{
    VkBuffer handle;
    VkDeviceMemory memory;
    VkDeviceSize size;
    uint usage;
    void* mapped;
}

// Aurora's binding covers what the 2D renderer needs; these three are loaded
// from the device by name.
private alias PFN_vkCmdCopyImageToBuffer = extern(System) void function(
    VkCommandBuffer, VkImage, int, VkBuffer, uint, const(VkBufferImageCopy)*);
private alias PFN_vkCmdCopyBufferToImage = extern(System) void function(
    VkCommandBuffer, VkBuffer, VkImage, int, uint, const(VkBufferImageCopy)*);
private alias PFN_vkCmdPushConstants = extern(System) void function(
    VkCommandBuffer, VkPipelineLayout, uint, uint, uint, const(void)*);
private alias PFN_vkCmdDraw = extern(System) void function(VkCommandBuffer,
    uint, uint, uint, uint);
private alias PFN_vkCmdClearAttachments = extern(System) void function(
    VkCommandBuffer, uint, const(void)*, uint, const(void)*);
/// The binding does not declare query pools yet.
private alias VkQueryPool = ulong;

private alias PFN_vkCreateComputePipelines = extern(System) VkResult function(
    VkDevice, VkPipelineCache, uint, const(void)*, const(void)*,
    VkPipeline*);
private alias PFN_vkCmdDispatch = extern(System) void function(
    VkCommandBuffer, uint, uint, uint);

private enum VkFlags BufferUsageStorage = 0x00000020;
private enum uint StageCompute = 0x00000020;
private enum uint PipelineStageCompute = 0x00000800;
private enum uint AccessShaderWrite = 0x00000040;
private enum uint UsageStorage = 0x00000008;
private enum int DescriptorTypeStorageImage = 3;
private enum int LayoutGeneral = 1;
private enum int DescriptorTypeStorageBuffer = 7;
private enum int BindPointCompute = 1;
private enum int StTypeComputePipeline = 29;

private alias PFN_vkCreateQueryPool = extern(System) VkResult function(
    VkDevice, const(void)*, const(void)*, VkQueryPool*);
private alias PFN_vkDestroyQueryPool = extern(System) void function(
    VkDevice, VkQueryPool, const(void)*);
private alias PFN_vkCmdResetQueryPool = extern(System) void function(
    VkCommandBuffer, VkQueryPool, uint, uint);
private alias PFN_vkCmdBeginQuery = extern(System) void function(
    VkCommandBuffer, VkQueryPool, uint, VkFlags);
private alias PFN_vkCmdEndQuery = extern(System) void function(
    VkCommandBuffer, VkQueryPool, uint);
private alias PFN_vkGetQueryPoolResults = extern(System) VkResult function(
    VkDevice, VkQueryPool, uint, uint, size_t, void*, VkDeviceSize, VkFlags);

/// Same layout as VkQueryPoolCreateInfo.
private struct QueryPoolInfo
{
    int sType;
    const(void)* pNext;
    VkFlags flags;
    int queryType;
    uint queryCount;
    VkFlags pipelineStatistics;
}

private enum int QueryTypePipelineStatistics = 1;
private enum VkFlags StatisticsPrimitives = 0x2;
private enum VkFlags StatisticsVertex = 0x4;
private enum VkFlags StatisticsClipping = 0x40;
private enum VkFlags StatisticsFragment = 0x80;

/// Same layout as VkPhysicalDeviceFeatures; only statistics matters here.
private struct PhysicalFeatures
{
    uint[55] flags;
}

private enum size_t PipelineStatisticsQueryFeature = 24;

private enum int StTypeQueryPool = 11;

/// Same layout as VkComputePipelineCreateInfo.
private struct ComputePipelineInfo
{
    int sType;
    const(void)* pNext;
    VkFlags flags;
    VkPipelineShaderStageCreateInfo stage;
    VkPipelineLayout layout;
    VkPipeline basePipelineHandle;
    int basePipelineIndex;
}
private enum int QueryTypeOcclusion = 0;
private enum VkFlags QueryResultWait = 1;
private enum VkFlags QueryResult64 = 2;

/// Same layout as VkClearAttachment and VkClearRect.
private struct ClearAttachment
{
    uint aspectMask;
    uint colorAttachment;
    VkClearValue clearValue;
}

private struct ClearRect
{
    VkRect2D rect;
    uint baseArrayLayer;
    uint layerCount;
}

private struct Texture
{
    VkImage image;
    VkImageView view;
    VkDeviceMemory memory;
    VkDescriptorSet set;
    RgbaImage source;
}

// Reused between frames so the readback does not allocate per frame.
private ubyte[] stagingScratch;


/// Frame timings and counters, so a caller can prove where time goes.
struct GpuStats
{
    double uploadMs;
    double drawMs;
    double readbackMs;
    int drawCalls;
    int triangles;
    int lines;
}

private immutable float[16] identityMatrix = [
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1
];

private void check(VkResult result, string what)
{
    if (result != VK_SUCCESS && result != VK_INCOMPLETE)
        throw new Exception(what ~ " failed with VkResult " ~ (cast(int) result).to!string);
}

/// Select which Vulkan physical device to use, by enumeration order.
int gpuDeviceIndex;

/** Cached answer to "is there a usable Vulkan device for offscreen work?". */
private __gshared int availability = -1;
private __gshared string availabilityReason;
private __gshared string backendName;
private __gshared bool tracing;

/// Print each device bring-up stage, to diagnose driver problems.
void gpuTrace(bool enabled)
{
    tracing = enabled;
}

private void traceStep(string stage)
{
    if (!tracing)
        return;
    // A hard driver fault can take the process down before buffered console
    // output reaches the terminal, so record bring-up stages on disk too.
    try
    {
        append("build/gpu-trace.log", "[gpu] " ~ stage ~ "\n");
    }
    catch (Exception)
    {
    }
    try
    {
        stderr.writeln("[gpu] " ~ stage);
    }
    catch (Exception)
    {
    }
}

bool gpuAvailable()
{
    if (availability < 0)
    {
        try
        {
            // Probe the device only: a driver that rejects a generated shader
            // must not crash the probe.
            auto renderer = new GpuMeshRenderer(true);
            renderer.dispose();
            availability = 1;
            availabilityReason = "";
        }
        catch (Exception error)
        {
            availability = 0;
            availabilityReason = error.msg;
        }
    }
    return availability == 1;
}

string gpuUnavailableReason()
{
    gpuAvailable();
    return availabilityReason;
}

string gpuDeviceName()
{
    gpuAvailable();
    return backendName;
}

final class GpuMeshRenderer
{
    private VulkanApi _vk;
    private VkInstance _instance;
    private VkPhysicalDevice _physicalDevice;
    private VkDevice _device;
    private VkQueue _queue;
    private uint _family;
    private VkPhysicalDeviceMemoryProperties _memory;
    private VkCommandPool _pool;
    private VkCommandBuffer _commands;
    private VkFence _fence;

    private VkRenderPass _renderPass;
    private VkDescriptorSetLayout _setLayout;
    private VkDescriptorPool _descriptorPool;
    private VkPipelineLayout _pipelineLayout;
    private VkPipeline _meshPipeline;
    private VkPipeline _linePipeline;
    private VkPipeline _pointPipeline;
    // The compute rasterizer keeps its pipeline: building one recompiles the
    // SPIR-V inside the driver, which cost more than a whole software frame.
    private VkPipeline _rasterPipeline;
    private VkPipelineLayout _rasterLayout;
    private VkDescriptorSetLayout _rasterSetLayout;
    private VkDescriptorSet _rasterSet;
    private VkImageView _rasterView;
    // Upload buffers are kept between frames and grown on demand: allocating and
    // mapping four buffers per frame cost more than the dispatch itself.
    private Buffer _rasterTriangles;
    private Buffer _rasterCandidates;
    private Buffer _rasterStarts;
    private Buffer _rasterParams;

    private int _width;
    private int _height;
    private VkImage _color;
    private VkImageView _colorView;
    private VkDeviceMemory _colorMemory;
    private VkImage _depth;
    private VkImageView _depthView;
    private VkDeviceMemory _depthMemory;
    private VkFramebuffer _framebuffer;

    private Buffer _uniforms;
    private Buffer _vertices;
    private int _vertexCapacity;
    private Buffer _readback;

    private Buffer[] _materialIndices;
    private Texture[] _textures;
    private Buffer _edgeIndices;
    private Buffer _gridLines;
    private int _gridVertices;

    private size_t _meshHash;
    private int _meshVertices;
    private int _meshFaces;

    private GpuStats _stats;
    private PFN_vkCmdCopyImageToBuffer _cmdCopyImageToBuffer;
    private PFN_vkCmdPushConstants _cmdPushConstants;
    private PFN_vkCmdDraw _cmdDraw;
    private PFN_vkCmdClearAttachments _cmdClearAttachments;
    private PFN_vkCmdCopyBufferToImage _cmdCopyBufferToImage;
    private PFN_vkCreateQueryPool _createQueryPool;
    private PFN_vkDestroyQueryPool _destroyQueryPool;
    private PFN_vkCmdResetQueryPool _cmdResetQueryPool;
    private PFN_vkCmdBeginQuery _cmdBeginQuery;
    private PFN_vkCmdEndQuery _cmdEndQuery;
    private PFN_vkGetQueryPoolResults _getQueryPoolResults;
    private PFN_vkCreateComputePipelines _createComputePipelines;
    private PFN_vkCmdDispatch _cmdDispatch;
    private VkQueryPool _traceStats;


    /// Loads the Vulkan loader and builds a headless device, or throws.
    this(bool baseOnly = false)
    {
        traceStep("load loader");
        _vk = new VulkanApi();
        traceStep("create instance");
        createInstance();
        _vk.loadInstance(_instance);
        traceStep("choose device");
        choosePhysicalDevice();
        traceStep("create device");
        createDevice();
        _vk.loadDevice(_device);
        traceStep("device ready");
        _vk.vkGetDeviceQueue(_device, _family, 0, &_queue);
        _vk.vkGetPhysicalDeviceMemoryProperties(_physicalDevice, &_memory);
        _cmdCopyImageToBuffer = cast(PFN_vkCmdCopyImageToBuffer) _vk
            .vkGetDeviceProcAddr(_device, "vkCmdCopyImageToBuffer".toStringz);
        _cmdPushConstants = cast(PFN_vkCmdPushConstants) _vk
            .vkGetDeviceProcAddr(_device, "vkCmdPushConstants".toStringz);
        _cmdDraw = cast(PFN_vkCmdDraw) _vk
            .vkGetDeviceProcAddr(_device, "vkCmdDraw".toStringz);
        _cmdClearAttachments = cast(PFN_vkCmdClearAttachments) _vk
            .vkGetDeviceProcAddr(_device, "vkCmdClearAttachments".toStringz);
        _cmdCopyBufferToImage = cast(PFN_vkCmdCopyBufferToImage) _vk
            .vkGetDeviceProcAddr(_device, "vkCmdCopyBufferToImage".toStringz);
        _createQueryPool = cast(PFN_vkCreateQueryPool) _vk
            .vkGetDeviceProcAddr(_device, "vkCreateQueryPool".toStringz);
        _destroyQueryPool = cast(PFN_vkDestroyQueryPool) _vk
            .vkGetDeviceProcAddr(_device, "vkDestroyQueryPool".toStringz);
        _cmdResetQueryPool = cast(PFN_vkCmdResetQueryPool) _vk
            .vkGetDeviceProcAddr(_device, "vkCmdResetQueryPool".toStringz);
        _cmdBeginQuery = cast(PFN_vkCmdBeginQuery) _vk
            .vkGetDeviceProcAddr(_device, "vkCmdBeginQuery".toStringz);
        _cmdEndQuery = cast(PFN_vkCmdEndQuery) _vk
            .vkGetDeviceProcAddr(_device, "vkCmdEndQuery".toStringz);
        _getQueryPoolResults = cast(PFN_vkGetQueryPoolResults) _vk
            .vkGetDeviceProcAddr(_device, "vkGetQueryPoolResults".toStringz);
        _createComputePipelines = cast(PFN_vkCreateComputePipelines) _vk
            .vkGetDeviceProcAddr(_device, "vkCreateComputePipelines".toStringz);
        _cmdDispatch = cast(PFN_vkCmdDispatch) _vk
            .vkGetDeviceProcAddr(_device, "vkCmdDispatch".toStringz);

        if (_cmdCopyImageToBuffer is null || _cmdPushConstants is null ||
            _cmdDraw is null)
            throw new Exception("the Vulkan device is missing required entry points");
        traceStep("command resources");
        createCommandResources();
        traceStep("descriptors");
        createDescriptors();
        traceStep("render pass");
        createRenderPass();
        traceStep("pipelines");
        createPipelineLayout();
        if (!baseOnly)
        {
            createPipelines();
            traceStep("grid");
            buildGrid();
        }
        traceStep("ready");
    }

    ~this()
    {
        dispose();
    }

    void dispose()
    {
        if (_device is null)
            return;
        _vk.vkDeviceWaitIdle(_device);
        if (_traceStats)
        {
            if (_destroyQueryPool !is null)
                _destroyQueryPool(_device, _traceStats, null);
            _traceStats = VK_NULL_HANDLE;
        }
        destroyTargets();
        destroyBuffer(_uniforms);
        destroyBuffer(_vertices);
        destroyBuffer(_readback);
        destroyBuffer(_rasterTriangles);
        destroyBuffer(_rasterCandidates);
        destroyBuffer(_rasterStarts);
        destroyBuffer(_rasterParams);
        destroyBuffer(_edgeIndices);
        destroyBuffer(_gridLines);
        foreach (ref buffer; _materialIndices)
            destroyBuffer(buffer);
        _materialIndices = null;
        foreach (ref texture; _textures)
            destroyTexture(texture);
        _textures = null;
        if (_meshPipeline) _vk.vkDestroyPipeline(_device, _meshPipeline, null);
        if (_linePipeline) _vk.vkDestroyPipeline(_device, _linePipeline, null);
        if (_pointPipeline) _vk.vkDestroyPipeline(_device, _pointPipeline, null);
        if (_rasterPipeline) _vk.vkDestroyPipeline(_device, _rasterPipeline, null);
        if (_rasterLayout) _vk.vkDestroyPipelineLayout(_device, _rasterLayout, null);
        if (_rasterSetLayout)
            _vk.vkDestroyDescriptorSetLayout(_device, _rasterSetLayout, null);
        if (_pipelineLayout) _vk.vkDestroyPipelineLayout(_device, _pipelineLayout, null);
        if (_descriptorPool) _vk.vkDestroyDescriptorPool(_device, _descriptorPool, null);
        if (_setLayout) _vk.vkDestroyDescriptorSetLayout(_device, _setLayout, null);
        if (_renderPass) _vk.vkDestroyRenderPass(_device, _renderPass, null);
        if (_fence) _vk.vkDestroyFence(_device, _fence, null);
        if (_pool) _vk.vkDestroyCommandPool(_device, _pool, null);
        _vk.vkDestroyDevice(_device, null);
        _vk.vkDestroyInstance(_instance, null);
        _device = null;
        _instance = null;
    }

    @property string deviceName() const
    {
        return _deviceName;
    }

    /**
     * Build a pipeline from Aurora's own shaders with this renderer's pipeline
     * state. It separates driver or state problems from generated shaders.
     */
    /// Try a vertex/fragment pair from disk. This is the fastest way to check
    /// whether a driver accepts a generated module.
    bool probeFiles(string vertexPath, string fragmentPath, out string report)
    {
        import std.file : read;
        const vertexWords = cast(const(uint)[]) read(vertexPath);
        const fragmentWords = cast(const(uint)[]) read(fragmentPath);
        const vertexModule = shaderModule(vertexWords);
        const fragmentModule = shaderModule(fragmentWords);
        scope (exit)
        {
            _vk.vkDestroyShaderModule(_device, vertexModule, null);
            _vk.vkDestroyShaderModule(_device, fragmentModule, null);
        }
        VkPipelineShaderStageCreateInfo[2] stages;
        stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
        stages[0].module_ = vertexModule;
        stages[0].pName = "main".ptr;
        stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
        stages[1].module_ = fragmentModule;
        stages[1].pName = "main".ptr;
        VkVertexInputBindingDescription binding;
        binding.binding = 0;
        binding.stride = GpuVertex.sizeof;
        binding.inputRate = VK_VERTEX_INPUT_RATE_VERTEX;
        VkVertexInputAttributeDescription[3] attributes = [
            VkVertexInputAttributeDescription(0, 0,
                VK_FORMAT_R32G32B32A32_SFLOAT, 0),
            VkVertexInputAttributeDescription(1, 0,
                VK_FORMAT_R32G32B32A32_SFLOAT, 16),
            VkVertexInputAttributeDescription(2, 0, VK_FORMAT_R32G32_SFLOAT, 32)];

        string[] notes;
        bool tryLayout(string label, VkVertexInputBindingDescription layout,
            VkVertexInputAttributeDescription[] layoutAttributes)
        {
            try
            {
                auto pipeline = buildPipeline(stages.ptr, layout,
                    layoutAttributes, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
                    PolygonModeFill, true, false, "probe");
                _vk.vkDestroyPipeline(_device, pipeline, null);
                notes ~= label ~ ": accepted";
                return true;
            }
            catch (Exception error)
            {
                notes ~= label ~ ": " ~ error.msg;
                return false;
            }
        }

        const meshLayoutOk = tryLayout("mesh-layout", binding, attributes[]);
        auto auroraBinding = binding;
        auroraBinding.stride = 24;
        VkVertexInputAttributeDescription[2] auroraAttributes = [
            VkVertexInputAttributeDescription(0, 0, VK_FORMAT_R32G32_SFLOAT, 0),
            VkVertexInputAttributeDescription(1, 0,
                VK_FORMAT_R32G32B32A32_SFLOAT, 8)];
        tryLayout("aurora-layout", auroraBinding, auroraAttributes[]);
        report = notes.join("; ");
        return meshLayoutOk;
    }

    /// Draw one clip-space triangle and report the centre pixel. This isolates
    /// rasterization from the camera, the mesh, and the material textures.
    bool smokeTest(out string report)
    {
        const float[12] clip = [-1, -1, 0, 1, 3, -1, 0, 1, -1, 3, 0, 1];
        auto buffer = createHostBuffer(48, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        buffer.mapped[0 .. 48] = cast(ubyte[]) clip[];
        const vertexModule = shaderModule(meshVertexClipSpirv);
        const fragmentModule = shaderModule(constantFragmentSpirv);
        scope (exit)
        {
            _vk.vkDestroyShaderModule(_device, vertexModule, null);
            _vk.vkDestroyShaderModule(_device, fragmentModule, null);
            destroyBuffer(buffer);
        }
        VkPipelineShaderStageCreateInfo[2] stages;
        stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
        stages[0].module_ = vertexModule;
        stages[0].pName = "main".ptr;
        stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
        stages[1].module_ = fragmentModule;
        stages[1].pName = "main".ptr;
        VkVertexInputBindingDescription binding;
        binding.binding = 0;
        binding.stride = 16;
        binding.inputRate = VK_VERTEX_INPUT_RATE_VERTEX;
        VkVertexInputAttributeDescription[1] attributes = [
            VkVertexInputAttributeDescription(0, 0,
                VK_FORMAT_R32G32B32A32_SFLOAT, 0)];
        auto pipeline = buildPipeline(stages.ptr, binding, attributes[],
            VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, PolygonModeFill, false, false,
            "smoke");
        scope (exit) _vk.vkDestroyPipeline(_device, pipeline, null);

        // The generated vertex shader multiplies by the uniform block, so bind a
        // real descriptor set; an unbound one reads zeros and clips everything.
        auto floats = cast(float[]) _uniforms.mapped[0 .. 160];
        floats[0 .. 16] = identityMatrix[];
        VkDescriptorSetAllocateInfo allocate;
        allocate.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        allocate.descriptorPool = _descriptorPool;
        allocate.descriptorSetCount = 1;
        allocate.pSetLayouts = &_setLayout;
        VkDescriptorSet set;
        check(_vk.vkAllocateDescriptorSets(_device, &allocate, &set),
            "allocating a smoke descriptor set");
        DescriptorBufferInfo bufferInfo;
        bufferInfo.buffer = _uniforms.handle;
        bufferInfo.range = _uniforms.size;
        VkWriteDescriptorSet write;
        write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write.dstSet = set;
        write.dstBinding = 0;
        write.descriptorCount = 1;
        write.descriptorType = DescriptorUniformBuffer;
        write.pBufferInfo = &bufferInfo;
        _vk.vkUpdateDescriptorSets(_device, 1, &write, 0, null);

        ensureTargets(64, 64);
        QueryPoolInfo statsInfo;
        statsInfo.sType = StTypeQueryPool;
        statsInfo.queryType = QueryTypePipelineStatistics;
        statsInfo.queryCount = 1;
        statsInfo.pipelineStatistics = StatisticsPrimitives | StatisticsVertex |
            StatisticsFragment;
        VkQueryPool statsPool;
        check(_createQueryPool(_device, &statsInfo, null, &statsPool),
            "creating a statistics query pool");
        scope (exit) _destroyQueryPool(_device, statsPool, null);
        check(_vk.vkResetCommandBuffer(_commands, 0), "resetting commands");
        VkCommandBufferBeginInfo begin;
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        check(_vk.vkBeginCommandBuffer(_commands, &begin), "beginning commands");
        _cmdResetQueryPool(_commands, statsPool, 0, 1);
        VkClearValue[1] clears;
        // A non-black clear tells a missing draw apart from a missing copy.
        clears[0].color.float32 = [0.25f, 0.5f, 0.75f, 1.0f];
        VkRenderPassBeginInfo pass;
        pass.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        pass.renderPass = _renderPass;
        pass.framebuffer = _framebuffer;
        pass.renderArea.extent = VkExtent2D(64, 64);
        pass.clearValueCount = 1;
        pass.pClearValues = clears.ptr;
        _vk.vkCmdBeginRenderPass(_commands, &pass, SubpassContentsInline);
        VkViewport viewport;
        viewport.width = 64;
        viewport.height = 64;
        viewport.maxDepth = 1.0f;
        _vk.vkCmdSetViewport(_commands, 0, 1, &viewport);
        VkRect2D scissor;
        scissor.extent = VkExtent2D(64, 64);
        _vk.vkCmdSetScissor(_commands, 0, 1, &scissor);
        _vk.vkCmdBindPipeline(_commands, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        _vk.vkCmdBindDescriptorSets(_commands, VK_PIPELINE_BIND_POINT_GRAPHICS,
            _pipelineLayout, 0, 1, &set, 0, null);
        const VkDeviceSize offset;
        _vk.vkCmdBindVertexBuffers(_commands, 0, 1, &buffer.handle, &offset);
        _cmdBeginQuery(_commands, statsPool, 0, 0);
        _cmdDraw(_commands, 3, 1, 0, 0);
        _cmdEndQuery(_commands, statsPool, 0);
        _vk.vkCmdEndRenderPass(_commands);
        VkBufferImageCopy copy;
        copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        copy.imageSubresource.layerCount = 1;
        copy.imageExtent = VkExtent3D(64, 64, 1);
        _cmdCopyImageToBuffer(_commands, _color, LayoutTransferSrc,
            _readback.handle, 1, &copy);
        check(_vk.vkEndCommandBuffer(_commands), "finishing a smoke test");
        submitAndWait();
        ulong[3] counters;
        check(_getQueryPoolResults(_device, statsPool, 0, 1, counters.sizeof,
            counters.ptr, counters[0].sizeof, QueryResultWait | QueryResult64),
            "reading the pipeline statistics");
        const pixels = cast(ubyte[]) _readback.mapped[0 .. 64 * 64 * 4];
        const middle = (32 * 64 + 32) * 4;
        // Compare against the cleared corner: UNORM rounding makes the stored
        // clear 127 rather than 128 in green, so a literal never matches.
        int drawn;
        int first = -1;
        foreach (index; 0 .. 64 * 64)
        {
            const at = index * 4;
            if (pixels[at] != pixels[0] || pixels[at + 1] != pixels[1] ||
                pixels[at + 2] != pixels[2])
            {
                if (first < 0)
                    first = index;
                drawn++;
            }
        }
        report = format("centre %s %s %s (expect 179 204 230); primitives %s "
            ~ "vertices %s fragments %s; drawn %s first %s", pixels[middle],
            pixels[middle + 1], pixels[middle + 2], counters[0], counters[1],
            counters[2], drawn, first < 0 ? "none" : format("%s,%s",
                first % 64, first / 64));
        return true;
    }

    /// Draw a triangle whose positions come from gl_VertexIndex alone, with no
    /// vertex buffer and no attributes, so a broken vertex fetch cannot collapse
    /// it: whatever is left is rasterization.
    bool smokeIndexTriangle(out string report)
    {
        ensureTargets(64, 64);
        const vertexModule = shaderModule(indexTriangleSpirv);
        const fragmentModule = shaderModule(flatFragmentSpirv);
        scope (exit)
        {
            _vk.vkDestroyShaderModule(_device, vertexModule, null);
            _vk.vkDestroyShaderModule(_device, fragmentModule, null);
        }
        VkPipelineShaderStageCreateInfo[2] stages;
        stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
        stages[0].module_ = vertexModule;
        stages[0].pName = "main".ptr;
        stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
        stages[1].module_ = fragmentModule;
        stages[1].pName = "main".ptr;
        VkPipelineVertexInputStateCreateInfo vertexInput;
        vertexInput.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        VkPipelineInputAssemblyStateCreateInfo assembly;
        assembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
        VkPipelineViewportStateCreateInfo viewportState;
        viewportState.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        viewportState.viewportCount = 1;
        viewportState.scissorCount = 1;
        VkViewport staticViewport;
        staticViewport.width = 64;
        staticViewport.height = 64;
        staticViewport.maxDepth = 1.0f;
        VkRect2D staticScissor;
        staticScissor.extent = VkExtent2D(64, 64);
        viewportState.pViewports = &staticViewport;
        viewportState.pScissors = &staticScissor;
        VkPipelineRasterizationStateCreateInfo raster;
        raster.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        raster.polygonMode = PolygonModeFill;
        raster.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
        raster.lineWidth = 1.0f;
        VkPipelineMultisampleStateCreateInfo multisample;
        multisample.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
        VkPipelineColorBlendAttachmentState blend;
        blend.colorWriteMask = VK_COLOR_COMPONENT_R_BIT |
            VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT |
            VK_COLOR_COMPONENT_A_BIT;
        VkPipelineColorBlendStateCreateInfo colorBlend;
        colorBlend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        colorBlend.attachmentCount = 1;
        colorBlend.pAttachments = &blend;
        VkGraphicsPipelineCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        info.stageCount = 2;
        info.pStages = stages.ptr;
        info.pVertexInputState = &vertexInput;
        info.pInputAssemblyState = &assembly;
        info.pViewportState = &viewportState;
        info.pRasterizationState = &raster;
        info.pMultisampleState = &multisample;
        info.pColorBlendState = &colorBlend;
        info.layout = _pipelineLayout;
        info.renderPass = _renderPass;
        VkPipeline pipeline;
        check(_vk.vkCreateGraphicsPipelines(_device, VK_NULL_HANDLE, 1, &info,
            null, &pipeline), "creating an index-triangle pipeline");
        scope (exit) _vk.vkDestroyPipeline(_device, pipeline, null);

        QueryPoolInfo statsInfo;
        statsInfo.sType = StTypeQueryPool;
        statsInfo.queryType = QueryTypePipelineStatistics;
        statsInfo.queryCount = 1;
        statsInfo.pipelineStatistics = StatisticsPrimitives | StatisticsVertex |
            StatisticsFragment;
        VkQueryPool statsPool;
        check(_createQueryPool(_device, &statsInfo, null, &statsPool),
            "creating a statistics query pool");
        scope (exit) _destroyQueryPool(_device, statsPool, null);

        check(_vk.vkResetCommandBuffer(_commands, 0), "resetting commands");
        VkCommandBufferBeginInfo begin;
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        check(_vk.vkBeginCommandBuffer(_commands, &begin), "beginning commands");
        _cmdResetQueryPool(_commands, statsPool, 0, 1);
        VkClearValue[1] clears;
        clears[0].color.float32 = [0.25f, 0.5f, 0.75f, 1.0f];
        VkRenderPassBeginInfo pass;
        pass.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        pass.renderPass = _renderPass;
        pass.framebuffer = _framebuffer;
        pass.renderArea.extent = VkExtent2D(64, 64);
        pass.clearValueCount = 1;
        pass.pClearValues = clears.ptr;
        _vk.vkCmdBeginRenderPass(_commands, &pass, SubpassContentsInline);
        VkViewport viewport;
        viewport.width = 64;
        viewport.height = 64;
        viewport.maxDepth = 1.0f;
        _vk.vkCmdSetViewport(_commands, 0, 1, &viewport);
        VkRect2D scissor;
        scissor.extent = VkExtent2D(64, 64);
        _vk.vkCmdSetScissor(_commands, 0, 1, &scissor);
        _vk.vkCmdBindPipeline(_commands, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        const float[4] red = [1.0f, 0.0f, 0.0f, 1.0f];
        _cmdPushConstants(_commands, _pipelineLayout,
            VK_SHADER_STAGE_FRAGMENT_BIT, 0, 16, red.ptr);
        _cmdBeginQuery(_commands, statsPool, 0, 0);
        _cmdDraw(_commands, 3, 1, 0, 0);
        _cmdEndQuery(_commands, statsPool, 0);
        _vk.vkCmdEndRenderPass(_commands);
        VkBufferImageCopy copy;
        copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        copy.imageSubresource.layerCount = 1;
        copy.imageExtent = VkExtent3D(64, 64, 1);
        _cmdCopyImageToBuffer(_commands, _color, LayoutTransferSrc,
            _readback.handle, 1, &copy);
        check(_vk.vkEndCommandBuffer(_commands), "finishing the index smoke");
        submitAndWait();
        ulong[3] counters;
        check(_getQueryPoolResults(_device, statsPool, 0, 1, counters.sizeof,
            counters.ptr, counters[0].sizeof, QueryResultWait | QueryResult64),
            "reading the pipeline statistics");
        const pixels = cast(ubyte[]) _readback.mapped[0 .. 64 * 64 * 4];
        int drawn;
        int first = -1;
        foreach (index; 0 .. 64 * 64)
        {
            const at = index * 4;
            if (pixels[at] != pixels[0] || pixels[at + 1] != pixels[1] ||
                pixels[at + 2] != pixels[2])
            {
                if (first < 0)
                    first = index;
                drawn++;
            }
        }
        const middle = (32 * 64 + 32) * 4;
        report = format("centre %s %s %s (expect 255 0 0); primitives %s "
            ~ "vertices %s fragments %s; drawn %s first %s", pixels[middle],
            pixels[middle + 1], pixels[middle + 2], counters[0], counters[1],
            counters[2], drawn, first < 0 ? "none" : format("%s,%s",
                first % 64, first / 64));
        return true;
    }

    /// Draw a single point from a constant vertex shader, with no vertex buffer
    /// and no vertex input state. The most direct rasterization check there is.
    bool smokePoint(out string report)
    {
        // Create the target first: the pipeline is then built with the real
        // framebuffer in place, matching the documented ordering.
        ensureTargets(64, 64);
        const vertexModule = shaderModule(meshVertexConstantSpirv);
        const fragmentModule = shaderModule(flatFragmentSpirv);
        scope (exit)
        {
            _vk.vkDestroyShaderModule(_device, vertexModule, null);
            _vk.vkDestroyShaderModule(_device, fragmentModule, null);
        }
        VkPipelineShaderStageCreateInfo[2] stages;
        stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
        stages[0].module_ = vertexModule;
        stages[0].pName = "main".ptr;
        stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
        stages[1].module_ = fragmentModule;
        stages[1].pName = "main".ptr;
        VkVertexInputBindingDescription binding;
        VkPipelineVertexInputStateCreateInfo vertexInput;
        vertexInput.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        VkPipelineInputAssemblyStateCreateInfo assembly;
        assembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        assembly.topology = TopologyPointList;
        VkPipelineViewportStateCreateInfo viewportState;
        viewportState.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        viewportState.viewportCount = 1;
        viewportState.scissorCount = 1;
        VkViewport staticViewport;
        staticViewport.width = 64;
        staticViewport.height = 64;
        staticViewport.maxDepth = 1.0f;
        VkRect2D staticScissor;
        staticScissor.extent = VkExtent2D(64, 64);
        viewportState.pViewports = &staticViewport;
        viewportState.pScissors = &staticScissor;
        VkPipelineRasterizationStateCreateInfo raster;
        raster.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        raster.polygonMode = PolygonModeFill;
        raster.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
        raster.lineWidth = 1.0f;
        VkPipelineMultisampleStateCreateInfo multisample;
        multisample.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
        VkPipelineColorBlendAttachmentState blend;
        blend.colorWriteMask = VK_COLOR_COMPONENT_R_BIT |
            VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT |
            VK_COLOR_COMPONENT_A_BIT;
        VkPipelineColorBlendStateCreateInfo colorBlend;
        colorBlend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        colorBlend.attachmentCount = 1;
        colorBlend.pAttachments = &blend;
        int[2] dynamicStates = [VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR];
        VkPipelineDynamicStateCreateInfo dynamic;
        dynamic.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dynamic.dynamicStateCount = 2;
        dynamic.pDynamicStates = dynamicStates.ptr;
        VkPipelineLayoutCreateInfo layoutInfo;
        layoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        VkPipelineLayout simpleLayout;
        check(_vk.vkCreatePipelineLayout(_device, &layoutInfo, null,
            &simpleLayout), "creating a bare pipeline layout");
        scope (exit) _vk.vkDestroyPipelineLayout(_device, simpleLayout, null);
        VkGraphicsPipelineCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        info.stageCount = 2;
        info.pStages = stages.ptr;
        info.pVertexInputState = &vertexInput;
        info.pInputAssemblyState = &assembly;
        info.pViewportState = &viewportState;
        info.pRasterizationState = &raster;
        info.pMultisampleState = &multisample;
        info.pColorBlendState = &colorBlend;
        info.pDynamicState = &dynamic;
        info.layout = _pipelineLayout;
        info.renderPass = _renderPass;
        VkPipeline pipeline;
        check(_vk.vkCreateGraphicsPipelines(_device, VK_NULL_HANDLE, 1, &info,
            null, &pipeline), "creating a point pipeline");
        scope (exit) _vk.vkDestroyPipeline(_device, pipeline, null);

        ensureTargets(64, 64);
        QueryPoolInfo pointStatsInfo;
        pointStatsInfo.sType = StTypeQueryPool;
        pointStatsInfo.queryType = QueryTypePipelineStatistics;
        pointStatsInfo.queryCount = 1;
        pointStatsInfo.pipelineStatistics = StatisticsPrimitives |
            StatisticsVertex | StatisticsFragment;
        VkQueryPool pointStats;
        check(_createQueryPool(_device, &pointStatsInfo, null, &pointStats),
            "creating a point statistics pool");
        scope (exit) _destroyQueryPool(_device, pointStats, null);
        check(_vk.vkResetCommandBuffer(_commands, 0), "resetting commands");
        VkCommandBufferBeginInfo begin;
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        check(_vk.vkBeginCommandBuffer(_commands, &begin), "beginning commands");
        _cmdResetQueryPool(_commands, pointStats, 0, 1);
        VkClearValue[1] clears;
        clears[0].color.float32 = [0.0f, 0.0f, 0.0f, 1.0f];
        VkRenderPassBeginInfo pass;
        pass.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        pass.renderPass = _renderPass;
        pass.framebuffer = _framebuffer;
        pass.renderArea.extent = VkExtent2D(64, 64);
        pass.clearValueCount = 1;
        pass.pClearValues = clears.ptr;
        _vk.vkCmdBeginRenderPass(_commands, &pass, SubpassContentsInline);
        VkViewport viewport;
        viewport.width = 64;
        viewport.height = 64;
        viewport.maxDepth = 1.0f;
        _vk.vkCmdSetViewport(_commands, 0, 1, &viewport);
        VkRect2D scissor;
        scissor.extent = VkExtent2D(64, 64);
        _vk.vkCmdSetScissor(_commands, 0, 1, &scissor);
        // Clearing inside the pass proves inline commands reach the driver.
        ClearAttachment attachment;
        attachment.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        attachment.clearValue.color.float32 = [1.0f, 0.0f, 0.0f, 1.0f];
        ClearRect rect;
        rect.rect.extent = VkExtent2D(8, 8);
        rect.layerCount = 1;
        _cmdClearAttachments(_commands, 1, &attachment, 1, &rect);
        _vk.vkCmdBindPipeline(_commands, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        const float[4] red = [1.0f, 0.0f, 0.0f, 1.0f];
        _cmdPushConstants(_commands, _pipelineLayout,
            VK_SHADER_STAGE_FRAGMENT_BIT, 0, 16, red.ptr);
        const uint[1] index = [0];
        auto indices = createHostBuffer(4, VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
        scope (exit) destroyBuffer(indices);
        indices.mapped[0 .. 4] = cast(ubyte[]) index[];
        _vk.vkCmdBindIndexBuffer(_commands, indices.handle, 0,
            VK_INDEX_TYPE_UINT32);
        _cmdBeginQuery(_commands, pointStats, 0, 0);
        _vk.vkCmdDrawIndexed(_commands, 1, 1, 0, 0, 0);
        _cmdEndQuery(_commands, pointStats, 0);
        _vk.vkCmdEndRenderPass(_commands);
        VkBufferImageCopy copy;
        copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        copy.imageSubresource.layerCount = 1;
        copy.imageExtent = VkExtent3D(64, 64, 1);
        _cmdCopyImageToBuffer(_commands, _color, LayoutTransferSrc,
            _readback.handle, 1, &copy);
        check(_vk.vkEndCommandBuffer(_commands), "finishing the point smoke test");
        submitAndWait();
        ulong[3] pointCounters;
        check(_getQueryPoolResults(_device, pointStats, 0, 1,
            pointCounters.sizeof, pointCounters.ptr, pointCounters[0].sizeof,
            QueryResultWait | QueryResult64),
            "reading the point statistics");
        const pixels = cast(ubyte[]) _readback.mapped[0 .. 64 * 64 * 4];
        const middle = (32 * 64 + 32) * 4;
        const corner = (4 * 64 + 4) * 4;
        report = format("centre %s %s %s (expect 255 0 0); corner %s %s %s "
            ~ "(expect 179 204 230); primitives %s vertices %s fragments %s",
            pixels[middle], pixels[middle + 1], pixels[middle + 2],
            pixels[corner], pixels[corner + 1], pixels[corner + 2],
            pointCounters[0], pointCounters[1], pointCounters[2]);
        return true;
    }

    /// Draw a clip-space triangle with Aurora's proven vertex shader, in this
    /// renderer's plumbing, to separate shader faults from pipeline faults.
    bool smokeAuroraVertex(out string report)
    {
        const float[24] vertices = [-1, -1, 0, 0, 1, 1, 1, 1,
                                    3, -1, 0, 0, 1, 1, 1, 1,
                                    -1, 3, 0, 0, 1, 1, 1, 1];
        auto buffer = createHostBuffer(96, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        buffer.mapped[0 .. 96] = cast(ubyte[]) vertices[];
        import aurora.vulkan.shaders : vertexShaderSpirv;
        const vertexModule = shaderModule(vertexShaderSpirv);
        const fragmentModule = shaderModule(constantFragmentSpirv);
        scope (exit)
        {
            _vk.vkDestroyShaderModule(_device, vertexModule, null);
            _vk.vkDestroyShaderModule(_device, fragmentModule, null);
            destroyBuffer(buffer);
        }
        VkPipelineShaderStageCreateInfo[2] stages;
        stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
        stages[0].module_ = vertexModule;
        stages[0].pName = "main".ptr;
        stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
        stages[1].module_ = fragmentModule;
        stages[1].pName = "main".ptr;
        VkVertexInputBindingDescription binding;
        binding.binding = 0;
        binding.stride = 32;
        binding.inputRate = VK_VERTEX_INPUT_RATE_VERTEX;
        VkVertexInputAttributeDescription[3] attributes = [
            VkVertexInputAttributeDescription(0, 0, VK_FORMAT_R32G32_SFLOAT, 0),
            VkVertexInputAttributeDescription(1, 0, VK_FORMAT_R32G32_SFLOAT, 8),
            VkVertexInputAttributeDescription(2, 0,
                VK_FORMAT_R32G32B32A32_SFLOAT, 16)];
        auto pipeline = buildPipeline(stages.ptr, binding, attributes[],
            VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, PolygonModeFill, false, false,
            "aurora-vertex");
        scope (exit) _vk.vkDestroyPipeline(_device, pipeline, null);

        ensureTargets(64, 64);
        check(_vk.vkResetCommandBuffer(_commands, 0), "resetting commands");
        VkCommandBufferBeginInfo begin;
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        check(_vk.vkBeginCommandBuffer(_commands, &begin), "beginning commands");
        VkClearValue[1] clears;
        clears[0].color.float32 = [0.25f, 0.5f, 0.75f, 1.0f];
        VkRenderPassBeginInfo pass;
        pass.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        pass.renderPass = _renderPass;
        pass.framebuffer = _framebuffer;
        pass.renderArea.extent = VkExtent2D(64, 64);
        pass.clearValueCount = 1;
        pass.pClearValues = clears.ptr;
        _vk.vkCmdBeginRenderPass(_commands, &pass, SubpassContentsInline);
        VkViewport viewport;
        viewport.width = 64;
        viewport.height = 64;
        viewport.maxDepth = 1.0f;
        _vk.vkCmdSetViewport(_commands, 0, 1, &viewport);
        VkRect2D scissor;
        scissor.extent = VkExtent2D(64, 64);
        _vk.vkCmdSetScissor(_commands, 0, 1, &scissor);
        _vk.vkCmdBindPipeline(_commands, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        const VkDeviceSize offset;
        _vk.vkCmdBindVertexBuffers(_commands, 0, 1, &buffer.handle, &offset);
        _cmdDraw(_commands, 3, 1, 0, 0);
        _vk.vkCmdEndRenderPass(_commands);
        VkBufferImageCopy copy;
        copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        copy.imageSubresource.layerCount = 1;
        copy.imageExtent = VkExtent3D(64, 64, 1);
        _cmdCopyImageToBuffer(_commands, _color, LayoutTransferSrc,
            _readback.handle, 1, &copy);
        check(_vk.vkEndCommandBuffer(_commands), "finishing the aurora smoke");
        submitAndWait();
        const pixels = cast(ubyte[]) _readback.mapped[0 .. 64 * 64 * 4];
        const middle = (32 * 64 + 32) * 4;
        report = format("centre %s %s %s (expect 179 204 230)", pixels[middle],
            pixels[middle + 1], pixels[middle + 2]);
        return true;
    }

    /// Draw a clip-space triangle with Aurora's own shader pair and a 1x1 white
    /// texture, using this repository's device and render pass.
    bool smokeAuroraPair(out string report)
    {
        import aurora.vulkan.shaders : fragmentShaderSpirv, vertexShaderSpirv;
        ensureTargets(64, 64);
        VkDescriptorSetLayoutBinding binding;
        binding.binding = 0;
        binding.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        binding.descriptorCount = 1;
        binding.stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
        VkDescriptorSetLayoutCreateInfo setInfo;
        setInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        setInfo.bindingCount = 1;
        setInfo.pBindings = &binding;
        VkDescriptorSetLayout setLayout;
        check(_vk.vkCreateDescriptorSetLayout(_device, &setInfo, null, &setLayout),
            "creating the sampler set layout");
        scope (exit) _vk.vkDestroyDescriptorSetLayout(_device, setLayout, null);
        VkPipelineLayoutCreateInfo layoutInfo;
        layoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        layoutInfo.setLayoutCount = 1;
        layoutInfo.pSetLayouts = &setLayout;
        VkPipelineLayout pairLayout;
        check(_vk.vkCreatePipelineLayout(_device, &layoutInfo, null, &pairLayout),
            "creating the pair layout");
        scope (exit) _vk.vkDestroyPipelineLayout(_device, pairLayout, null);

        // One white texel, so the fragment shader's sample is predictable.
        VkDeviceMemory textureMemory;
        const texture = createImage(1, 1, VK_FORMAT_R8G8B8A8_UNORM,
            VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
            textureMemory);
        scope (exit)
        {
            _vk.vkDestroyImage(_device, texture, null);
            _vk.vkFreeMemory(_device, textureMemory, null);
        }
        const view = createView(texture, VK_FORMAT_R8G8B8A8_UNORM);
        scope (exit) _vk.vkDestroyImageView(_device, view, null);
        auto staging = createHostBuffer(4, VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
        scope (exit) destroyBuffer(staging);
        ubyte[4] white = [255, 255, 255, 255];
        staging.mapped[0 .. 4] = white[];

        check(_vk.vkResetCommandBuffer(_commands, 0), "resetting commands");
        VkCommandBufferBeginInfo upload;
        upload.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        upload.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        check(_vk.vkBeginCommandBuffer(_commands, &upload), "beginning the upload");
        transitionImage(_commands, texture, VK_IMAGE_LAYOUT_UNDEFINED,
            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
        VkBufferImageCopy region;
        region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.layerCount = 1;
        region.imageExtent = VkExtent3D(1, 1, 1);
        _cmdCopyBufferToImage(_commands, staging.handle, texture,
            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
        transitionImage(_commands, texture, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
        check(_vk.vkEndCommandBuffer(_commands), "finishing the upload");
        submitAndWait();

        VkDescriptorSetAllocateInfo allocate;
        allocate.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        allocate.descriptorPool = _descriptorPool;
        allocate.descriptorSetCount = 1;
        allocate.pSetLayouts = &setLayout;
        VkDescriptorSet set;
        check(_vk.vkAllocateDescriptorSets(_device, &allocate, &set),
            "allocating the pair descriptor set");
        VkDescriptorImageInfo imageInfo;
        imageInfo.sampler = sampler();
        imageInfo.imageView = view;
        imageInfo.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        VkWriteDescriptorSet write;
        write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write.dstSet = set;
        write.dstBinding = 0;
        write.descriptorCount = 1;
        write.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        write.pImageInfo = &imageInfo;
        _vk.vkUpdateDescriptorSets(_device, 1, &write, 0, null);

        // Aurora's vertex layout: position, uv, colour.
        const float[24] vertices = [
            -1, -1, 0, 0, 1, 1, 1, 1,
            3, -1, 0, 0, 1, 1, 1, 1,
            -1, 3, 0, 0, 1, 1, 1, 1];
        auto buffer = createHostBuffer(96, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        buffer.mapped[0 .. 96] = cast(ubyte[]) vertices[];
        auto indices = createHostBuffer(12, VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
        const uint[3] order = [0, 1, 2];
        indices.mapped[0 .. 12] = cast(ubyte[]) order[];
        const vertexModule = shaderModule(vertexShaderSpirv);
        const fragmentModule = shaderModule(fragmentShaderSpirv);
        scope (exit)
        {
            _vk.vkDestroyShaderModule(_device, vertexModule, null);
            _vk.vkDestroyShaderModule(_device, fragmentModule, null);
            destroyBuffer(buffer);
            destroyBuffer(indices);
        }
        VkPipelineShaderStageCreateInfo[2] stages;
        stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
        stages[0].module_ = vertexModule;
        stages[0].pName = "main".ptr;
        stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
        stages[1].module_ = fragmentModule;
        stages[1].pName = "main".ptr;
        VkVertexInputBindingDescription vertexBinding;
        vertexBinding.binding = 0;
        vertexBinding.stride = 32;
        vertexBinding.inputRate = VK_VERTEX_INPUT_RATE_VERTEX;
        VkVertexInputAttributeDescription[3] attributes = [
            VkVertexInputAttributeDescription(0, 0, VK_FORMAT_R32G32_SFLOAT, 0),
            VkVertexInputAttributeDescription(1, 0, VK_FORMAT_R32G32_SFLOAT, 8),
            VkVertexInputAttributeDescription(2, 0,
                VK_FORMAT_R32G32B32A32_SFLOAT, 16)];
        auto pipeline = buildPipeline(stages.ptr, vertexBinding, attributes[],
            VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, PolygonModeFill, false, false,
            "aurora-pair", pairLayout);
        scope (exit) _vk.vkDestroyPipeline(_device, pipeline, null);

        // An occlusion query separates "no fragments" from "no colour writes".
        QueryPoolInfo queryPoolInfo;
        queryPoolInfo.sType = StTypeQueryPool;
        queryPoolInfo.queryType = QueryTypeOcclusion;
        queryPoolInfo.queryCount = 1;
        VkQueryPool queryPool;
        check(_createQueryPool(_device, &queryPoolInfo, null, &queryPool),
            "creating an occlusion query pool");
        scope (exit) _destroyQueryPool(_device, queryPool, null);

        // Pipeline statistics say which stage the draw dies in.
        QueryPoolInfo statsInfo;
        statsInfo.sType = StTypeQueryPool;
        statsInfo.queryType = QueryTypePipelineStatistics;
        statsInfo.queryCount = 1;
        statsInfo.pipelineStatistics = StatisticsPrimitives | StatisticsVertex |
            StatisticsFragment;
        VkQueryPool statsPool;
        check(_createQueryPool(_device, &statsInfo, null, &statsPool),
            "creating a statistics query pool");
        scope (exit) _destroyQueryPool(_device, statsPool, null);

        check(_vk.vkResetCommandBuffer(_commands, 0), "resetting commands");
        VkCommandBufferBeginInfo begin;
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        check(_vk.vkBeginCommandBuffer(_commands, &begin), "beginning commands");
        _cmdResetQueryPool(_commands, queryPool, 0, 1);
        _cmdResetQueryPool(_commands, statsPool, 0, 1);
        VkClearValue[1] clears;
        clears[0].color.float32 = [0.25f, 0.5f, 0.75f, 1.0f];
        VkRenderPassBeginInfo pass;
        pass.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        pass.renderPass = _renderPass;
        pass.framebuffer = _framebuffer;
        pass.renderArea.extent = VkExtent2D(64, 64);
        pass.clearValueCount = 1;
        pass.pClearValues = clears.ptr;
        _vk.vkCmdBeginRenderPass(_commands, &pass, SubpassContentsInline);
        VkViewport viewport;
        viewport.width = 64;
        viewport.height = 64;
        viewport.maxDepth = 1.0f;
        _vk.vkCmdSetViewport(_commands, 0, 1, &viewport);
        VkRect2D scissor;
        scissor.extent = VkExtent2D(64, 64);
        _vk.vkCmdSetScissor(_commands, 0, 1, &scissor);
        _vk.vkCmdBindPipeline(_commands, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        _vk.vkCmdBindDescriptorSets(_commands, VK_PIPELINE_BIND_POINT_GRAPHICS,
            pairLayout, 0, 1, &set, 0, null);
        const VkDeviceSize offset;
        _vk.vkCmdBindVertexBuffers(_commands, 0, 1, &buffer.handle, &offset);
        _vk.vkCmdBindIndexBuffer(_commands, indices.handle, 0,
            VK_INDEX_TYPE_UINT32);
        _cmdBeginQuery(_commands, queryPool, 0, 0);
        _cmdBeginQuery(_commands, statsPool, 0, 0);
        _vk.vkCmdDrawIndexed(_commands, 3, 1, 0, 0, 0);
        _cmdEndQuery(_commands, statsPool, 0);
        _cmdEndQuery(_commands, queryPool, 0);
        _vk.vkCmdEndRenderPass(_commands);
        VkBufferImageCopy copy;
        copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        copy.imageSubresource.layerCount = 1;
        copy.imageExtent = VkExtent3D(64, 64, 1);
        _cmdCopyImageToBuffer(_commands, _color, LayoutTransferSrc,
            _readback.handle, 1, &copy);
        check(_vk.vkEndCommandBuffer(_commands), "finishing the pair smoke");
        submitAndWait();
        ulong samples;
        const queryResult = _getQueryPoolResults(_device, queryPool, 0, 1,
            samples.sizeof, &samples, samples.sizeof,
            QueryResultWait | QueryResult64);
        check(queryResult, "reading the occlusion query");
        ulong[3] counters;
        check(_getQueryPoolResults(_device, statsPool, 0, 1, counters.sizeof,
            counters.ptr, counters[0].sizeof, QueryResultWait | QueryResult64),
            "reading the pipeline statistics");
        const pixels = cast(ubyte[]) _readback.mapped[0 .. 64 * 64 * 4];
        const middle = (32 * 64 + 32) * 4;
        report = format("centre %s %s %s (expect 255 255 255); occlusion "
            ~ "samples %s; primitives %s vertices %s fragments %s",
            pixels[middle], pixels[middle + 1], pixels[middle + 2], samples,
            counters[0], counters[1], counters[2]);
        return true;
    }

    /// Dispatch one workgroup that stores 7 into a storage buffer. Compute uses
    /// no rasterizer, so this separates "shader execution" from "rasterization".
    bool smokeCompute(out string report)
    {
        import auroramesh.mesh_shaders : computeStoreSpirv;
        const shader = shaderModule(computeStoreSpirv);
        scope (exit) _vk.vkDestroyShaderModule(_device, shader, null);

        auto buffer = createHostBuffer(4, BufferUsageStorage);
        scope (exit) destroyBuffer(buffer);
        const uint[1] zero = [0];
        buffer.mapped[0 .. 4] = cast(ubyte[]) zero[];

        VkDescriptorSetLayoutBinding binding;
        binding.binding = 0;
        binding.descriptorType = DescriptorTypeStorageBuffer;
        binding.descriptorCount = 1;
        binding.stageFlags = StageCompute;
        VkDescriptorSetLayoutCreateInfo setInfo;
        setInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        setInfo.bindingCount = 1;
        setInfo.pBindings = &binding;
        VkDescriptorSetLayout setLayout;
        check(_vk.vkCreateDescriptorSetLayout(_device, &setInfo, null, &setLayout),
            "creating the compute set layout");
        scope (exit) _vk.vkDestroyDescriptorSetLayout(_device, setLayout, null);
        VkPipelineLayoutCreateInfo layoutInfo;
        layoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        layoutInfo.setLayoutCount = 1;
        layoutInfo.pSetLayouts = &setLayout;
        VkPipelineLayout layout;
        check(_vk.vkCreatePipelineLayout(_device, &layoutInfo, null, &layout),
            "creating the compute layout");
        scope (exit) _vk.vkDestroyPipelineLayout(_device, layout, null);
        VkDescriptorSetAllocateInfo allocate;
        allocate.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        allocate.descriptorPool = _descriptorPool;
        allocate.descriptorSetCount = 1;
        allocate.pSetLayouts = &setLayout;
        VkDescriptorSet set;
        check(_vk.vkAllocateDescriptorSets(_device, &allocate, &set),
            "allocating the compute descriptor set");
        DescriptorBufferInfo bufferInfo;
        bufferInfo.buffer = buffer.handle;
        bufferInfo.range = buffer.size;
        VkWriteDescriptorSet write;
        write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write.dstSet = set;
        write.dstBinding = 0;
        write.descriptorCount = 1;
        write.descriptorType = DescriptorTypeStorageBuffer;
        write.pBufferInfo = &bufferInfo;
        _vk.vkUpdateDescriptorSets(_device, 1, &write, 0, null);

        ComputePipelineInfo info;
        info.sType = StTypeComputePipeline;
        info.stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        info.stage.stage = StageCompute;
        info.stage.module_ = shader;
        info.stage.pName = "main".ptr;
        info.layout = layout;
        info.basePipelineIndex = -1;
        VkPipeline pipeline;
        check(_createComputePipelines(_device, VK_NULL_HANDLE, 1, &info, null,
            &pipeline), "creating the compute pipeline");
        scope (exit) _vk.vkDestroyPipeline(_device, pipeline, null);

        check(_vk.vkResetCommandBuffer(_commands, 0), "resetting commands");
        VkCommandBufferBeginInfo begin;
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        check(_vk.vkBeginCommandBuffer(_commands, &begin), "beginning commands");
        _vk.vkCmdBindPipeline(_commands, BindPointCompute, pipeline);
        _vk.vkCmdBindDescriptorSets(_commands, BindPointCompute, layout, 0, 1,
            &set, 0, null);
        _cmdDispatch(_commands, 1, 1, 1);
        check(_vk.vkEndCommandBuffer(_commands), "finishing the dispatch");
        submitAndWait();
        const words = cast(uint[]) buffer.mapped[0 .. 4];
        report = format("storage value %s (expect 7)", words[0]);
        return words[0] == 7;
    }

    /// Dispatch a compute shader that paints a per-invocation colour into a
    /// storage image and read the image back. The rasterizer cannot produce
    /// pixels on this device, so this decides whether a dispatch can.
    bool smokeComputeImage(out string report)
    {
        import auroramesh.mesh_shaders : computePaintSpirv;
        ensureTargets(64, 64);
        const shader = shaderModule(computePaintSpirv);
        scope (exit) _vk.vkDestroyShaderModule(_device, shader, null);

        VkDeviceMemory imageMemory;
        const image = createImage(64, 64, VK_FORMAT_R8G8B8A8_UNORM,
            UsageStorage | UsageTransferSrc, imageMemory);
        scope (exit)
        {
            _vk.vkDestroyImage(_device, image, null);
            _vk.vkFreeMemory(_device, imageMemory, null);
        }
        const view = createView(image, VK_FORMAT_R8G8B8A8_UNORM);
        scope (exit) _vk.vkDestroyImageView(_device, view, null);

        // A storage buffer, the shape the proven compute shader writes.
        auto stamps = createHostBuffer(64 * 64 * 4, BufferUsageStorage);
        scope (exit) destroyBuffer(stamps);
        auto zeros = cast(ubyte*) stamps.mapped;
        foreach (index; 0 .. 64 * 64 * 4)
            zeros[index] = 0;

        // VkShaderStageFlags: compute is 0x20. 0x800 is the task stage, and a
        // descriptor declared there is invisible to a compute shader.
        VkDescriptorSetLayoutBinding[2] bindings;
        bindings[0].binding = 0;
        bindings[0].descriptorType = DescriptorTypeStorageImage;
        bindings[0].descriptorCount = 1;
        bindings[0].stageFlags = StageCompute;
        bindings[1].binding = 1;
        bindings[1].descriptorType = DescriptorTypeStorageBuffer;
        bindings[1].descriptorCount = 1;
        bindings[1].stageFlags = StageCompute;
        VkDescriptorSetLayoutCreateInfo setInfo;
        setInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        setInfo.bindingCount = 2;
        setInfo.pBindings = bindings.ptr;
        VkDescriptorSetLayout setLayout;
        check(_vk.vkCreateDescriptorSetLayout(_device, &setInfo, null, &setLayout),
            "creating the image set layout");
        scope (exit) _vk.vkDestroyDescriptorSetLayout(_device, setLayout, null);
        VkPipelineLayoutCreateInfo layoutInfo;
        layoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        layoutInfo.setLayoutCount = 1;
        layoutInfo.pSetLayouts = &setLayout;
        VkPipelineLayout layout;
        check(_vk.vkCreatePipelineLayout(_device, &layoutInfo, null, &layout),
            "creating the image compute layout");
        scope (exit) _vk.vkDestroyPipelineLayout(_device, layout, null);
        VkDescriptorSetAllocateInfo allocate;
        allocate.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        allocate.descriptorPool = _descriptorPool;
        allocate.descriptorSetCount = 1;
        allocate.pSetLayouts = &setLayout;
        VkDescriptorSet set;
        check(_vk.vkAllocateDescriptorSets(_device, &allocate, &set),
            "allocating the image descriptor set");
        DescriptorBufferInfo stampInfo;
        stampInfo.buffer = stamps.handle;
        stampInfo.range = stamps.size;
        VkDescriptorImageInfo imageInfo;
        imageInfo.imageView = view;
        imageInfo.imageLayout = LayoutGeneral;
        VkWriteDescriptorSet[2] writes;
        writes[0].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[0].dstSet = _rasterSet;
        writes[0].dstBinding = 0;
        writes[0].descriptorCount = 1;
        writes[0].descriptorType = DescriptorTypeStorageImage;
        writes[0].pImageInfo = &imageInfo;
        writes[1].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[1].dstSet = set;
        writes[1].dstBinding = 1;
        writes[1].descriptorCount = 1;
        writes[1].descriptorType = DescriptorTypeStorageBuffer;
        writes[1].pBufferInfo = &stampInfo;
        _vk.vkUpdateDescriptorSets(_device, 2, writes.ptr, 0, null);

        ComputePipelineInfo info;
        info.sType = StTypeComputePipeline;
        info.stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        info.stage.stage = StageCompute;
        info.stage.module_ = shader;
        info.stage.pName = "main".ptr;
        info.layout = layout;
        info.basePipelineIndex = -1;
        VkPipeline pipeline;
        check(_createComputePipelines(_device, VK_NULL_HANDLE, 1, &info, null,
            &pipeline), "creating the paint pipeline");
        scope (exit) _vk.vkDestroyPipeline(_device, pipeline, null);

        check(_vk.vkResetCommandBuffer(_commands, 0), "resetting commands");
        VkCommandBufferBeginInfo begin;
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        check(_vk.vkBeginCommandBuffer(_commands, &begin), "beginning commands");
        // Probe: no barrier before the dispatch.
        _vk.vkCmdBindPipeline(_commands, BindPointCompute, pipeline);
        _vk.vkCmdBindDescriptorSets(_commands, BindPointCompute, layout, 0, 1,
            &set, 0, null);
        transitionStorage(_commands, image, VK_IMAGE_LAYOUT_UNDEFINED, LayoutGeneral,
            VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, PipelineStageCompute, 0,
            AccessShaderWrite);
        _cmdDispatch(_commands, 8, 8, 1);
        transitionStorage(_commands, image, LayoutGeneral, LayoutTransferSrc,
            PipelineStageCompute, VK_PIPELINE_STAGE_TRANSFER_BIT,
            AccessShaderWrite, AccessTransferRead);
        VkBufferImageCopy copy;
        copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        copy.imageSubresource.layerCount = 1;
        copy.imageExtent = VkExtent3D(64, 64, 1);
        _cmdCopyImageToBuffer(_commands, image, LayoutTransferSrc,
            _readback.handle, 1, &copy);
        check(_vk.vkEndCommandBuffer(_commands), "finishing the paint dispatch");
        submitAndWait();

        const pixels = cast(ubyte[]) _readback.mapped[0 .. 64 * 64 * 4];
        const atA = (5 * 64 + 3) * 4;
        const atB = (20 * 64 + 60) * 4;
        report = format("pixel 3,5 %s %s %s (expect ~12 20 127); pixel 60,20 "
            ~ "%s %s %s (expect ~239 80 127)", pixels[atA], pixels[atA + 1],
            pixels[atA + 2], pixels[atB], pixels[atB + 1], pixels[atB + 2]);
        // UNORM rounds to nearest, so every channel may differ from the
        // truncating expectation by one.
        bool near(int at, int red, int green, int blue)
        {
            import std.math : abs;
            return abs(cast(int) pixels[at] - red) <= 1 &&
                abs(cast(int) pixels[at + 1] - green) <= 1 &&
                abs(cast(int) pixels[at + 2] - blue) <= 1;
        }
        return near(atA, 12, 20, 127) && near(atB, 239, 80, 127);
    }

    /// Move an image between layouts with explicit stage and access masks.
    private void transitionStorage(VkCommandBuffer commands, VkImage image,
        int oldLayout, int newLayout, uint oldStage, uint newStage,
        uint oldAccess, uint newAccess)
    {
        VkImageMemoryBarrier barrier;
        barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.srcAccessMask = oldAccess;
        barrier.dstAccessMask = newAccess;
        barrier.oldLayout = oldLayout;
        barrier.newLayout = newLayout;
        barrier.srcQueueFamilyIndex = uint.max;
        barrier.dstQueueFamilyIndex = uint.max;
        barrier.image = image;
        barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        barrier.subresourceRange.levelCount = 1;
        barrier.subresourceRange.layerCount = 1;
        _vk.vkCmdPipelineBarrier(commands, oldStage, newStage, 0, 0, null, 0,
            null, 1, &barrier);
    }

    /// Rasterize projected triangles on the GPU and paint them into the frame.
    ///
    /// The pipeline is built once and kept: creating it per frame made the
    /// driver recompile the kernel every time, which cost more than a whole
    /// software frame. Only the descriptor contents change from frame to frame.
    private void ensureRasterPipeline()
    {
        import auroramesh.mesh_shaders : computeRasterSpirv;
        if (_rasterPipeline)
            return;
        const shader = shaderModule(computeRasterSpirv);
        scope (exit) _vk.vkDestroyShaderModule(_device, shader, null);
        VkDescriptorSetLayoutBinding[5] bindings;
        bindings[0].binding = 0;
        bindings[0].descriptorType = DescriptorTypeStorageImage;
        bindings[0].descriptorCount = 1;
        bindings[0].stageFlags = StageCompute;
        foreach (slot; 1 .. 5)
        {
            bindings[slot].binding = cast(uint) slot;
            bindings[slot].descriptorType = DescriptorTypeStorageBuffer;
            bindings[slot].descriptorCount = 1;
            bindings[slot].stageFlags = StageCompute;
        }
        VkDescriptorSetLayoutCreateInfo setInfo;
        setInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        setInfo.bindingCount = 5;
        setInfo.pBindings = bindings.ptr;
        check(_vk.vkCreateDescriptorSetLayout(_device, &setInfo, null,
            &_rasterSetLayout), "creating the viewport raster set layout");
        VkPipelineLayoutCreateInfo layoutInfo;
        layoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        layoutInfo.setLayoutCount = 1;
        layoutInfo.pSetLayouts = &_rasterSetLayout;
        check(_vk.vkCreatePipelineLayout(_device, &layoutInfo, null,
            &_rasterLayout), "creating the viewport raster layout");
        VkDescriptorSetAllocateInfo allocate;
        allocate.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        allocate.descriptorPool = _descriptorPool;
        allocate.descriptorSetCount = 1;
        allocate.pSetLayouts = &_rasterSetLayout;
        check(_vk.vkAllocateDescriptorSets(_device, &allocate, &_rasterSet),
            "allocating the viewport raster descriptor set");
        ComputePipelineInfo info;
        info.sType = StTypeComputePipeline;
        info.stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        info.stage.stage = StageCompute;
        info.stage.module_ = shader;
        info.stage.pName = "main".ptr;
        info.layout = _rasterLayout;
        info.basePipelineIndex = -1;
        check(_createComputePipelines(_device, VK_NULL_HANDLE, 1, &info, null,
            &_rasterPipeline), "creating the viewport raster pipeline");
    }

    /// Rasterize projected triangles on the GPU and paint them into the frame.
    ///
    /// The caller keeps whatever it already drew (background, grid, overlays);
    /// only pixels the kernel actually covers are replaced. Returns false when
    /// nothing was covered, which keeps the software path as the fallback.
    bool rasterizeTriangles(const GpuTriangle[] triangles, int width, int height,
        ref RgbFrame frame)
    {
        import auroramesh.mesh_shaders : computeRasterSpirv;
        import auroramesh.renderer : GpuTriangle, RgbFrame;
        if (triangles.length == 0 || width <= 0 || height <= 0)
            return false;
        const startTime = MonoTime.currTime();
        ensureTargets(width, height);
        const targetTime = MonoTime.currTime();

        const pixelCount = width * height;
        // Bin each triangle into the 8x8 tiles its bounding box touches. Binning
        // per pixel cost more than the whole software frame: the count and fill
        // passes walked every covered pixel twice. A tile lookup serves 64
        // pixels and the kernel still resolves depth per pixel.
        enum tileSize = 8;
        const tileColumns = (width + tileSize - 1) / tileSize;
        const tileRows = (height + tileSize - 1) / tileSize;
        const tileCount = tileColumns * tileRows;
        uint[] counts;
        counts.length = tileCount;
        counts[] = 0;
        void tilesOf(in GpuTriangle triangle, out int lowColumn, out int lowRow,
            out int highColumn, out int highRow)
        {
            const xs = [triangle.data[0], triangle.data[4], triangle.data[8]];
            const ys = [triangle.data[1], triangle.data[5], triangle.data[9]];
            const lowX = max(0.0, min(xs[0], min(xs[1], xs[2])));
            const lowY = max(0.0, min(ys[0], min(ys[1], ys[2])));
            const highX = min(width - 1.0, max(xs[0], max(xs[1], xs[2])));
            const highY = min(height - 1.0, max(ys[0], max(ys[1], ys[2])));
            lowColumn = cast(int) lowX / tileSize;
            lowRow = cast(int) lowY / tileSize;
            highColumn = cast(int) highX / tileSize;
            highRow = cast(int) highY / tileSize;
        }
        foreach (index, triangle; triangles)
        {
            int lowColumn;
            int lowRow;
            int highColumn;
            int highRow;
            tilesOf(triangle, lowColumn, lowRow, highColumn, highRow);
            foreach (row; lowRow .. highRow + 1)
                foreach (column; lowColumn .. highColumn + 1)
                    counts[row * tileColumns + column] += 1;
        }
        uint[] starts;
        starts.length = tileCount + 1;
        uint running;
        foreach (index; 0 .. tileCount)
        {
            starts[index] = running;
            running += counts[index];
        }
        starts[tileCount] = running;
        if (running == 0)
            return false;
        uint[] cursor = starts.dup;
        uint[] candidates;
        candidates.length = running;
        foreach (index, triangle; triangles)
        {
            int lowColumn;
            int lowRow;
            int highColumn;
            int highRow;
            tilesOf(triangle, lowColumn, lowRow, highColumn, highRow);
            foreach (row; lowRow .. highRow + 1)
                foreach (column; lowColumn .. highColumn + 1)
                    candidates[cursor[row * tileColumns + column]++] =
                        cast(uint) index;
        }


        ensureRasterBuffer(_rasterTriangles,
            triangles.length * GpuTriangle.sizeof);
        _rasterTriangles.mapped[0 .. triangles.length * GpuTriangle.sizeof] =
            cast(ubyte[]) triangles[];
        ensureRasterBuffer(_rasterCandidates, candidates.length * uint.sizeof);
        _rasterCandidates.mapped[0 .. candidates.length * uint.sizeof] =
            cast(ubyte[]) candidates[];
        ensureRasterBuffer(_rasterStarts, starts.length * uint.sizeof);
        _rasterStarts.mapped[0 .. starts.length * uint.sizeof] =
            cast(ubyte[]) starts[];
        const uint[3] params = [cast(uint) width, cast(uint) height,
            cast(uint) tileColumns];
        ensureRasterBuffer(_rasterParams, params.length * uint.sizeof);
        _rasterParams.mapped[0 .. params.length * uint.sizeof] =
            cast(ubyte[]) params[];
        const uploadTime = MonoTime.currTime();

        ensureRasterPipeline();
        VkDescriptorImageInfo imageInfo;
        imageInfo.imageView = _colorView;
        imageInfo.imageLayout = LayoutGeneral;
        DescriptorBufferInfo[4] bufferInfos;
        bufferInfos[0].buffer = _rasterTriangles.handle;
        bufferInfos[0].range = _rasterTriangles.size;
        bufferInfos[1].buffer = _rasterCandidates.handle;
        bufferInfos[1].range = _rasterCandidates.size;
        bufferInfos[2].buffer = _rasterStarts.handle;
        bufferInfos[2].range = _rasterStarts.size;
        bufferInfos[3].buffer = _rasterParams.handle;
        bufferInfos[3].range = _rasterParams.size;
        VkWriteDescriptorSet[5] writes;
        writes[0].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[0].dstSet = _rasterSet;
        writes[0].dstBinding = 0;
        writes[0].descriptorCount = 1;
        writes[0].descriptorType = DescriptorTypeStorageImage;
        writes[0].pImageInfo = &imageInfo;
        foreach (slot; 0 .. 4)
        {
            writes[slot + 1].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[slot + 1].dstSet = _rasterSet;
            writes[slot + 1].dstBinding = cast(uint) (slot + 1);
            writes[slot + 1].descriptorCount = 1;
            writes[slot + 1].descriptorType = DescriptorTypeStorageBuffer;
            writes[slot + 1].pBufferInfo = &bufferInfos[slot];
        }
        _vk.vkUpdateDescriptorSets(_device, 5, writes.ptr, 0, null);

        check(_vk.vkResetCommandBuffer(_commands, 0), "resetting commands");
        VkCommandBufferBeginInfo begin;
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        check(_vk.vkBeginCommandBuffer(_commands, &begin), "beginning commands");
        transitionStorage(_commands, _color, VK_IMAGE_LAYOUT_UNDEFINED,
            LayoutGeneral, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            PipelineStageCompute, 0, AccessShaderWrite);
        _vk.vkCmdBindPipeline(_commands, BindPointCompute, _rasterPipeline);
        _vk.vkCmdBindDescriptorSets(_commands, BindPointCompute, _rasterLayout, 0,
            1, &_rasterSet, 0, null);
        _cmdDispatch(_commands, (pixelCount + 63) / 64, 1, 1);
        transitionStorage(_commands, _color, LayoutGeneral, LayoutTransferSrc,
            PipelineStageCompute, VK_PIPELINE_STAGE_TRANSFER_BIT,
            AccessShaderWrite, AccessTransferRead);
        VkBufferImageCopy copy;
        copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        copy.imageSubresource.layerCount = 1;
        copy.imageExtent = VkExtent3D(cast(uint) width, cast(uint) height, 1);
        _cmdCopyImageToBuffer(_commands, _color, LayoutTransferSrc,
            _readback.handle, 1, &copy);
        check(_vk.vkEndCommandBuffer(_commands), "finishing the raster dispatch");
        submitAndWait();
        const submitTime = MonoTime.currTime();

        // Mapped device memory reads uncached, so pull it across in one bulk
        // copy. Per-pixel loads from the mapping cost more than the dispatch.
        import core.stdc.string : memcpy;
        stagingScratch.length = pixelCount * 4;
        memcpy(stagingScratch.ptr, _readback.mapped, pixelCount * 4);
        const bgra = cast(ubyte[]) stagingScratch[];
        bool any;
        int painted;
        foreach (pixel; 0 .. pixelCount)
        {
            const at = pixel * 4;
            // The kernel clears alpha where nothing was drawn.
            if (bgra[at + 3] == 0)
                continue;
            any = true;
            ++painted;
            const target = pixel * 3;
            // The target is BGRA, the frame is RGB.
            frame.pixels[target] = bgra[at + 2];
            frame.pixels[target + 1] = bgra[at + 1];
            frame.pixels[target + 2] = bgra[at];
        }
        // One dispatch covers the frame; the counts are what a viewer reports.
        _stats = GpuStats.init;
        _stats.drawCalls = 1;
        _stats.triangles = cast(int) triangles.length;
        _stats.lines = painted;
        _stats.uploadMs = (uploadTime - startTime).total!"usecs" / 1000.0;
        _stats.drawMs = (submitTime - uploadTime).total!"usecs" / 1000.0;
        _stats.readbackMs = (MonoTime.currTime() - submitTime).total!"usecs"
            / 1000.0;
        return any;
    }

    /// Rasterize two known triangles through the compute kernel: one red behind,
    /// one blue in front. Validates coverage, depth ordering and shading.
    bool smokeComputeRaster(out string report)
    {
        import auroramesh.mesh_shaders : computeRasterSpirv;
        import std.file : append, exists, remove;
        if (exists("build/raster.log"))
            remove("build/raster.log");
        void mark(string text)
        {
            append("build/raster.log", text ~ "\n");
        }
        mark("begin");
        ensureTargets(64, 64);
        mark("targets");
        const shader = shaderModule(computeRasterSpirv);
        mark("module");
        scope (exit) _vk.vkDestroyShaderModule(_device, shader, null);

        VkDeviceMemory imageMemory;
        const image = createImage(64, 64, VK_FORMAT_R8G8B8A8_UNORM,
            UsageStorage | UsageTransferSrc, imageMemory);
        scope (exit)
        {
            _vk.vkDestroyImage(_device, image, null);
            _vk.vkFreeMemory(_device, imageMemory, null);
        }
        const view = createView(image, VK_FORMAT_R8G8B8A8_UNORM);
        scope (exit) _vk.vkDestroyImageView(_device, view, null);

        // 16 floats per triangle: x, y, inverse depth, light for three corners,
        // then red, green, blue, alpha.
        enum triangleFloats = 16;
        const float[] triangleData = [
            4, 4, 2, 1, 60, 4, 2, 1, 4, 60, 2, 1, 1, 0, 0, 1,       // red, far
            10, 10, 4, 1, 30, 10, 4, 1, 10, 30, 4, 1, 0, 0, 1, 1,    // blue, near
        ];
        const triangleCount = triangleData.length / triangleFloats;

        // Bin candidate triangles per pixel, so one invocation per pixel can
        // resolve the nearest surface with a single loop and no atomics.
        enum pixelCount = 64 * 64;
        void visit(void delegate(uint pixel, uint triangle) sink)
        {
            foreach (index; 0 .. triangleCount)
            {
                const base = index * triangleFloats;
                const xs = [triangleData[base], triangleData[base + 4],
                            triangleData[base + 8]];
                const ys = [triangleData[base + 1], triangleData[base + 5],
                            triangleData[base + 9]];
                const lowX = cast(int) max(0.0, xs[0] < xs[1] ?
                    (xs[0] < xs[2] ? xs[0] : xs[2]) :
                    (xs[1] < xs[2] ? xs[1] : xs[2]));
                const lowY = cast(int) max(0.0, ys[0] < ys[1] ?
                    (ys[0] < ys[2] ? ys[0] : ys[2]) :
                    (ys[1] < ys[2] ? ys[1] : ys[2]));
                const highX = cast(int) min(63.0, xs[0] > xs[1] ?
                    (xs[0] > xs[2] ? xs[0] : xs[2]) :
                    (xs[1] > xs[2] ? xs[1] : xs[2]));
                const highY = cast(int) min(63.0, ys[0] > ys[1] ?
                    (ys[0] > ys[2] ? ys[0] : ys[2]) :
                    (ys[1] > ys[2] ? ys[1] : ys[2]));
                foreach (y; lowY .. highY + 1)
                    foreach (x; lowX .. highX + 1)
                        sink(cast(uint) ((y / 8) * 8 + (x / 8)),
                            cast(uint) index);
            }
        }
        enum tileCount = (64 / 8) * (64 / 8);
        uint[] counts;
        counts.length = tileCount;
        counts[] = 0;
        visit((tile, triangle) { counts[tile] += 1; });
        uint[] starts;
        starts.length = tileCount + 1;
        uint running;
        foreach (index; 0 .. tileCount)
        {
            starts[index] = running;
            running += counts[index];
        }
        starts[tileCount] = running;
        uint[] cursor = starts.dup;
        uint[] candidates;
        candidates.length = running;
        visit((tile, triangle) { candidates[cursor[tile]++] = triangle; });
        const uint[3] params = [64, 64, 64 / 8];
        mark("entries");

        auto triangles = createHostBuffer(triangleData.length * float.sizeof,
            BufferUsageStorage);
        scope (exit) destroyBuffer(triangles);
        triangles.mapped[0 .. triangleData.length * float.sizeof] =
            cast(ubyte[]) triangleData[];
        auto candidateBuffer = createHostBuffer(candidates.length * uint.sizeof,
            BufferUsageStorage);
        scope (exit) destroyBuffer(candidateBuffer);
        candidateBuffer.mapped[0 .. candidates.length * uint.sizeof] =
            cast(ubyte[]) candidates[];
        auto startBuffer = createHostBuffer(starts.length * uint.sizeof,
            BufferUsageStorage);
        scope (exit) destroyBuffer(startBuffer);
        startBuffer.mapped[0 .. starts.length * uint.sizeof] =
            cast(ubyte[]) starts[];
        auto paramBuffer = createHostBuffer(params.length * uint.sizeof,
            BufferUsageStorage);
        scope (exit) destroyBuffer(paramBuffer);
        paramBuffer.mapped[0 .. params.length * uint.sizeof] =
            cast(ubyte[]) params[];
        mark("buffers");

        VkDescriptorSetLayoutBinding[5] bindings;
        bindings[0].binding = 0;
        bindings[0].descriptorType = DescriptorTypeStorageImage;
        bindings[0].descriptorCount = 1;
        bindings[0].stageFlags = StageCompute;
        bindings[1].binding = 1;
        bindings[1].descriptorType = DescriptorTypeStorageBuffer;
        bindings[1].descriptorCount = 1;
        bindings[1].stageFlags = StageCompute;
        bindings[2].binding = 2;
        bindings[2].descriptorType = DescriptorTypeStorageBuffer;
        bindings[2].descriptorCount = 1;
        bindings[2].stageFlags = StageCompute;
        bindings[3].binding = 3;
        bindings[3].descriptorType = DescriptorTypeStorageBuffer;
        bindings[3].descriptorCount = 1;
        bindings[3].stageFlags = StageCompute;
        bindings[4].binding = 4;
        bindings[4].descriptorType = DescriptorTypeStorageBuffer;
        bindings[4].descriptorCount = 1;
        bindings[4].stageFlags = StageCompute;
        VkDescriptorSetLayoutCreateInfo setInfo;
        setInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        setInfo.bindingCount = 5;
        setInfo.pBindings = bindings.ptr;
        VkDescriptorSetLayout setLayout;
        check(_vk.vkCreateDescriptorSetLayout(_device, &setInfo, null, &setLayout),
            "creating the raster set layout");
        scope (exit) _vk.vkDestroyDescriptorSetLayout(_device, setLayout, null);
        PushConstantRange range;
        range.stageFlags = StageCompute;
        range.offset = 0;
        range.size = 4;
        VkPipelineLayoutCreateInfo layoutInfo;
        layoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        layoutInfo.setLayoutCount = 1;
        layoutInfo.pSetLayouts = &setLayout;
        layoutInfo.pushConstantRangeCount = 1;
        layoutInfo.pPushConstantRanges = &range;
        VkPipelineLayout layout;
        check(_vk.vkCreatePipelineLayout(_device, &layoutInfo, null, &layout),
            "creating the raster layout");
        scope (exit) _vk.vkDestroyPipelineLayout(_device, layout, null);
        VkDescriptorSetAllocateInfo allocate;
        allocate.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        allocate.descriptorPool = _descriptorPool;
        allocate.descriptorSetCount = 1;
        allocate.pSetLayouts = &setLayout;
        VkDescriptorSet set;
        check(_vk.vkAllocateDescriptorSets(_device, &allocate, &set),
            "allocating the raster descriptor set");
        VkDescriptorImageInfo imageInfo;
        imageInfo.imageView = view;
        imageInfo.imageLayout = LayoutGeneral;
        DescriptorBufferInfo[4] bufferInfos;
        bufferInfos[0].buffer = triangles.handle;
        bufferInfos[0].range = triangles.size;
        bufferInfos[1].buffer = candidateBuffer.handle;
        bufferInfos[1].range = candidateBuffer.size;
        bufferInfos[2].buffer = startBuffer.handle;
        bufferInfos[2].range = startBuffer.size;
        bufferInfos[3].buffer = paramBuffer.handle;
        bufferInfos[3].range = paramBuffer.size;
        VkWriteDescriptorSet[5] writes;
        writes[0].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[0].dstSet = set;
        writes[0].dstBinding = 0;
        writes[0].descriptorCount = 1;
        writes[0].descriptorType = DescriptorTypeStorageImage;
        writes[0].pImageInfo = &imageInfo;
        foreach (index; 0 .. 4)
        {
            writes[index + 1].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[index + 1].dstSet = set;
            writes[index + 1].dstBinding = cast(uint) (index + 1);
            writes[index + 1].descriptorCount = 1;
            writes[index + 1].descriptorType = DescriptorTypeStorageBuffer;
            writes[index + 1].pBufferInfo = &bufferInfos[index];
        }
        _vk.vkUpdateDescriptorSets(_device, 5, writes.ptr, 0, null);
        mark("descriptors");

        ComputePipelineInfo info;
        info.sType = StTypeComputePipeline;
        info.stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        info.stage.stage = StageCompute;
        info.stage.module_ = shader;
        info.stage.pName = "main".ptr;
        info.layout = layout;
        info.basePipelineIndex = -1;
        VkPipeline pipeline;
        mark("layout");
        check(_createComputePipelines(_device, VK_NULL_HANDLE, 1, &info, null,
            &pipeline), "creating the raster pipeline");
        mark("pipeline");
        scope (exit) _vk.vkDestroyPipeline(_device, pipeline, null);

        check(_vk.vkResetCommandBuffer(_commands, 0), "resetting commands");
        VkCommandBufferBeginInfo begin;
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        check(_vk.vkBeginCommandBuffer(_commands, &begin), "beginning commands");
        transitionStorage(_commands, image, VK_IMAGE_LAYOUT_UNDEFINED, LayoutGeneral,
            VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, PipelineStageCompute, 0,
            AccessShaderWrite);
        _vk.vkCmdBindPipeline(_commands, BindPointCompute, pipeline);
        _vk.vkCmdBindDescriptorSets(_commands, BindPointCompute, layout, 0, 1,
            &set, 0, null);
        _cmdDispatch(_commands, (pixelCount + 63) / 64, 1, 1);
        mark("dispatched");
        transitionStorage(_commands, image, LayoutGeneral, LayoutTransferSrc,
            PipelineStageCompute, VK_PIPELINE_STAGE_TRANSFER_BIT,
            AccessShaderWrite, AccessTransferRead);
        VkBufferImageCopy copy;
        copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        copy.imageSubresource.layerCount = 1;
        copy.imageExtent = VkExtent3D(64, 64, 1);
        _cmdCopyImageToBuffer(_commands, image, LayoutTransferSrc,
            _readback.handle, 1, &copy);
        check(_vk.vkEndCommandBuffer(_commands), "finishing the raster dispatch");
        mark("recorded");
        submitAndWait();
        mark("submitted");

        const result = cast(ubyte[]) _readback.mapped[0 .. 64 * 64 * 4];
        const redOnly = (10 * 64 + 50) * 4;   // inside the red triangle only
        const overlapping = (13 * 64 + 20) * 4; // blue in front of red
        report = format("covered %s %s %s a%s (expect 127 0 0 a255); overlap "
            ~ "%s %s %s a%s (expect 0 0 63 a255); %s candidates", result[redOnly],
            result[redOnly + 1], result[redOnly + 2], result[redOnly + 3],
            result[overlapping], result[overlapping + 1],
            result[overlapping + 2], result[overlapping + 3],
            candidates.length);
        // Red only where the far triangle is; the near blue triangle must win the
        // overlap, which is what the per-pixel depth resolve guarantees.
        return result[redOnly] > 100 && result[redOnly + 1] < 40 &&
            result[redOnly + 2] < 40 && result[redOnly + 3] > 200 &&
            result[overlapping] < 40 && result[overlapping + 1] < 40 &&
            result[overlapping + 2] > 40 && result[overlapping + 3] > 200;
    }

    bool selfTest(out string report, string only = "")
    {
        import aurora.vulkan.shaders : fragmentShaderSpirv, vertexShaderSpirv;
        const vertexModule = shaderModule(vertexShaderSpirv);
        const fragmentModule = shaderModule(fragmentShaderSpirv);
        const myVertexModule = shaderModule(meshVertexSpirv);
        const myMeshModule = shaderModule(meshFragmentSpirv);
        const myFlatModule = shaderModule(flatFragmentSpirv);
        const positionModule = shaderModule(meshVertexPositionSpirv);
        const tintModule = shaderModule(meshVertexTintSpirv);
        const passthroughModule = shaderModule(meshVertexPassthroughSpirv);
        const constantModule = shaderModule(constantFragmentSpirv);
        scope (exit)
        {
            _vk.vkDestroyShaderModule(_device, vertexModule, null);
            _vk.vkDestroyShaderModule(_device, fragmentModule, null);
            _vk.vkDestroyShaderModule(_device, myVertexModule, null);
            _vk.vkDestroyShaderModule(_device, myMeshModule, null);
            _vk.vkDestroyShaderModule(_device, myFlatModule, null);
            _vk.vkDestroyShaderModule(_device, positionModule, null);
            _vk.vkDestroyShaderModule(_device, tintModule, null);
            _vk.vkDestroyShaderModule(_device, passthroughModule, null);
            _vk.vkDestroyShaderModule(_device, constantModule, null);
        }
        VkVertexInputBindingDescription binding;
        binding.binding = 0;
        binding.stride = 24;
        binding.inputRate = VK_VERTEX_INPUT_RATE_VERTEX;
        auto meshBinding = binding;
        meshBinding.stride = GpuVertex.sizeof;
        VkVertexInputAttributeDescription[2] auroraAttributes;
        auroraAttributes[0].location = 0;
        auroraAttributes[0].format = VK_FORMAT_R32G32_SFLOAT;
        auroraAttributes[0].offset = 0;
        auroraAttributes[1].location = 1;
        auroraAttributes[1].format = VK_FORMAT_R32G32B32A32_SFLOAT;
        auroraAttributes[1].offset = 8;
        VkVertexInputAttributeDescription[3] meshAttributes;
        meshAttributes[0].location = 0;
        meshAttributes[0].format = VK_FORMAT_R32G32B32A32_SFLOAT;
        meshAttributes[0].offset = 0;
        meshAttributes[1].location = 1;
        meshAttributes[1].format = VK_FORMAT_R32G32B32A32_SFLOAT;
        meshAttributes[1].offset = 16;
        meshAttributes[2].location = 2;
        meshAttributes[2].format = VK_FORMAT_R32G32_SFLOAT;
        meshAttributes[2].offset = 32;

        string[] notes;
        bool attempt(string label, VkShaderModule vertex,
            VkShaderModule fragment, VkVertexInputBindingDescription bindingInfo,
            VkVertexInputAttributeDescription[] attributes)
        {
            if (only.length > 0 && only != label)
                return true;
            VkPipelineShaderStageCreateInfo[2] stages;
            stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
            stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
            stages[0].module_ = vertex;
            stages[0].pName = "main".ptr;
            stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
            stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
            stages[1].module_ = fragment;
            stages[1].pName = "main".ptr;
            traceStep("selftest " ~ label);
            try
            {
                auto pipeline = buildPipeline(stages.ptr, bindingInfo, attributes,
                    VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, PolygonModeFill, true,
                    false, label);
                _vk.vkDestroyPipeline(_device, pipeline, null);
                notes ~= label ~ ": ok";
                return true;
            }
            catch (Exception error)
            {
                notes ~= label ~ ": " ~ error.msg;
                return false;
            }
        }

        const auroraOk = attempt("aurora-shaders", vertexModule, fragmentModule,
            binding, auroraAttributes);
        // Two probes decide whether the generated modules or the vertex input
        // layout is what this driver rejects.
        auto threeBinding = binding;
        threeBinding.stride = 32;
        VkVertexInputAttributeDescription[3] auroraThreeAttributes =
            [auroraAttributes[0], auroraAttributes[1],
             VkVertexInputAttributeDescription(2, 0, VK_FORMAT_R32G32_SFLOAT, 24)];
        const auroraThreeOk = attempt("aurora-shaders-three-attributes",
            vertexModule, fragmentModule, threeBinding,
            auroraThreeAttributes[]);
        const passthroughOneOk = attempt("passthrough-one-attribute",
            passthroughModule, myFlatModule, meshBinding,
            [meshAttributes[0]]);
        // The mismatch probe must fail cleanly if the vertex module itself is
        // acceptable; a crash here blames the vertex module.
        const mismatchOk = attempt("passthrough-aurora-fragment-mismatch",
            passthroughModule, fragmentModule, meshBinding, [meshAttributes[0]]);
        const constantOk = attempt("passthrough-constant-fragment",
            passthroughModule, constantModule, meshBinding, [meshAttributes[0]]);
        // Every remaining pair uses the production vertex layout, so a shader
        // interface mismatch cannot be mistaken for a shader defect.
        const passthroughOk = attempt("generated-passthrough", passthroughModule,
            myFlatModule, meshBinding, meshAttributes[]);
        const positionOk = attempt("generated-position-only", positionModule,
            myFlatModule, meshBinding, meshAttributes[]);
        const tintOk = attempt("generated-position-tint", tintModule,
            myFlatModule, meshBinding, meshAttributes[]);
        const flatOk = attempt("generated-vertex-flat-fragment", myVertexModule,
            myFlatModule, meshBinding, meshAttributes[]);
        const isolatedVertex = attempt("generated-vertex-aurora-fragment",
            myVertexModule, fragmentModule, meshBinding, meshAttributes[]);
        const isolatedFlat = attempt("aurora-vertex-generated-fragment",
            vertexModule, myFlatModule, binding, auroraAttributes);
        const meshOk = attempt("generated-vertex-mesh-fragment", myVertexModule,
            myMeshModule, meshBinding, meshAttributes[]);
        report = notes.join("; ");
        return auroraOk && auroraThreeOk && passthroughOneOk && passthroughOk &&
            positionOk && tintOk && flatOk && isolatedVertex && isolatedFlat &&
            meshOk;
    }

    /// Timings and counters from the most recent render.
    GpuStats stats() const
    {
        return _stats;
    }

    /**
     * Draw the mesh and return the image. Geometry upload is skipped when the
     * mesh is unchanged, which keeps a static pose free of buffer traffic.
     */
    RgbFrame render(const Mesh mesh, const Camera camera, int width, int height,
        RenderOptions options = RenderOptions())
    {
        width = max(1, width);
        height = max(1, height);
        ensureTargets(width, height);

        const uploadStart = MonoTime.currTime();
        ensureGeometry(mesh);
        updateUniforms(camera, width, height, options);
        _stats.uploadMs = (MonoTime.currTime() - uploadStart).total!"usecs" / 1000.0;

        const drawStart = MonoTime.currTime();
        recordCommands(options);
        _stats.drawMs = (MonoTime.currTime() - drawStart).total!"usecs" / 1000.0;

        const readStart = MonoTime.currTime();
        auto frame = readback(width, height);
        _stats.readbackMs = (MonoTime.currTime() - readStart).total!"usecs" / 1000.0;
        if (tracing)
        {
            const middle = (height / 2) * width + width / 2;
            traceStep(format("pixels corner %s %s %s centre %s %s %s",
                frame.pixels[0], frame.pixels[1], frame.pixels[2],
                frame.pixels[middle * 3], frame.pixels[middle * 3 + 1],
                frame.pixels[middle * 3 + 2]));
            // A collapsed draw leaves a single pixel, so count and locate the
            // pixels that differ from the top-left one.
            int drawn;
            int first = -1;
            foreach (index; 0 .. width * height)
            {
                const at = index * 3;
                if (frame.pixels[at] != frame.pixels[0] ||
                    frame.pixels[at + 1] != frame.pixels[1] ||
                    frame.pixels[at + 2] != frame.pixels[2])
                {
                    if (first < 0)
                        first = index;
                    drawn++;
                }
            }
            traceStep(format("drawn pixels %s first %s", drawn,
                first < 0 ? "none" : format("%s,%s", first % width,
                    first / width)));
        }
        return frame;
    }

    // ---- device setup -----------------------------------------------------

    private string _deviceName;

    private void createInstance()
    {
        // Aurora's loader wrapper resolves the surface entry points eagerly, so
        // the instance has to expose VK_KHR_surface even though this renderer
        // never presents anything.
        uint available;
        _vk.vkEnumerateInstanceExtensionProperties(null, &available, null);
        auto properties = new VkExtensionProperties[available];
        _vk.vkEnumerateInstanceExtensionProperties(null, &available,
            properties.ptr);
        bool offered(string name)
        {
            foreach (ref property; properties)
            {
                size_t length;
                while (length < 256 && property.extensionName[length] != 0)
                    length++;
                if (cast(string) property.extensionName[0 .. length] == name)
                    return true;
            }
            return false;
        }
        // Aurora's loader wrapper resolves the WSI entry points eagerly, so the
        // surface extensions stay enabled even though this renderer never
        // presents.
        string[] extensions = ["VK_KHR_surface"];
        version (Windows)
            extensions ~= "VK_KHR_win32_surface";
        else version (linux)
            extensions ~= "VK_KHR_xlib_surface";
        else version (OSX)
            extensions ~= "VK_EXT_metal_surface";
        const(char)*[] names;
        foreach (extension; extensions)
            if (offered(extension))
                names ~= extension.toStringz;
        if (names.length == 0)
            throw new Exception("Vulkan does not offer VK_KHR_surface");

        VkApplicationInfo application;
        application.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
        application.pApplicationName = "aurora-mesh".toStringz;
        application.applicationVersion = 1;
        application.pEngineName = "aurora".toStringz;
        application.engineVersion = 1;
        // 1.1 keeps the driver on its current path instead of the 1.0 legacy
        // one; the renderer uses no 1.1 entry points.
        application.apiVersion = 0x00401000;
        VkInstanceCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        info.pApplicationInfo = &application;
        info.enabledExtensionCount = cast(uint) names.length;
        info.ppEnabledExtensionNames = names.ptr;
        // On a hybrid laptop NVIDIA's Optimus layer is what routes rendering to
        // the discrete GPU, so enable it whenever the loader offers it.
        uint layerCount;
        _vk.vkEnumerateInstanceLayerProperties(&layerCount, null);
        auto layers = new VkLayerProperties[layerCount];
        _vk.vkEnumerateInstanceLayerProperties(&layerCount, layers.ptr);
        const(char)*[] layerNames;
        foreach (ref layer; layers)
        {
            size_t length;
            while (length < 256 && layer.layerName[length] != 0)
                length++;
            const name = cast(string) layer.layerName[0 .. length];
            if (name == "VK_LAYER_NV_optimus")
                layerNames ~= "VK_LAYER_NV_optimus".toStringz;
        }
        info.enabledLayerCount = cast(uint) layerNames.length;
        info.ppEnabledLayerNames = layerNames.ptr;
        check(_vk.vkCreateInstance(&info, null, &_instance),
            "creating a Vulkan instance");
    }

    private void choosePhysicalDevice()
    {
        uint count;
        check(_vk.vkEnumeratePhysicalDevices(_instance, &count, null),
            "counting Vulkan devices");
        if (count == 0)
            throw new Exception("no Vulkan physical device is available");
        auto devices = new VkPhysicalDevice[count];
        check(_vk.vkEnumeratePhysicalDevices(_instance, &count, devices.ptr),
            "enumerating Vulkan devices");
        int seen;
        foreach (device; devices)
        {
            uint families;
            _vk.vkGetPhysicalDeviceQueueFamilyProperties(device, &families, null);
            if (families == 0)
                continue;
            auto properties = new VkQueueFamilyProperties[families];
            _vk.vkGetPhysicalDeviceQueueFamilyProperties(device, &families,
                properties.ptr);
            foreach (index, family; properties)
                if ((family.queueFlags & VK_QUEUE_GRAPHICS_BIT) != 0 &&
                    family.queueCount > 0)
                {
                    traceStep(format("device %s family %s", seen, index));
                    if (seen++ != gpuDeviceIndex)
                        break;
                    _physicalDevice = device;
                    _family = cast(uint) index;
                    return;
                }
        }
        throw new Exception(format(
            "no Vulkan device at index %s exposes a graphics queue",
            gpuDeviceIndex));
    }

    private void createDevice()
    {
        // Aurora's loader wrapper resolves the WSI entry points eagerly, so
        // VK_KHR_swapchain stays enabled even for this offscreen renderer.
        uint available;
        _vk.vkEnumerateDeviceExtensionProperties(_physicalDevice, null,
            &available, null);
        auto properties = new VkExtensionProperties[available];
        _vk.vkEnumerateDeviceExtensionProperties(_physicalDevice, null,
            &available, properties.ptr);
        bool offered(string name)
        {
            foreach (ref property; properties)
            {
                size_t length;
                while (length < 256 && property.extensionName[length] != 0)
                    length++;
                if (cast(string) property.extensionName[0 .. length] == name)
                    return true;
            }
            return false;
        }
        const(char)*[] names;
        if (offered("VK_KHR_swapchain"))
            names ~= "VK_KHR_swapchain".toStringz;
        else
            throw new Exception("the Vulkan device does not offer VK_KHR_swapchain");
        if (offered("VK_KHR_portability_subset"))
            names ~= "VK_KHR_portability_subset".toStringz;

        float priority = 1.0f;
        VkDeviceQueueCreateInfo queue;
        queue.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        queue.queueFamilyIndex = _family;
        queue.queueCount = 1;
        queue.pQueuePriorities = &priority;
        VkDeviceCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        info.queueCreateInfoCount = 1;
        info.pQueueCreateInfos = &queue;
        info.enabledExtensionCount = cast(uint) names.length;
        info.ppEnabledExtensionNames = names.ptr;
        // Pipeline statistics are opt-in; the diagnostics need them.
        PhysicalFeatures features;
        features.flags[PipelineStatisticsQueryFeature] = 1;
        info.pEnabledFeatures = &features;
        check(_vk.vkCreateDevice(_physicalDevice, &info, null, &_device),
            "creating a Vulkan device");
        _deviceName = queryDeviceName();
        backendName = _deviceName;
    }

    private string queryDeviceName()
    {
        auto procedure = cast(PFN_vkGetPhysicalDeviceProperties) _vk
            .vkGetInstanceProcAddr(_instance,
                "vkGetPhysicalDeviceProperties".toStringz);
        if (procedure is null)
            return "Vulkan";
        DevicePropertiesPrefix properties;
        procedure(_physicalDevice, &properties);
        size_t length;
        while (length < properties.deviceName.length &&
            properties.deviceName[length] != 0)
            length++;
        if (length == 0)
            return "Vulkan";
        return cast(string) properties.deviceName[0 .. length].idup;
    }

    private void createCommandResources()
    {
        VkCommandPoolCreateInfo poolInfo;
        poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        poolInfo.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        poolInfo.queueFamilyIndex = _family;
        check(_vk.vkCreateCommandPool(_device, &poolInfo, null, &_pool),
            "creating a Vulkan command pool");
        VkCommandBufferAllocateInfo allocate;
        allocate.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        allocate.commandPool = _pool;
        allocate.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        allocate.commandBufferCount = 1;
        check(_vk.vkAllocateCommandBuffers(_device, &allocate, &_commands),
            "allocating a Vulkan command buffer");
        VkFenceCreateInfo fence;
        fence.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        check(_vk.vkCreateFence(_device, &fence, null, &_fence),
            "creating a Vulkan fence");
    }

    private void createDescriptors()
    {
        VkDescriptorSetLayoutBinding[2] bindings;
        bindings[0].binding = 0;
        bindings[0].descriptorType = DescriptorUniformBuffer;
        bindings[0].descriptorCount = 1;
        bindings[0].stageFlags = VK_SHADER_STAGE_VERTEX_BIT;
        bindings[1].binding = 1;
        bindings[1].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        bindings[1].descriptorCount = 1;
        bindings[1].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
        VkDescriptorSetLayoutCreateInfo layout;
        layout.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        layout.bindingCount = 2;
        layout.pBindings = bindings.ptr;
        check(_vk.vkCreateDescriptorSetLayout(_device, &layout, null, &_setLayout),
            "creating the descriptor set layout");
        VkDescriptorPoolSize[4] poolSizes;
        poolSizes[0].type = DescriptorUniformBuffer;
        poolSizes[0].descriptorCount = 64;
        poolSizes[1].type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        poolSizes[1].descriptorCount = 64;
        // Storage descriptors for the compute rasterizer path.
        poolSizes[2].type = DescriptorTypeStorageImage;
        poolSizes[2].descriptorCount = 64;
        poolSizes[3].type = DescriptorTypeStorageBuffer;
        poolSizes[3].descriptorCount = 64;
        VkDescriptorPoolCreateInfo pool;
        pool.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        pool.maxSets = 64;
        pool.poolSizeCount = 4;
        pool.pPoolSizes = poolSizes.ptr;
        check(_vk.vkCreateDescriptorPool(_device, &pool, null, &_descriptorPool),
            "creating the descriptor pool");
        // Descriptor writes point at the uniform buffer, so allocate it before
        // any material binds it.
        _uniforms = createHostBuffer(160, UsageUniformBuffer);
    }

    private void createRenderPass()
    {
        VkAttachmentDescription[1] attachments;
        attachments[0].format = TargetFormat;
        attachments[0].samples = VK_SAMPLE_COUNT_1_BIT;
        attachments[0].loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
        attachments[0].storeOp = VK_ATTACHMENT_STORE_OP_STORE;
        attachments[0].stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        attachments[0].stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
        attachments[0].initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        attachments[0].finalLayout = LayoutTransferSrc;

        VkAttachmentReference colorReference;
        colorReference.attachment = 0;
        colorReference.layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        VkSubpassDescription subpass;
        subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &colorReference;
        VkSubpassDependency[2] dependencies;
        dependencies[0].srcSubpass = VK_SUBPASS_EXTERNAL;
        dependencies[0].dstSubpass = 0;
        dependencies[0].srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dependencies[0].dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dependencies[0].dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        dependencies[0].dependencyFlags = VK_DEPENDENCY_BY_REGION_BIT;
        dependencies[1].srcSubpass = 0;
        dependencies[1].dstSubpass = VK_SUBPASS_EXTERNAL;
        dependencies[1].srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dependencies[1].dstStageMask = VK_PIPELINE_STAGE_TRANSFER_BIT;
        dependencies[1].srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        dependencies[1].dstAccessMask = AccessTransferRead;
        dependencies[1].dependencyFlags = VK_DEPENDENCY_BY_REGION_BIT;
        VkRenderPassCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        info.attachmentCount = 1;
        info.pAttachments = attachments.ptr;
        info.subpassCount = 1;
        info.pSubpasses = &subpass;
        info.dependencyCount = 2;
        info.pDependencies = dependencies.ptr;
        check(_vk.vkCreateRenderPass(_device, &info, null, &_renderPass),
            "creating the render pass");
    }

    private VkShaderModule shaderModule(const(uint)[] words)
    {
        VkShaderModuleCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
        info.codeSize = words.length * uint.sizeof;
        info.pCode = words.ptr;
        VkShaderModule handle;
        check(_vk.vkCreateShaderModule(_device, &info, null, &handle),
            "creating a shader module");
        return handle;
    }

    private void createPipelines()
    {
        const vertexModule = shaderModule(meshVertexSpirv);
        traceStep("vertex module");
        const meshModule = shaderModule(meshFragmentSpirv);
        traceStep("mesh fragment module");
        const flatModule = shaderModule(flatFragmentSpirv);
        traceStep("flat fragment module");
        const probeModule = shaderModule(constantFragmentSpirv);
        scope (exit)
        {
            _vk.vkDestroyShaderModule(_device, vertexModule, null);
            _vk.vkDestroyShaderModule(_device, meshModule, null);
            _vk.vkDestroyShaderModule(_device, flatModule, null);
            _vk.vkDestroyShaderModule(_device, probeModule, null);
        }
        createMeshPipeline(vertexModule, meshModule, flatModule, probeModule);
    }

    private void createPipelineLayout()
    {
        PushConstantRange range;
        range.stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT;
        range.offset = 0;
        range.size = 16;
        VkPipelineLayoutCreateInfo layout;
        layout.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        layout.setLayoutCount = 1;
        layout.pSetLayouts = &_setLayout;
        layout.pushConstantRangeCount = 1;
        layout.pPushConstantRanges = &range;
        check(_vk.vkCreatePipelineLayout(_device, &layout, null, &_pipelineLayout),
            "creating the pipeline layout");
        traceStep("layout ready");
    }

    private void createMeshPipeline(VkShaderModule vertexModule,
        VkShaderModule meshModule, VkShaderModule flatModule,
        VkShaderModule probeModule)
    {
        VkPipelineShaderStageCreateInfo[2] meshStages;
        meshStages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        meshStages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
        meshStages[0].module_ = vertexModule;
        meshStages[0].pName = "main".ptr;
        meshStages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        meshStages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
        meshStages[1].module_ = meshModule;
        meshStages[1].pName = "main".ptr;

        VkVertexInputBindingDescription binding;
        binding.binding = 0;
        binding.stride = GpuVertex.sizeof;
        binding.inputRate = VK_VERTEX_INPUT_RATE_VERTEX;
        VkVertexInputAttributeDescription[3] attributes;
        attributes[0].location = 0;
        attributes[0].format = VK_FORMAT_R32G32B32A32_SFLOAT;
        attributes[0].offset = 0;
        attributes[1].location = 1;
        attributes[1].format = VK_FORMAT_R32G32B32A32_SFLOAT;
        attributes[1].offset = 16;
        attributes[2].location = 2;
        attributes[2].format = VK_FORMAT_R32G32_SFLOAT;
        attributes[2].offset = 32;

        _meshPipeline = buildPipeline(meshStages.ptr, binding, attributes,
            VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, PolygonModeFill, true, false,
            "mesh");

        VkPipelineShaderStageCreateInfo[2] lineStages;
        lineStages[0] = meshStages[0];
        lineStages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        lineStages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
        // Diagnostic: a constant colour proves fragments reach the attachments.
        lineStages[1].module_ = probeModule;
        lineStages[1].pName = "main".ptr;
        _linePipeline = buildPipeline(lineStages.ptr, binding, attributes,
            TopologyLineList, PolygonModeFill, false, false, "lines");
        _pointPipeline = buildPipeline(lineStages.ptr, binding, attributes,
            TopologyPointList, PolygonModePoint, false, false, "points");
    }

    private VkPipeline buildPipeline(const(VkPipelineShaderStageCreateInfo)* stages,
        VkVertexInputBindingDescription binding,
        VkVertexInputAttributeDescription[] attributes, int topology,
        int polygonMode, bool writeDepth, bool cull, string label,
        VkPipelineLayout layoutOverride = VK_NULL_HANDLE)
    {
        traceStep("pipeline " ~ label ~ " setup");
        VkPipelineVertexInputStateCreateInfo vertexInput;
        vertexInput.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vertexInput.vertexBindingDescriptionCount = 1;
        vertexInput.pVertexBindingDescriptions = &binding;
        vertexInput.vertexAttributeDescriptionCount =
            cast(uint) attributes.length;
        vertexInput.pVertexAttributeDescriptions = attributes.ptr;
        VkPipelineInputAssemblyStateCreateInfo assembly;
        assembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        assembly.topology = topology;
        VkPipelineViewportStateCreateInfo viewport;
        viewport.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        viewport.viewportCount = 1;
        viewport.scissorCount = 1;
        // Dynamic state wins at draw time; pinning a full-extent static viewport
        // and scissor keeps the pipeline valid for drivers that read them anyway.
        VkViewport defaultViewport;
        defaultViewport.width = 16384;
        defaultViewport.height = 16384;
        defaultViewport.maxDepth = 1.0f;
        VkRect2D defaultScissor;
        defaultScissor.extent = VkExtent2D(16384, 16384);
        viewport.pViewports = &defaultViewport;
        viewport.pScissors = &defaultScissor;
        VkPipelineRasterizationStateCreateInfo raster;
        raster.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        raster.polygonMode = polygonMode;
        raster.cullMode = cull ? CullBackFace : 0;
        raster.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
        raster.lineWidth = 1.0f;
        VkPipelineMultisampleStateCreateInfo multisample;
        multisample.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
        // The offscreen pass has a single colour attachment, so the pipeline
        // leaves depth state unset; ordering comes from the painter's algorithm
        // the mesh already provides.
        DepthStencilState depth;
        depth.sType = StTypePipelineDepthStencil;
        depth.depthTestEnable = VK_FALSE;
        depth.depthWriteEnable = VK_FALSE;
        depth.depthCompareOp = CompareLessOrEqual;
        VkPipelineColorBlendAttachmentState blend;
        blend.colorWriteMask = VK_COLOR_COMPONENT_R_BIT |
            VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT |
            VK_COLOR_COMPONENT_A_BIT;
        VkPipelineColorBlendStateCreateInfo colorBlend;
        colorBlend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        colorBlend.attachmentCount = 1;
        colorBlend.pAttachments = &blend;
        int[2] dynamicStates = [VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR];
        VkPipelineDynamicStateCreateInfo dynamic;
        dynamic.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dynamic.dynamicStateCount = 0;
        dynamic.pDynamicStates = null;
        VkGraphicsPipelineCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        info.stageCount = 2;
        info.pStages = stages;
        info.pVertexInputState = &vertexInput;
        info.pInputAssemblyState = &assembly;
        info.pViewportState = &viewport;
        info.pRasterizationState = &raster;
        info.pMultisampleState = &multisample;
        info.pDepthStencilState = null;
        info.pColorBlendState = &colorBlend;
        info.pDynamicState = &dynamic;
        info.layout = layoutOverride ? layoutOverride : _pipelineLayout;
        info.renderPass = _renderPass;
        VkPipeline pipeline;
        traceStep("pipeline " ~ label ~ " create");
        check(_vk.vkCreateGraphicsPipelines(_device, VK_NULL_HANDLE, 1, &info,
            null, &pipeline), "creating a graphics pipeline");
        traceStep("pipeline " ~ label ~ " ready");
        return pipeline;
    }

    // ---- targets ----------------------------------------------------------

    private void ensureTargets(int width, int height)
    {
        if (width == _width && height == _height && _framebuffer)
            return;
        _vk.vkDeviceWaitIdle(_device);
        destroyTargets();
        _width = width;
        _height = height;
        _color = createImage(width, height, TargetFormat,
            VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | UsageTransferSrc | UsageStorage,
            _colorMemory);
        _colorView = createView(_color, TargetFormat);
        _depth = createImage(width, height, FormatDepth32, UsageDepthStencil,
            _depthMemory);
        _depthView = createView(_depth, FormatDepth32);
        VkImageView[1] views = [_colorView];
        VkFramebufferCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        info.renderPass = _renderPass;
        info.attachmentCount = 1;
        info.pAttachments = views.ptr;
        info.width = cast(uint) width;
        info.height = cast(uint) height;
        info.layers = 1;
        check(_vk.vkCreateFramebuffer(_device, &info, null, &_framebuffer),
            "creating the framebuffer");
        destroyBuffer(_readback);
        _readback = createHostBuffer(cast(VkDeviceSize) width * height * 4);
    }

    private void destroyTargets()
    {
        destroyBuffer(_readback);
        _readback = Buffer.init;
        if (_framebuffer)
        {
            _vk.vkDestroyFramebuffer(_device, _framebuffer, null);
            _framebuffer = VK_NULL_HANDLE;
        }
        if (_colorView)
        {
            _vk.vkDestroyImageView(_device, _colorView, null);
            _colorView = VK_NULL_HANDLE;
        }
        if (_depthView)
        {
            _vk.vkDestroyImageView(_device, _depthView, null);
            _depthView = VK_NULL_HANDLE;
        }
        if (_color)
        {
            _vk.vkDestroyImage(_device, _color, null);
            _color = VK_NULL_HANDLE;
        }
        if (_depth)
        {
            _vk.vkDestroyImage(_device, _depth, null);
            _depth = VK_NULL_HANDLE;
        }
        if (_colorMemory)
        {
            _vk.vkFreeMemory(_device, _colorMemory, null);
            _colorMemory = VK_NULL_HANDLE;
        }
        if (_depthMemory)
        {
            _vk.vkFreeMemory(_device, _depthMemory, null);
            _depthMemory = VK_NULL_HANDLE;
        }
        _width = _height = 0;
    }

    private VkImage createImage(int width, int height, int format, uint usage,
        ref VkDeviceMemory memory)
    {
        VkImageCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        info.imageType = VK_IMAGE_TYPE_2D;
        info.format = format;
        info.extent = VkExtent3D(cast(uint) width, cast(uint) height, 1);
        info.mipLevels = 1;
        info.arrayLayers = 1;
        info.samples = VK_SAMPLE_COUNT_1_BIT;
        info.tiling = VK_IMAGE_TILING_OPTIMAL;
        info.usage = usage;
        info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        VkImage image;
        check(_vk.vkCreateImage(_device, &info, null, &image),
            "creating an image");
        VkMemoryRequirements requirements;
        _vk.vkGetImageMemoryRequirements(_device, image, &requirements);
        VkMemoryAllocateInfo allocate;
        allocate.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        allocate.allocationSize = requirements.size;
        allocate.memoryTypeIndex = findMemoryType(requirements.memoryTypeBits,
            VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        check(_vk.vkAllocateMemory(_device, &allocate, null, &memory),
            "allocating image memory");
        check(_vk.vkBindImageMemory(_device, image, memory, 0),
            "binding image memory");
        return image;
    }

    private VkImageView createView(VkImage image, int format)
    {
        VkImageViewCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        info.image = image;
        info.viewType = VK_IMAGE_VIEW_TYPE_2D;
        info.format = format;
        info.subresourceRange.aspectMask =
            format == FormatDepth32 ? 0x00000002 : VK_IMAGE_ASPECT_COLOR_BIT;
        info.subresourceRange.levelCount = 1;
        info.subresourceRange.layerCount = 1;
        VkImageView view;
        check(_vk.vkCreateImageView(_device, &info, null, &view),
            "creating an image view");
        return view;
    }

    private uint findMemoryType(uint allowed, VkFlags required) const
    {
        foreach (index; 0 .. _memory.memoryTypeCount)
            if ((allowed & (1u << index)) != 0 &&
                (_memory.memoryTypes[index].propertyFlags & required) == required)
                return index;
        throw new Exception("no Vulkan memory type matches the requirement");
    }

    /// Reuse an upload buffer, growing it only when the frame needs more room.
    private void ensureRasterBuffer(ref Buffer buffer, VkDeviceSize needed)
    {
        if (buffer.handle !is VK_NULL_HANDLE && buffer.handle != 0 &&
            buffer.size >= needed)
            return;
        destroyBuffer(buffer);
        buffer = createHostBuffer(needed, BufferUsageStorage);
    }

    private Buffer createHostBuffer(VkDeviceSize size, uint usage = 0)
    {
        VkBufferCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        info.size = size;
        info.usage = usage | VK_BUFFER_USAGE_TRANSFER_DST_BIT;
        info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        Buffer buffer;
        buffer.size = size;
        buffer.usage = usage;
        check(_vk.vkCreateBuffer(_device, &info, null, &buffer.handle),
            "creating a buffer");
        VkMemoryRequirements requirements;
        _vk.vkGetBufferMemoryRequirements(_device, buffer.handle, &requirements);
        VkMemoryAllocateInfo allocate;
        allocate.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        allocate.allocationSize = requirements.size;
        // Prefer a cached type when it is coherent as well. The viewport reads the
        // frame back every frame, and a write-combined mapping reads at a few
        // hundred MB/s, which cost more than a whole software frame. Requiring
        // coherent too means no explicit invalidation is needed.
        const wanted = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
            VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        uint cachedType = uint.max;
        foreach (index; 0 .. _memory.memoryTypeCount)
            if ((requirements.memoryTypeBits & (1u << index)) != 0 &&
                (_memory.memoryTypes[index].propertyFlags & (wanted | 0x8)) ==
                (wanted | 0x8)) // 0x8 is HOST_CACHED
                cachedType = index;
        allocate.memoryTypeIndex = cachedType != uint.max ? cachedType :
            findMemoryType(requirements.memoryTypeBits, wanted);
        check(_vk.vkAllocateMemory(_device, &allocate, null, &buffer.memory),
            "allocating buffer memory");
        check(_vk.vkBindBufferMemory(_device, buffer.handle, buffer.memory, 0),
            "binding buffer memory");
        check(_vk.vkMapMemory(_device, buffer.memory, 0, size, 0, &buffer.mapped),
            "mapping buffer memory");
        return buffer;
    }


    private void destroyBuffer(ref Buffer buffer)
    {
        if (buffer.handle is VK_NULL_HANDLE || buffer.handle == 0)
            return;
        if (buffer.mapped !is null)
            _vk.vkUnmapMemory(_device, buffer.memory);
        _vk.vkDestroyBuffer(_device, buffer.handle, null);
        _vk.vkFreeMemory(_device, buffer.memory, null);
        buffer = Buffer.init;
    }

    // ---- geometry ---------------------------------------------------------

    private void ensureGeometry(const Mesh mesh)
    {
        size_t hash = 0xcbf29ce484222325UL;
        void mix(ulong value)
        {
            hash = (hash ^ value) * 0x100000001b3UL;
        }
        mix(mesh.vertices.length);
        mix(mesh.faces.length);
        foreach (vertex; mesh.vertices)
        {
            mix(cast(ulong) (cast(long) (vertex.x * 8192.0)));
            mix(cast(ulong) (cast(long) (vertex.y * 8192.0)));
            mix(cast(ulong) (cast(long) (vertex.z * 8192.0)));
        }
        if (hash == _meshHash && mesh.vertices.length == _meshVertices)
            return;
        _meshHash = hash;
        _meshVertices = cast(int) mesh.vertices.length;
        _meshFaces = cast(int) mesh.faces.length;

        auto gpuVertices = new GpuVertex[mesh.vertices.length];
        const hasNormals = mesh.normals.length == mesh.vertices.length;
        const hasUvs = mesh.uvs.length == mesh.vertices.length;
        foreach (index, vertex; mesh.vertices)
        {
            float[10] values;
            values[0] = cast(float) vertex.x;
            values[1] = cast(float) vertex.y;
            values[2] = cast(float) vertex.z;
            values[3] = 1.0f;
            if (hasNormals)
            {
                values[4] = cast(float) mesh.normals[index].x;
                values[5] = cast(float) mesh.normals[index].y;
                values[6] = cast(float) mesh.normals[index].z;
                values[7] = 0.0f;
            }
            if (hasUvs)
            {
                values[8] = cast(float) mesh.uvs[index].x;
                values[9] = cast(float) mesh.uvs[index].y;
            }
            gpuVertices[index].values = values;
        }
        uploadBuffer(_vertices, gpuVertices, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);

        // Group triangles by material so each draw carries one texture.
        auto materialCount = max(1u, cast(uint) mesh.materials.length);
        auto groups = new uint[][materialCount];
        auto edgeList = new uint[(mesh.faces.length * 6) + 3];
        size_t edgeCursor;
        const hasMaterials = mesh.faceMaterials.length == mesh.faces.length;
        foreach (faceIndex, face; mesh.faces)
        {
            if (face.a < 0 || face.b < 0 || face.c < 0 ||
                face.a >= mesh.vertices.length ||
                face.b >= mesh.vertices.length ||
                face.c >= mesh.vertices.length)
                continue;
            uint material = hasMaterials ? cast(uint) mesh.faceMaterials[faceIndex] : 0;
            if (material >= materialCount)
                material = 0;
            groups[material] ~= cast(uint) face.a;
            groups[material] ~= cast(uint) face.b;
            groups[material] ~= cast(uint) face.c;
            edgeList[edgeCursor++] = cast(uint) face.a;
            edgeList[edgeCursor++] = cast(uint) face.b;
            edgeList[edgeCursor++] = cast(uint) face.b;
            edgeList[edgeCursor++] = cast(uint) face.c;
            edgeList[edgeCursor++] = cast(uint) face.c;
            edgeList[edgeCursor++] = cast(uint) face.a;
        }
        edgeList.length = edgeCursor;
        ensureMaterialBuffers(groups.length);
        foreach (materialIndex, group; groups)
            uploadBuffer(_materialIndices[materialIndex], group,
                VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
        uploadBuffer(_edgeIndices, edgeList, VK_BUFFER_USAGE_INDEX_BUFFER_BIT);

        ensureTextures(mesh);
    }

    private void ensureMaterialBuffers(size_t count)
    {
        if (_materialIndices.length >= count)
            return;
        foreach (index; _materialIndices.length .. count)
        {
            try
            {
                Buffer buffer;
                buffer.size = 0;
                _materialIndices ~= buffer;
            }
            catch (Exception)
            {
                break;
            }
        }
    }

    private void ensureTextures(const Mesh mesh)
    {
        // A mesh without materials still needs one slot, otherwise the draw
        // loop has no descriptor set to bind and nothing is rasterized.
        const count = max(1, mesh.materials.length);
        if (_textures.length < count)
        {
            foreach (index; _textures.length .. count)
                _textures ~= Texture.init;
        }
        // Allocate one descriptor set per material for the lifetime of the device.
        if (_materialSets.length < count)
        {
            auto layouts = new VkDescriptorSetLayout[count - _materialSets.length];
            foreach (ref layout; layouts)
                layout = _setLayout;
            if (layouts.length > 0)
            {
                VkDescriptorSetAllocateInfo allocate;
                allocate.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
                allocate.descriptorPool = _descriptorPool;
                allocate.descriptorSetCount = cast(uint) layouts.length;
                allocate.pSetLayouts = layouts.ptr;
                auto sets = new VkDescriptorSet[layouts.length];
                check(_vk.vkAllocateDescriptorSets(_device, &allocate, sets.ptr),
                    "allocating descriptor sets");
                _materialSets ~= sets;
            }
        }
        foreach (index; 0 .. count)
        {
            const slot = index < mesh.materials.length ?
                mesh.materials[index] : MaterialSlot.init;
            RgbaImage source = slot.texture >= 0 &&
                slot.texture < cast(int) mesh.textures.length ?
                cast(RgbaImage) mesh.textures[slot.texture] : null;
            if (_textures[index].set && _textures[index].source is source)
                continue;
            finalizeTexture(index, source, slot);
        }
    }

    private VkDescriptorSet[] _materialSets;

    private VkSampler _sampler;

    private VkSampler sampler()
    {
        if (_sampler)
            return _sampler;
        VkSamplerCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        info.magFilter = VK_FILTER_LINEAR;
        info.minFilter = VK_FILTER_LINEAR;
        info.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
        info.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        info.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        info.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        info.maxLod = 0;
        check(_vk.vkCreateSampler(_device, &info, null, &_sampler),
            "creating a sampler");
        return _sampler;
    }

    private void finalizeTexture(size_t index, RgbaImage source,
        const MaterialSlot slot)
    {
        destroyTexture(_textures[index]);
        auto texture = Texture.init;
        const width = source !is null ? source.width : 1;
        const height = source !is null ? source.height : 1;
        texture.source = source;
        texture.image = createImage(width, height, VK_FORMAT_R8G8B8A8_UNORM,
            VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
            texture.memory);
        texture.view = createView(texture.image, VK_FORMAT_R8G8B8A8_UNORM);

        // White pixels stand in for materials without a texture, so the shader
        // needs no branch and can always multiply.
        auto staging = createHostBuffer(cast(VkDeviceSize) width * height * 4,
            VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
        auto pixels = cast(ubyte[]) staging.mapped[0 .. width * height * 4];
        if (source !is null)
            foreach (offset; 0 .. width * height * 4)
                pixels[offset] = offset < source.pixels.length ? source.pixels[offset] : 255;
        else
            foreach (offset; 0 .. width * height * 4)
                pixels[offset] = 255;

        _vk.vkResetCommandBuffer(_commands, 0);
        VkCommandBufferBeginInfo begin;
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        check(_vk.vkBeginCommandBuffer(_commands, &begin), "recording a copy");
        transitionImage(_commands, texture.image, VK_IMAGE_LAYOUT_UNDEFINED,
            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
        VkBufferImageCopy copy;
        copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        copy.imageSubresource.layerCount = 1;
        copy.imageExtent = VkExtent3D(cast(uint) width, cast(uint) height, 1);
        _vk.vkCmdCopyBufferToImage(_commands, staging.handle, texture.image,
            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
        transitionImage(_commands, texture.image,
            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
        check(_vk.vkEndCommandBuffer(_commands), "finishing a copy");
        submitAndWait();
        destroyBuffer(staging);

        VkDescriptorSet set = _materialSets[index];
        DescriptorBufferInfo bufferInfo;
        bufferInfo.buffer = _uniforms.handle;
        bufferInfo.range = _uniforms.size;
        VkDescriptorImageInfo imageInfo;
        imageInfo.sampler = sampler();
        imageInfo.imageView = texture.view;
        imageInfo.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        VkWriteDescriptorSet[2] writes;
        writes[0].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[0].dstSet = set;
        writes[0].dstBinding = 0;
        writes[0].descriptorCount = 1;
        writes[0].descriptorType = DescriptorUniformBuffer;
        writes[0].pBufferInfo = &bufferInfo;
        writes[1].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[1].dstSet = set;
        writes[1].dstBinding = 1;
        writes[1].descriptorCount = 1;
        writes[1].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        writes[1].pImageInfo = &imageInfo;
        _vk.vkUpdateDescriptorSets(_device, 2, writes.ptr, 0, null);
        texture.set = set;
        _textures[index] = texture;
    }

    private void destroyTexture(ref Texture texture)
    {
        if (texture.view)
            _vk.vkDestroyImageView(_device, texture.view, null);
        if (texture.image)
            _vk.vkDestroyImage(_device, texture.image, null);
        if (texture.memory)
            _vk.vkFreeMemory(_device, texture.memory, null);
        texture = Texture.init;
    }

    private void transitionImage(VkCommandBuffer commands, VkImage image,
        int oldLayout, int newLayout)
    {
        VkImageMemoryBarrier barrier;
        barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.oldLayout = oldLayout;
        barrier.newLayout = newLayout;
        barrier.srcQueueFamilyIndex = uint.max;
        barrier.dstQueueFamilyIndex = uint.max;
        barrier.image = image;
        barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        barrier.subresourceRange.levelCount = 1;
        barrier.subresourceRange.layerCount = 1;
        const target = newLayout == VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL ?
            VK_PIPELINE_STAGE_TRANSFER_BIT : VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        _vk.vkCmdPipelineBarrier(commands,
            oldLayout == VK_IMAGE_LAYOUT_UNDEFINED ? VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT :
            VK_PIPELINE_STAGE_TRANSFER_BIT, target, 0, 0, null, 0, null, 1,
            &barrier);
    }

    private void uploadBuffer(T)(ref Buffer buffer, const(T)[] data, uint usage)
    {
        const bytes = cast(VkDeviceSize) (data.length * T.sizeof);
        if (bytes == 0)
        {
            buffer.size = 0;
            return;
        }
        if (buffer.handle == 0 || buffer.size < bytes || buffer.usage != usage)
        {
            destroyBuffer(buffer);
            buffer = createHostBuffer(bytes, usage);
        }
        buffer.mapped[0 .. bytes] = cast(ubyte[]) data[];
    }

    private void buildGrid()
    {
        enum float Radius = 4.0;
        enum float Step = 0.25;
        GpuVertex[] vertices;
        for (float offset = -Radius; offset <= Radius + 0.001; offset += Step)
        {
            foreach (sign; [-1.0f, 1.0f])
            {
                vertices ~= gridVertex(offset, -Radius, sign);
                vertices ~= gridVertex(offset, Radius, sign);
                vertices ~= gridVertex(-Radius, offset, sign);
                vertices ~= gridVertex(Radius, offset, sign);
            }
        }
        _gridVertices = cast(int) vertices.length;
        uploadBuffer(_gridLines, vertices, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
    }

    private GpuVertex gridVertex(float x, float z, float unused)
    {
        GpuVertex vertex;
        vertex.values[0] = x;
        vertex.values[1] = 0;
        vertex.values[2] = z;
        vertex.values[3] = 1;
        vertex.values[4] = 0;
        vertex.values[5] = 1;
        vertex.values[6] = 0;
        vertex.values[7] = 0;
        return vertex;
    }

    // ---- frame recording --------------------------------------------------

    private void updateUniforms(const Camera camera, int width, int height,
        RenderOptions options)
    {
        if (_uniforms.handle == 0)
            _uniforms = createHostBuffer(160, UsageUniformBuffer);
        auto floats = cast(float[]) _uniforms.mapped[0 .. 160];

        const eye = camera.eye();
        const forward = camera.forward();
        const right = camera.right();
        const up = camera.up();
        const focal = (height * 0.5) / tan(camera.fov * 0.5);
        const scaleX = 2.0 * focal / width;
        const scaleY = -2.0 * focal / height;
        enum double Near = 0.04;
        enum double Far = 120.0;
        const a = Far / (Far - Near);
        const b = -(Near * Far) / (Far - Near);

        // Column-major mat4: column c occupies floats [c*4 .. c*4+3].
        float[16] mvp;
        mvp[0] = cast(float) (scaleX * right.x);
        mvp[1] = cast(float) (scaleY * up.x);
        mvp[2] = cast(float) (a * forward.x);
        mvp[3] = cast(float) forward.x;
        mvp[4] = cast(float) (scaleX * right.y);
        mvp[5] = cast(float) (scaleY * up.y);
        mvp[6] = cast(float) (a * forward.y);
        mvp[7] = cast(float) forward.y;
        mvp[8] = cast(float) (scaleX * right.z);
        mvp[9] = cast(float) (scaleY * up.z);
        mvp[10] = cast(float) (a * forward.z);
        mvp[11] = cast(float) forward.z;
        mvp[12] = cast(float) -(scaleX * dot(right, eye));
        mvp[13] = cast(float) -(scaleY * dot(up, eye));
        mvp[14] = cast(float) (b - a * dot(forward, eye));
        mvp[15] = cast(float) -dot(forward, eye);
        floats[0 .. 16] = mvp[];
        floats[16 .. 32] = identityMatrix[];

        // Light direction is negated here so the shader needs only a dot.
        const light = Vec3(0.35, 0.85, 0.55);
        const lengthSquared = dot(light, light);
        const inverse = lengthSquared > 0 ? 1.0 / sqrt(lengthSquared) : 0.0;
        floats[32] = cast(float) (-light.x * inverse);
        floats[33] = cast(float) (-light.y * inverse);
        floats[34] = cast(float) (-light.z * inverse);
        floats[35] = 0.34f; // ambient
        floats[36] = 0.78f; // diffuse
        floats[37] = 0.0f;
        floats[38] = 0.0f;
        floats[39] = 0.0f;
        if (tracing)
            traceStep(format("frame %dx%d vertices %d faces %d eye %.2f %.2f %.2f "
                ~ "mvp %.3f %.3f %.3f %.3f", width, height, _meshVertices,
                _meshFaces, eye.x, eye.y, eye.z, floats[0], floats[1],
                floats[2], floats[3]));
    }

    private void recordCommands(RenderOptions options)
    {
        check(_vk.vkResetCommandBuffer(_commands, 0), "resetting commands");
        VkCommandBufferBeginInfo begin;
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        check(_vk.vkBeginCommandBuffer(_commands, &begin), "beginning commands");

        VkClearValue[1] clears;
        clears[0].color.float32 = [8.0f / 255.0f, 14.0f / 255.0f, 26.0f / 255.0f, 1.0f];
        VkRenderPassBeginInfo pass;
        pass.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        pass.renderPass = _renderPass;
        pass.framebuffer = _framebuffer;
        pass.renderArea.extent = VkExtent2D(cast(uint) _width, cast(uint) _height);
        pass.clearValueCount = 1;
        pass.pClearValues = clears.ptr;
        _vk.vkCmdBeginRenderPass(_commands, &pass, SubpassContentsInline);

        VkViewport viewport;
        viewport.width = cast(float) _width;
        viewport.height = cast(float) _height;
        viewport.maxDepth = 1.0f;
        _vk.vkCmdSetViewport(_commands, 0, 1, &viewport);
        VkRect2D scissor;
        scissor.extent = VkExtent2D(cast(uint) _width, cast(uint) _height);
        _vk.vkCmdSetScissor(_commands, 0, 1, &scissor);

        if (tracing)
        {
            if (_traceStats == VK_NULL_HANDLE || _traceStats == 0)
            {
                QueryPoolInfo traceStatsInfo;
                traceStatsInfo.sType = StTypeQueryPool;
                traceStatsInfo.queryType = QueryTypePipelineStatistics;
                traceStatsInfo.queryCount = 1;
                // One flag only, so the single counter is unambiguous.
                traceStatsInfo.pipelineStatistics = StatisticsFragment;
                check(_createQueryPool(_device, &traceStatsInfo, null,
                    &_traceStats),
                    "creating a statistics query pool");
            }
            _cmdResetQueryPool(_commands, _traceStats, 0, 1);
            _cmdBeginQuery(_commands, _traceStats, 0, 0);
        }

        _stats.drawCalls = 0;
        _stats.triangles = 0;
        _stats.lines = 0;

        if (options.grid && _gridVertices > 0)
        {
            const VkDeviceSize offset;
            _vk.vkCmdBindPipeline(_commands, VK_PIPELINE_BIND_POINT_GRAPHICS,
                _linePipeline);
            _vk.vkCmdBindVertexBuffers(_commands, 0, 1, &_gridLines.handle, &offset);
            pushColor(0.17f, 0.23f, 0.31f, 1.0f);
            _cmdDraw(_commands, cast(uint) _gridVertices, 1, 0, 0);
            _stats.drawCalls++;
            _stats.lines += _gridVertices / 2;
        }

        const drawsMesh = _meshVertices > 0 && _meshFaces > 0 &&
            _vertices.handle != 0;
        if (drawsMesh)
        {
            const VkDeviceSize offset;
            _vk.vkCmdBindPipeline(_commands, VK_PIPELINE_BIND_POINT_GRAPHICS,
                _meshPipeline);
            _vk.vkCmdBindVertexBuffers(_commands, 0, 1, &_vertices.handle, &offset);
            foreach (materialIndex, indices; _materialIndices)
            {
                if (indices.size == 0 || materialIndex >= _materialSets.length ||
                    materialIndex >= _textures.length)
                    continue;
                if (!_textures[materialIndex].set)
                    continue;
                _vk.vkCmdBindDescriptorSets(_commands, VK_PIPELINE_BIND_POINT_GRAPHICS,
                    _pipelineLayout, 0, 1, &_materialSets[materialIndex], 0, null);
                pushColor(0.76f, 0.78f, 0.82f, 1.0f);
                _vk.vkCmdBindIndexBuffer(_commands, indices.handle, 0,
                    VK_INDEX_TYPE_UINT32);
                const count = cast(uint) (indices.size / uint.sizeof);
                _vk.vkCmdDrawIndexed(_commands, count, 1, 0, 0, 0);
                _stats.drawCalls++;
                _stats.triangles += count / 3;
            }
            if (options.wireframe && _edgeIndices.size > 0)
            {
                _vk.vkCmdBindPipeline(_commands, VK_PIPELINE_BIND_POINT_GRAPHICS,
                    _linePipeline);
                pushColor(0.62f, 0.72f, 0.86f, 1.0f);
                _vk.vkCmdBindIndexBuffer(_commands, _edgeIndices.handle, 0,
                    VK_INDEX_TYPE_UINT32);
                const count = cast(uint) (_edgeIndices.size / uint.sizeof);
                _vk.vkCmdDrawIndexed(_commands, count, 1, 0, 0, 0);
                _stats.drawCalls++;
                _stats.lines += count / 2;
            }
            if (options.vertices && _vertices.size > 0)
            {
                _vk.vkCmdBindPipeline(_commands, VK_PIPELINE_BIND_POINT_GRAPHICS,
                    _pointPipeline);
                pushColor(0.95f, 0.78f, 0.35f, 1.0f);
                _cmdDraw(_commands, cast(uint) _meshVertices, 1, 0, 0);
                _stats.drawCalls++;
            }
        }

        _vk.vkCmdEndRenderPass(_commands);
        if (tracing && _traceStats)
            _cmdEndQuery(_commands, _traceStats, 0);

        VkBufferImageCopy copy;
        copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        copy.imageSubresource.layerCount = 1;
        copy.imageExtent = VkExtent3D(cast(uint) _width, cast(uint) _height, 1);
        _cmdCopyImageToBuffer(_commands, _color, LayoutTransferSrc,
            _readback.handle, 1, &copy);
        check(_vk.vkEndCommandBuffer(_commands), "finishing commands");
        submitAndWait();
        if (tracing && _traceStats)
        {
            ulong[1] counters;
            if (_getQueryPoolResults(_device, _traceStats, 0, 1,
                counters.sizeof, counters.ptr, counters[0].sizeof,
                QueryResultWait | QueryResult64) == VK_SUCCESS)
                traceStep(format("frame fragment invocations %s", counters[0]));
        }
    }

    private void pushColor(float red, float green, float blue, float alpha)
    {
        const float[4] color = [red, green, blue, alpha];
        _cmdPushConstants(_commands, _pipelineLayout,
            VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 0, 16,
            color.ptr);
    }

    private void submitAndWait()
    {
        VkSubmitInfo submit;
        submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &_commands;
        // Every submit waits and then re-arms the fence, so it is always
        // unsignalled here and the queue is idle between frames.
        check(_vk.vkQueueSubmit(_queue, 1, &submit, _fence), "submitting work");
        check(_vk.vkWaitForFences(_device, 1, &_fence, VK_TRUE, ulong.max),
            "waiting for the GPU");
        check(_vk.vkResetFences(_device, 1, &_fence), "resetting the fence");
    }


    private RgbFrame readback(int width, int height)
    {
        RgbFrame frame;
        frame.width = width;
        frame.height = height;
        frame.pixels = new ubyte[width * height * 3];
        const pixels = cast(ubyte[]) _readback.mapped[0 .. width * height * 4];
        foreach (index; 0 .. width * height)
        {
            static if (TargetIsBgra)
            {
                frame.pixels[index * 3] = pixels[index * 4 + 2];
                frame.pixels[index * 3 + 1] = pixels[index * 4 + 1];
                frame.pixels[index * 3 + 2] = pixels[index * 4];
            }
            else
            {
                frame.pixels[index * 3] = pixels[index * 4];
                frame.pixels[index * 3 + 1] = pixels[index * 4 + 1];
                frame.pixels[index * 3 + 2] = pixels[index * 4 + 2];
            }
        }
        return frame;
    }
}
