module marchingcubesterrain;

pragma(lib, "user32.lib");
pragma(lib, "winmm.lib");

private extern(Windows) int SetProcessDPIAware();
private extern(Windows) int SetProcessDpiAwarenessContext(void*);
private extern(Windows) void* SetThreadDpiAwarenessContext(void*);
private extern(Windows) short GetAsyncKeyState(int);
private extern(Windows) void* GetCurrentProcess();
private extern(Windows) void* GetCurrentThread();
private extern(Windows) int SetPriorityClass(void*, uint);
private extern(Windows) int SetThreadPriority(void*, int);
private extern(Windows) uint timeBeginPeriod(uint);
private extern(Windows) uint timeEndPeriod(uint);

import aurora.vulkan.api;
import aurora.font : GlyphAdvance, GlyphHeight, GlyphWidth, LineAdvance,
    glyphBits, glyphPixel;
import engine.runtime : TerrainRuntime, defaultRuntime;
import engine.player : PlayerInput, PlayerState, updatePlayer;
import engine.game : GameState, initGame, updateGame;
import engine.world : TerrainMaterial, materialName;
import mcmesh : MeshData, MeshVertex, TerrainChunk, TerrainChunkRebuild,
    TerrainChunkStream, buildTerrainChunk;

import core.stdc.string : memcpy;
import core.stdc.stdio : snprintf;
import core.stdc.stdint : intptr_t;
import core.memory : GC;
import core.thread : Thread;
import core.time : MonoTime, msecs, usecs;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.sys.windows.windows : CreateWindowExA, DefWindowProcA, DispatchMessageA,
    ClientToScreen, FindWindowA, GetClientRect, GetCurrentProcessId,
    GetCursorPos, GetForegroundWindow, GetModuleHandleA, HINSTANCE, HWND,
    IsIconic, IsWindow, LoadCursorA,
    LPARAM, LRESULT, MSG, POINT, PeekMessageA, RECT, RegisterClassA,
    ScreenToClient, SetCursorPos, SetForegroundWindow, SetWindowPos, SW_SHOW,
    ShowCursor, ShowWindow, TranslateMessage, UINT, WM_CLOSE, WM_DESTROY,
    WNDCLASSA, WPARAM, WS_CHILD, WS_OVERLAPPEDWINDOW, WS_VISIBLE;
import std.conv : to;
import std.file : exists, read, write;
import std.format : format;
import std.math : cos, floor, sin, sqrt, tan;
import std.mmfile : MmFile;
import std.path : buildPath;
import std.stdio : File, stderr, stdout;
import std.string : toStringz;

// Embedded at build time; compile from the app directory with -J=.
private enum string CubeVertexSpirv = import("shaders3d/cube.vert.spv");
private enum string CubeFragmentSpirv = import("shaders3d/cube.frag.spv");
private string gShaderDir;

enum int Width = 2048;
enum int Height = 1152;

private struct ChunkGpu
{
    VkBuffer vertexBuffer;
    VkDeviceMemory vertexMemory;
    VkBuffer indexBuffer;
    VkDeviceMemory indexMemory;
    uint indexCount;
    double centerX;
    double centerZ;
}
enum int ColorFormat = VK_FORMAT_R8G8B8A8_UNORM;
enum int DepthFormat = 126; // VK_FORMAT_D32_SFLOAT
enum int EventBytes = 24;
enum int EventCapacity = 64;
enum int SurfaceHeader = 80;
private enum int MaxHudVertices = 32768;
private enum int MaxHudIndices = 49152;
private enum int HudScale = 2;

private struct AnimatedSurface
{
    MmFile map;
    ubyte[] data;
    int frameBytes;
    ulong sequence;

    this(string path)
    {
        frameBytes = Width * Height * 4;
        const size = SurfaceHeader + EventCapacity * EventBytes +
            2 * frameBytes;
        auto stream = File(path, "wb");
        stream.rawWrite(new ubyte[size]);
        stream.close();
        map = new MmFile(path, MmFile.Mode.readWrite, cast(ulong) size, null);
        data = cast(ubyte[]) map[];
        char[8] magic = "AURSFACE";
        memcpy(data.ptr, magic.ptr, 8);
        put!uint(8, 2);
        put!uint(12, SurfaceHeader);
        put!uint(16, Width);
        put!uint(20, Height);
        put!uint(24, 0);
        put!uint(28, EventCapacity);
        put!ulong(32, 0);
        put!ulong(40, 0);
        put!uint(48, 0);
        put!uint(52, 0);
        put!uint(56, EventBytes);
        put!uint(60, 2);
        put!uint(64, frameBytes);
    }

    private void put(T)(size_t offset, T value)
    {
        memcpy(data.ptr + offset, &value, T.sizeof);
    }

    private T get(T)(size_t offset)
    {
        T value;
        memcpy(&value, data.ptr + offset, T.sizeof);
        return value;
    }

    void publish(const(ubyte)[] pixels, bool captured = false)
    {
        const active = get!uint(24);
        const target = 1 - active;
        const offset = SurfaceHeader + EventCapacity * EventBytes +
            target * frameBytes;
        memcpy(data.ptr + offset, pixels.ptr, frameBytes);
        put!uint(24, target);
        put!uint(68, captured ? 1 : 0);
        sequence++;
        put!ulong(32, sequence);
    }

    bool waitHost(ulong wanted, int timeoutMs = 500)
    {
        while (get!ulong(40) < wanted)
        {
            if (timeoutMs <= 0) return false;
            Thread.sleep(5.msecs);
            timeoutMs -= 5;
        }
        return true;
    }

    void close()
    {
        map = null;
    }
}

private class SurfacePresenter
{
    private AnimatedSurface _surface;
    private Thread _thread;
    private Mutex _mutex;
    private Condition _condition;
    private ubyte[] _frame;
    private ubyte[] _publishFrame;
    private bool _hasFrame;
    private bool _running = true;
    private bool _captured;
    private MonoTime _lastPublish;
    private int _publishOver16;
    private int _publishOver20;
    private double _publishMaxMs;
    private int _publishSamples;

    this(string path)
    {
        _surface = AnimatedSurface(path);
        _mutex = new Mutex();
        _condition = new Condition(_mutex);
        _frame = new ubyte[Width * Height * 4];
        _publishFrame = new ubyte[Width * Height * 4];
        _thread = new Thread(&run);
        _thread.start();
    }

    void submit(const(ubyte)[] pixels, bool captured)
    {
        synchronized (_mutex)
        {
            const count = pixels.length < _frame.length ?
                pixels.length : _frame.length;
            memcpy(_frame.ptr, pixels.ptr, count);
            _captured = captured;
            _hasFrame = true;
            _condition.notify();
        }
    }

    void stop()
    {
        synchronized (_mutex)
        {
            _running = false;
            _condition.notify();
        }
        _thread.join();
        _surface.close();
    }

    private void run()
    {
        SetThreadPriority(GetCurrentThread(), 2);
        while (true)
        {
            bool captured;
            synchronized (_mutex)
            {
                while (_running && !_hasFrame)
                    _condition.wait();
                if (!_running) break;
                auto swap = _frame;
                _frame = _publishFrame;
                _publishFrame = swap;
                _hasFrame = false;
                captured = _captured;
            }
            _surface.publish(_publishFrame, captured);
            const now = MonoTime.currTime;
            if (_lastPublish != MonoTime.init)
            {
                const intervalMs = (now - _lastPublish)
                    .total!"usecs" / 1000.0;
                if (intervalMs > 16.667) ++_publishOver16;
                if (intervalMs > 20.0) ++_publishOver20;
                if (intervalMs > _publishMaxMs)
                    _publishMaxMs = intervalMs;
            }
            _lastPublish = now;
            if (++_publishSamples >= 60)
            {
                _publishOver16 = 0;
                _publishOver20 = 0;
                _publishMaxMs = 0;
                _publishSamples = 0;
            }
        }
    }
}

struct PushConstants
{
    float[16] mvp;
}

struct VkDescriptorBufferInfo
{
    VkBuffer buffer;
    ulong offset;
    ulong range;
}

struct VkBufferMemoryBarrier
{
    int sType;
    const(void)* pNext;
    uint srcAccessMask;
    uint dstAccessMask;
    uint srcQueueFamilyIndex;
    uint dstQueueFamilyIndex;
    VkBuffer buffer;
    ulong offset;
    ulong size;
}

struct VkComputePipelineCreateInfo
{
    int sType;
    const(void)* pNext;
    uint flags;
    VkPipelineShaderStageCreateInfo stage;
    VkPipelineLayout layout;
    VkPipeline basePipelineHandle;
    int basePipelineIndex;
}

alias CmdDispatch = extern(System) void function(VkCommandBuffer, uint, uint,
    uint);
alias CreateComputePipelines = extern(System) VkResult function(VkDevice,
    VkPipelineCache, uint, const(VkComputePipelineCreateInfo)*, const(void)*,
    VkPipeline*);

struct StencilOp
{
    int failOp;
    int passOp;
    int depthFailOp;
    int compareOp;
    uint compareMask;
    uint writeMask;
    uint reference;
}

struct DepthState
{
    int sType;
    const(void)* pNext;
    VkFlags flags;
    VkBool32 depthTestEnable;
    VkBool32 depthWriteEnable;
    int depthCompareOp;
    VkBool32 depthBoundsTestEnable;
    VkBool32 stencilTestEnable;
    StencilOp front;
    StencilOp back;
    float minDepthBounds;
    float maxDepthBounds;
}

struct PushRange
{
    int stageFlags;
    uint offset;
    uint size;
}

struct ImageCopy
{
    VkImageSubresourceLayers srcSubresource;
    VkOffset3D srcOffset;
    VkImageSubresourceLayers dstSubresource;
    VkOffset3D dstOffset;
    VkExtent3D extent;
}

extern(System) alias CmdPushConstants = void function(VkCommandBuffer, VkPipelineLayout,
    int, uint, uint, const(void)*);
extern(System) alias CmdCopyImageToBuffer = void function(VkCommandBuffer, VkImage,
    int, VkBuffer, uint, const(VkBufferImageCopy)*);
extern(System) alias CmdCopyImage = void function(VkCommandBuffer, VkImage, int,
    VkImage, int, uint, const(ImageCopy)*);
extern(Windows) alias WndProc = LRESULT function(HWND, UINT, WPARAM, LPARAM);

private __gshared HWND gChildWindow;
private __gshared bool gWindowClosed;
private __gshared bool gStandaloneWindow;

private final class App
{
    VulkanApi vk;
    VkInstance instance;
    VkPhysicalDevice physical;
    VkDevice device;
    VkQueue queue;
    uint queueFamily;
    VkCommandPool commandPool;
    VkCommandBuffer commands;
    VkFence fence;
    VkRenderPass renderPass;
    VkPipeline pipeline;
    VkPipelineLayout pipelineLayout;
    VkPipeline terrainPipeline;
    VkPipelineLayout terrainPipelineLayout;
    VkDescriptorSetLayout terrainDescriptorLayout;
    VkDescriptorPool terrainDescriptorPool;
    VkDescriptorSet terrainDescriptorSet;
    VkImage terrainImage;
    VkImageView terrainImageView;
    VkDeviceMemory terrainImageMemory;
    VkSampler terrainSampler;
    VkImage terrainNormalImage;
    VkImageView terrainNormalView;
    VkDeviceMemory terrainNormalMemory;
    VkImage terrainOrmImage;
    VkImageView terrainOrmView;
    VkDeviceMemory terrainOrmMemory;
    VkBuffer terrainDetailBuffer;
    VkDeviceMemory terrainDetailMemory;
    VkPipeline terrainDetailPipeline;
    VkFramebuffer framebuffer;
    VkImage colorImage;
    VkImageView colorView;
    VkDeviceMemory colorMemory;
    VkImage depthImage;
    VkImageView depthView;
    VkDeviceMemory depthMemory;
    VkBuffer vertexBuffer;
    VkDeviceMemory vertexMemory;
    VkBuffer indexBuffer;
    VkDeviceMemory indexMemory;
    uint indexCount;
    ChunkGpu[][] chunkLods;
    TerrainChunk[] chunkData;
    TerrainChunkStream chunkStream;
    TerrainChunkRebuild rebuildJob;
    TerrainRuntime runtime;
    GameState game;
    SurfacePresenter presenter;
    int materialIndex;
    bool digHeld;
    bool buildHeld;
    bool[] pendingDirty;
    int[] pendingDirtyList;
    double health = 100;
    double stamina = 100;
    string[] notifications;
    VkBuffer readBuffer;
    VkDeviceMemory readMemory;

    VkPipeline hudPipeline;
    VkBuffer skyVertexBuffer;
    VkDeviceMemory skyVertexMemory;
    VkBuffer skyIndexBuffer;
    VkDeviceMemory skyIndexMemory;
    uint skyIndexCount;
    VkBuffer vegetationVertexBuffer;
    VkDeviceMemory vegetationVertexMemory;
    VkBuffer vegetationIndexBuffer;
    VkDeviceMemory vegetationIndexMemory;
    uint vegetationIndexCount;
    VkBuffer actorVertexBuffer;
    VkDeviceMemory actorVertexMemory;
    VkBuffer actorIndexBuffer;
    VkDeviceMemory actorIndexMemory;
    uint actorIndexCount;
    MeshVertex[] actorVertexCache;
    uint[] actorIndexCache;
    VkBuffer hudVertexBuffer;
    VkDeviceMemory hudVertexMemory;
    VkBuffer hudIndexBuffer;
    VkDeviceMemory hudIndexMemory;
    uint hudIndexCount;
    bool hudVisible = true;
    bool hudTrace;
    bool hudToggleDown;
    bool hudDirty = true;
    MeshVertex[] hudVertexCache;
    uint[] hudIndexCache;
    double hudRefreshAccumulator;
    bool hudClockStarted;
    uint hudWidth;
    uint hudHeight;
    uint hudFrameCount;
    double hudFps = 60;
    MonoTime hudLastUpdate;
    CmdPushConstants pushConstants;
    CmdCopyImageToBuffer copyImageToBuffer;
    CmdCopyImage copyImage;
    CmdDispatch cmdDispatch;
    CreateComputePipelines createComputePipelines;
    int colorFormat = ColorFormat;
    VkSurfaceKHR surface;
    VkSwapchainKHR swapchain;
    VkImage[] swapImages;
    VkImageView[] swapViews;
    VkSemaphore acquireSemaphore;
    VkSemaphore presentSemaphore;
    VkExtent2D extent = VkExtent2D(Width, Height);
    VkPhysicalDeviceMemoryProperties memoryProperties;
    double camX = 0;
    double camY = 0;
    double camZ = 0;
    double camYaw = 0;
    double camPitch = 0;
    double velocityX = 0;
    double velocityZ = 0;
    PlayerState player;
    string mouseTitle = "Large Marching Cubes Terrain";
    HWND mouseWindow;
    bool mouseCaptured;
    bool cursorHidden;
    bool testMotion;
    bool extremeMotion;

    this(string surfacePath = null)
    {
        if (surfacePath.length != 0)
            presenter = new SurfacePresenter(surfacePath);
        runtime = defaultRuntime();
        chunkStream = new TerrainChunkStream(runtime.world, runtime.lights);
        chunkStream.start();
        vk = new VulkanApi();
        VkApplicationInfo application;
        application.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
        application.pApplicationName = "Aurora Vulkan 3D".ptr;
        application.applicationVersion = 1;
        application.pEngineName = "Aurora".ptr;
        application.engineVersion = 2;
        application.apiVersion = VK_API_VERSION_1_0;
        VkInstanceCreateInfo createInfo;
        createInfo.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        createInfo.pApplicationInfo = &application;
        const(char)*[] extensions;
        if (gChildWindow !is null)
        {
            extensions ~= toStringz("VK_KHR_surface");
            extensions ~= toStringz("VK_KHR_win32_surface");
            createInfo.enabledExtensionCount = cast(uint) extensions.length;
            createInfo.ppEnabledExtensionNames = extensions.ptr;
        }
        check(vk.vkCreateInstance(&createInfo, null, &instance),
            "creating the Vulkan instance");
        vk.loadInstance(instance);
        if (gChildWindow !is null) { stdout.writeln("vulkan3d: instance"); stdout.flush(); }
        if (gChildWindow !is null)
        {
            if (vk.vkCreateWin32SurfaceKHR is null)
                throw new Exception("Vulkan Win32 surface extension unavailable");
            VkWin32SurfaceCreateInfoKHR surfaceInfo;
            surfaceInfo.sType = VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR;
            surfaceInfo.hinstance = cast(void*) GetModuleHandleA(null);
            surfaceInfo.hwnd = cast(void*) gChildWindow;
            check(vk.vkCreateWin32SurfaceKHR(instance, &surfaceInfo, null,
                &surface), "creating the child Vulkan surface");
            stdout.writeln("vulkan3d: surface"); stdout.flush();
        }

        uint count;
        check(vk.vkEnumeratePhysicalDevices(instance, &count, null),
            "counting Vulkan devices");
        if (count == 0) throw new Exception("no Vulkan physical device");
        auto devices = new VkPhysicalDevice[count];
        check(vk.vkEnumeratePhysicalDevices(instance, &count, devices.ptr),
            "enumerating Vulkan devices");
        physical = devices[0];

        uint familyCount;
        vk.vkGetPhysicalDeviceQueueFamilyProperties(physical, &familyCount, null);
        auto families = new VkQueueFamilyProperties[familyCount];
        vk.vkGetPhysicalDeviceQueueFamilyProperties(physical, &familyCount,
            families.ptr);
        bool found;
        foreach (index, family; families)
        {
            if ((family.queueFlags & VK_QUEUE_GRAPHICS_BIT) == 0) continue;
            if (gChildWindow !is null)
            {
                VkBool32 supported;
                if (vk.vkGetPhysicalDeviceSurfaceSupportKHR is null ||
                    vk.vkGetPhysicalDeviceSurfaceSupportKHR(physical,
                        cast(uint) index, surface, &supported) != VK_SUCCESS ||
                    supported == 0)
                    continue;
            }
            if (true)
            {
                queueFamily = cast(uint) index;
                found = true;
                break;
            }
        }
        if (!found) throw new Exception("no Vulkan graphics queue");

        float priority = 1.0f;
        VkDeviceQueueCreateInfo queueInfo;
        queueInfo.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        queueInfo.queueFamilyIndex = queueFamily;
        queueInfo.queueCount = 1;
        queueInfo.pQueuePriorities = &priority;
        VkDeviceCreateInfo deviceInfo;
        deviceInfo.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        deviceInfo.queueCreateInfoCount = 1;
        deviceInfo.pQueueCreateInfos = &queueInfo;
        const(char)* swapchainExtension = toStringz("VK_KHR_swapchain");
        if (gChildWindow !is null)
        {
            deviceInfo.enabledExtensionCount = 1;
            deviceInfo.ppEnabledExtensionNames = &swapchainExtension;
        }
        check(vk.vkCreateDevice(physical, &deviceInfo, null, &device),
            "creating the Vulkan device");
        vk.loadDevice(device);
        vk.vkGetDeviceQueue(device, queueFamily, 0, &queue);
        vk.vkGetPhysicalDeviceMemoryProperties(physical, &memoryProperties);
        if (gChildWindow !is null) { stdout.writeln("vulkan3d: device"); stdout.flush(); }

        pushConstants = cast(CmdPushConstants) vk.vkGetDeviceProcAddr(device,
            toStringz("vkCmdPushConstants"));
        copyImageToBuffer = cast(CmdCopyImageToBuffer) vk.vkGetDeviceProcAddr(
            device, toStringz("vkCmdCopyImageToBuffer"));
        copyImage = cast(CmdCopyImage) vk.vkGetDeviceProcAddr(device,
            toStringz("vkCmdCopyImage"));
        cmdDispatch = cast(CmdDispatch) vk.vkGetDeviceProcAddr(device,
            toStringz("vkCmdDispatch"));
        createComputePipelines = cast(CreateComputePipelines)
            vk.vkGetDeviceProcAddr(device,
                toStringz("vkCreateComputePipelines"));
        if (pushConstants is null || copyImageToBuffer is null)
            throw new Exception("required Vulkan device entry points unavailable");
        if (cmdDispatch is null)
            throw new Exception("vkCmdDispatch unavailable");
        if (createComputePipelines is null)
            throw new Exception("vkCreateComputePipelines unavailable");
        if (gChildWindow !is null && copyImage is null)
            throw new Exception("vkCmdCopyImage unavailable");

        if (gChildWindow !is null) {
            createSwapchain();
            stdout.writeln("vulkan3d: swapchain"); stdout.flush();
        }
        createImages();
        if (gChildWindow !is null) { stdout.writeln("vulkan3d: images"); stdout.flush(); }
        createRenderPass();
        if (gChildWindow !is null) { stdout.writeln("vulkan3d: render pass"); stdout.flush(); }
        createPipeline();
        if (gChildWindow !is null) { stdout.writeln("vulkan3d: pipeline"); stdout.flush(); }
        createHudPipeline();
        if (gChildWindow !is null) { stdout.writeln("vulkan3d: hud pipeline"); stdout.flush(); }
        auto terrainChunks = chunkStream.wait();
        createBuffers(terrainChunks);
        createHudBuffers();
        createSkyBuffers();
        camZ = 40;
        camY = runtime.world.terrainHeight(camX, camZ) + 2.26;
        player.x = camX;
        player.y = camY;
        player.z = camZ;
        player.yaw = camYaw;
        player.velocityX = 0;
        player.velocityY = 0;
        player.velocityZ = 0;
        player.grounded = false;
        player.jumpHeld = false;
        if (gChildWindow !is null) { stdout.writeln("vulkan3d: buffers"); stdout.flush(); }
        createCommands();
        createTexturedTerrain();
        initGame(game, runtime.world);
        createVegetationMesh();
        createActorMeshBuffers();
        GC.minimize();
        if (gChildWindow !is null) { stdout.writeln("vulkan3d: commands"); stdout.flush(); }
    }

    private void check(VkResult result, string label)
    {
        if (result != VK_SUCCESS)
            throw new Exception(label ~ ": " ~ vkResultName(result));
    }

    private uint memoryType(uint bits, VkFlags required)
    {
        foreach (index; 0 .. memoryProperties.memoryTypeCount)
            if ((bits & (1u << index)) != 0 &&
                (memoryProperties.memoryTypes[index].propertyFlags &
                    required) == required)
                return index;
        throw new Exception("no suitable Vulkan memory type");
    }

    private void createSwapchain()
    {
        stdout.writeln("vulkan3d: swapchain capabilities"); stdout.flush();
        VkSurfaceCapabilitiesKHR capabilities;
        check(vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical, surface,
            &capabilities), "querying swapchain capabilities");
        stdout.writeln("vulkan3d: swapchain formats"); stdout.flush();
        uint formatCount;
        check(vk.vkGetPhysicalDeviceSurfaceFormatsKHR(physical, surface,
            &formatCount, null), "counting swapchain formats");
        auto formats = new VkSurfaceFormatKHR[formatCount];
        check(vk.vkGetPhysicalDeviceSurfaceFormatsKHR(physical, surface,
            &formatCount, formats.ptr), "reading swapchain formats");
        int chosen = ColorFormat;
        bool foundFormat;
        foreach (format; formats)
        {
            if (format.format == ColorFormat)
            {
                chosen = format.format;
                foundFormat = true;
                break;
            }
        }
        if (!foundFormat && formats.length != 0)
            chosen = formats[0].format;
        colorFormat = chosen;
        stdout.writeln("vulkan3d: swapchain format ", chosen); stdout.flush();
        extent = capabilities.currentExtent;
        if (extent.width == uint.max || extent.height == uint.max)
            extent = VkExtent2D(Width, Height);
        uint imageCount = capabilities.minImageCount + 1;
        if (capabilities.maxImageCount > 0 &&
            imageCount > capabilities.maxImageCount)
            imageCount = capabilities.maxImageCount;
        VkSwapchainCreateInfoKHR info;
        info.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
        info.surface = surface;
        info.minImageCount = imageCount;
        info.imageFormat = chosen;
        info.imageColorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
        info.imageExtent = extent;
        info.imageArrayLayers = 1;
        info.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
            VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        info.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
        info.preTransform = capabilities.currentTransform;
        info.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
        uint presentModeCount;
        check(vk.vkGetPhysicalDeviceSurfacePresentModesKHR(physical, surface,
            &presentModeCount, null), "counting present modes");
        auto presentModes = new int[presentModeCount];
        check(vk.vkGetPhysicalDeviceSurfacePresentModesKHR(physical, surface,
            &presentModeCount, presentModes.ptr), "reading present modes");
        info.presentMode = VK_PRESENT_MODE_FIFO_KHR;
        foreach (mode; presentModes)
            if (mode == VK_PRESENT_MODE_IMMEDIATE_KHR)
            {
                info.presentMode = mode;
                break;
            }
        if (info.presentMode == VK_PRESENT_MODE_FIFO_KHR)
            foreach (mode; presentModes)
                if (mode == VK_PRESENT_MODE_MAILBOX_KHR)
                {
                    info.presentMode = mode;
                    break;
                }
        info.clipped = 1;
        stdout.writeln("vulkan3d: present mode ", cast(int) info.presentMode);
        stdout.flush();
        stdout.writeln("vulkan3d: creating swapchain ", extent.width, "x",
            extent.height); stdout.flush();
        if (vk.vkCreateSwapchainKHR is null)
            throw new Exception("VK_KHR_swapchain device extension is unavailable");
        check(vk.vkCreateSwapchainKHR(device, &info, null, &swapchain),
            "creating the child swapchain");
        stdout.writeln("vulkan3d: swapchain images"); stdout.flush();
        check(vk.vkGetSwapchainImagesKHR(device, swapchain, &imageCount, null),
            "counting swapchain images");
        swapImages.length = imageCount;
        check(vk.vkGetSwapchainImagesKHR(device, swapchain, &imageCount,
            swapImages.ptr), "reading swapchain images");
        swapViews.length = imageCount;
        foreach (index, image; swapImages)
        {
            VkImageViewCreateInfo viewInfo;
            viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
            viewInfo.image = image;
            viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
            viewInfo.format = chosen;
            viewInfo.components = VkComponentMapping(0, 0, 0, 0);
            viewInfo.subresourceRange = VkImageSubresourceRange(
                VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1);
            check(vk.vkCreateImageView(device, &viewInfo, null,
                &swapViews[index]), "creating swapchain image view");
        }
        stdout.writeln("vulkan3d: swapchain semaphores"); stdout.flush();
        VkSemaphoreCreateInfo semaphoreInfo;
        semaphoreInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        check(vk.vkCreateSemaphore(device, &semaphoreInfo, null,
            &acquireSemaphore), "creating acquire semaphore");
        check(vk.vkCreateSemaphore(device, &semaphoreInfo, null,
            &presentSemaphore), "creating present semaphore");
    }

    private void recreateSwapchain()
    {
        vk.vkDeviceWaitIdle(device);
        foreach (view; swapViews)
            if (view != VK_NULL_HANDLE)
                vk.vkDestroyImageView(device, view, null);
        swapViews.length = 0;
        swapImages.length = 0;
        if (swapchain != VK_NULL_HANDLE)
        {
            vk.vkDestroySwapchainKHR(device, swapchain, null);
            swapchain = VK_NULL_HANDLE;
        }
        if (acquireSemaphore != VK_NULL_HANDLE)
        {
            vk.vkDestroySemaphore(device, acquireSemaphore, null);
            acquireSemaphore = VK_NULL_HANDLE;
        }
        if (presentSemaphore != VK_NULL_HANDLE)
        {
            vk.vkDestroySemaphore(device, presentSemaphore, null);
            presentSemaphore = VK_NULL_HANDLE;
        }
        createSwapchain();
    }

    private void createImage(ref VkImage image, ref VkDeviceMemory memory,
        ref VkImageView view, int format, VkFlags usage, VkFlags aspect)
    {
        VkImageCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        info.imageType = VK_IMAGE_TYPE_2D;
        info.format = format;
        info.extent = VkExtent3D(Width, Height, 1);
        info.mipLevels = 1;
        info.arrayLayers = 1;
        info.samples = 1;
        info.tiling = VK_IMAGE_TILING_OPTIMAL;
        info.usage = usage;
        info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        check(vk.vkCreateImage(device, &info, null, &image),
            "creating a 3D image");
        VkMemoryRequirements requirements;
        vk.vkGetImageMemoryRequirements(device, image, &requirements);
        VkMemoryAllocateInfo allocation;
        allocation.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        allocation.allocationSize = requirements.size;
        allocation.memoryTypeIndex = memoryType(requirements.memoryTypeBits,
            VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        check(vk.vkAllocateMemory(device, &allocation, null, &memory),
            "allocating image memory");
        check(vk.vkBindImageMemory(device, image, memory, 0),
            "binding image memory");
        VkImageViewCreateInfo viewInfo;
        viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        viewInfo.image = image;
        viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
        viewInfo.format = format;
        viewInfo.components = VkComponentMapping(0, 0, 0, 0);
        viewInfo.subresourceRange = VkImageSubresourceRange(aspect, 0, 1, 0, 1);
        check(vk.vkCreateImageView(device, &viewInfo, null, &view),
            "creating an image view");
    }

    private void createImages()
    {
        createImage(colorImage, colorMemory, colorView, colorFormat,
            VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | 0x1, // TRANSFER_SRC
            VK_IMAGE_ASPECT_COLOR_BIT);
        createImage(depthImage, depthMemory, depthView, DepthFormat,
            0x20, // DEPTH_STENCIL_ATTACHMENT
            0x2); // DEPTH
    }

    private void createRenderPass()
    {
        VkAttachmentDescription[2] attachments;
        attachments[0].format = colorFormat;
        attachments[0].samples = 1;
        attachments[0].loadOp = 1; // CLEAR
        attachments[0].storeOp = 0; // STORE
        attachments[0].stencilLoadOp = 2;
        attachments[0].stencilStoreOp = 2;
        attachments[0].initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        attachments[0].finalLayout = 6; // TRANSFER_SRC_OPTIMAL
        attachments[1].format = DepthFormat;
        attachments[1].samples = 1;
        attachments[1].loadOp = 1;
        attachments[1].storeOp = 2;
        attachments[1].stencilLoadOp = 2;
        attachments[1].stencilStoreOp = 2;
        attachments[1].initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        attachments[1].finalLayout = 3; // DEPTH_STENCIL_ATTACHMENT_OPTIMAL
        VkAttachmentReference colorRef;
        colorRef.attachment = 0;
        colorRef.layout = 2;
        VkAttachmentReference depthRef;
        depthRef.attachment = 1;
        depthRef.layout = 3;
        VkSubpassDescription subpass;
        subpass.pipelineBindPoint = 0;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &colorRef;
        subpass.pDepthStencilAttachment = &depthRef;
        VkSubpassDependency dependency;
        dependency.srcSubpass = 0xffffffff;
        dependency.dstSubpass = 0;
        dependency.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dependency.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dependency.srcAccessMask = 0;
        dependency.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        VkRenderPassCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        info.attachmentCount = 2;
        info.pAttachments = attachments.ptr;
        info.subpassCount = 1;
        info.pSubpasses = &subpass;
        info.dependencyCount = 1;
        info.pDependencies = &dependency;
        check(vk.vkCreateRenderPass(device, &info, null, &renderPass),
            "creating the 3D render pass");
        VkImageView[2] views = [colorView, depthView];
        VkFramebufferCreateInfo frameInfo;
        frameInfo.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        frameInfo.renderPass = renderPass;
        frameInfo.attachmentCount = 2;
        frameInfo.pAttachments = views.ptr;
        frameInfo.width = Width;
        frameInfo.height = Height;
        frameInfo.layers = 1;
        check(vk.vkCreateFramebuffer(device, &frameInfo, null, &framebuffer),
            "creating the 3D framebuffer");
    }

    private VkShaderModule shader(string embedded, string name)
    {
        const(ubyte)[] bytes = cast(const(ubyte)[]) embedded;
        if (gShaderDir.length != 0)
            bytes = cast(const(ubyte)[]) read(buildPath(gShaderDir, name));
        VkShaderModuleCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
        info.codeSize = bytes.length;
        info.pCode = cast(const(uint)*) bytes.ptr;
        VkShaderModule shaderModule;
        check(vk.vkCreateShaderModule(device, &info, null, &shaderModule),
            "creating shader module " ~ name);
        return shaderModule;
    }

    private void createPipeline()
    {
        auto vertex = shader(CubeVertexSpirv, "cube.vert.spv");
        auto fragment = shader(CubeFragmentSpirv, "cube.frag.spv");
        VkPipelineShaderStageCreateInfo[2] stages;
        stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
        stages[0].module_ = vertex;
        stages[0].pName = toStringz("main");
        stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
        stages[1].module_ = fragment;
        stages[1].pName = toStringz("main");

        VkVertexInputBindingDescription binding;
        binding.binding = 0;
        binding.stride = MeshVertex.sizeof;
        binding.inputRate = 0;
        VkVertexInputAttributeDescription[2] attributes;
        attributes[0].location = 0;
        attributes[0].binding = 0;
        attributes[0].format = 106; // R32G32B32_SFLOAT
        attributes[0].offset = 0;
        attributes[1].location = 1;
        attributes[1].binding = 0;
        attributes[1].format = 106;
        attributes[1].offset = 12;
        VkPipelineVertexInputStateCreateInfo vertexInput;
        vertexInput.sType =
            VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vertexInput.vertexBindingDescriptionCount = 1;
        vertexInput.pVertexBindingDescriptions = &binding;
        vertexInput.vertexAttributeDescriptionCount = 2;
        vertexInput.pVertexAttributeDescriptions = attributes.ptr;
        VkPipelineInputAssemblyStateCreateInfo assembly;
        assembly.sType =
            VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        assembly.topology = 3;
        VkViewport viewport = VkViewport(0, 0, Width, Height, 0, 1);
        VkRect2D scissor = VkRect2D(VkOffset2D(0, 0),
            VkExtent2D(Width, Height));
        VkPipelineViewportStateCreateInfo viewportState;
        viewportState.sType =
            VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        viewportState.viewportCount = 1;
        viewportState.pViewports = &viewport;
        viewportState.scissorCount = 1;
        viewportState.pScissors = &scissor;
        VkPipelineRasterizationStateCreateInfo raster;
        raster.sType =
            VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        raster.polygonMode = 0;
        raster.cullMode = 0;
        raster.frontFace = 1;
        raster.lineWidth = 1;
        VkPipelineMultisampleStateCreateInfo multisample;
        multisample.sType =
            VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        multisample.rasterizationSamples = 1;
        VkPipelineColorBlendAttachmentState blendAttachment;
        blendAttachment.colorWriteMask = 0xf;
        VkPipelineColorBlendStateCreateInfo blend;
        blend.sType =
            VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        blend.attachmentCount = 1;
        blend.pAttachments = &blendAttachment;
        DepthState depth;
        depth.sType = 46; // VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE
        depth.depthTestEnable = 1;
        depth.depthWriteEnable = 1;
        depth.depthCompareOp = 1; // LESS
        PushRange push;
        push.stageFlags = VK_SHADER_STAGE_VERTEX_BIT;
        push.size = 64;
        VkPipelineLayoutCreateInfo layoutInfo;
        layoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        layoutInfo.pushConstantRangeCount = 1;
        layoutInfo.pPushConstantRanges = &push;
        check(vk.vkCreatePipelineLayout(device, &layoutInfo, null,
            &pipelineLayout), "creating the 3D pipeline layout");
        VkGraphicsPipelineCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        info.stageCount = 2;
        info.pStages = stages.ptr;
        info.pVertexInputState = &vertexInput;
        info.pInputAssemblyState = &assembly;
        info.pViewportState = &viewportState;
        info.pRasterizationState = &raster;
        info.pMultisampleState = &multisample;
        info.pDepthStencilState = &depth;
        info.pColorBlendState = &blend;
        info.layout = pipelineLayout;
        info.renderPass = renderPass;
        info.subpass = 0;
        info.basePipelineIndex = -1;
        check(vk.vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &info,
            null, &pipeline), "creating the 3D pipeline");
    }

    private void createHudPipeline()
    {
        auto vertex = shader(CubeVertexSpirv, "cube.vert.spv");
        auto fragment = shader(CubeFragmentSpirv, "cube.frag.spv");
        VkPipelineShaderStageCreateInfo[2] stages;
        stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
        stages[0].module_ = vertex;
        stages[0].pName = toStringz("main");
        stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
        stages[1].module_ = fragment;
        stages[1].pName = toStringz("main");

        VkVertexInputBindingDescription binding;
        binding.binding = 0;
        binding.stride = MeshVertex.sizeof;
        binding.inputRate = 0;
        VkVertexInputAttributeDescription[2] attributes;
        attributes[0].location = 0;
        attributes[0].binding = 0;
        attributes[0].format = 106; // R32G32B32_SFLOAT
        attributes[0].offset = 0;
        attributes[1].location = 1;
        attributes[1].binding = 0;
        attributes[1].format = 106;
        attributes[1].offset = 12;
        VkPipelineVertexInputStateCreateInfo vertexInput;
        vertexInput.sType =
            VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vertexInput.vertexBindingDescriptionCount = 1;
        vertexInput.pVertexBindingDescriptions = &binding;
        vertexInput.vertexAttributeDescriptionCount = 2;
        vertexInput.pVertexAttributeDescriptions = attributes.ptr;
        VkPipelineInputAssemblyStateCreateInfo assembly;
        assembly.sType =
            VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        assembly.topology = 3;
        int[2] dynamicStates = [VK_DYNAMIC_STATE_VIEWPORT,
            VK_DYNAMIC_STATE_SCISSOR];
        VkPipelineDynamicStateCreateInfo dynamicState;
        dynamicState.sType =
            VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dynamicState.dynamicStateCount = 2;
        dynamicState.pDynamicStates = dynamicStates.ptr;
        VkPipelineViewportStateCreateInfo viewportState;
        viewportState.sType =
            VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        viewportState.viewportCount = 1;
        viewportState.scissorCount = 1;
        VkPipelineRasterizationStateCreateInfo raster;
        raster.sType =
            VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        raster.polygonMode = 0;
        raster.cullMode = 0;
        raster.frontFace = 1;
        raster.lineWidth = 1;
        VkPipelineMultisampleStateCreateInfo multisample;
        multisample.sType =
            VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        multisample.rasterizationSamples = 1;
        VkPipelineColorBlendAttachmentState blendAttachment;
        blendAttachment.colorWriteMask = 0xf;
        VkPipelineColorBlendStateCreateInfo blend;
        blend.sType =
            VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        blend.attachmentCount = 1;
        blend.pAttachments = &blendAttachment;
        DepthState depth;
        depth.sType = 46;
        depth.depthTestEnable = 0;
        depth.depthWriteEnable = 0;
        VkGraphicsPipelineCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        info.stageCount = 2;
        info.pStages = stages.ptr;
        info.pVertexInputState = &vertexInput;
        info.pInputAssemblyState = &assembly;
        info.pViewportState = &viewportState;
        info.pRasterizationState = &raster;
        info.pMultisampleState = &multisample;
        info.pDepthStencilState = &depth;
        info.pColorBlendState = &blend;
        info.pDynamicState = &dynamicState;
        info.layout = pipelineLayout;
        info.renderPass = renderPass;
        info.subpass = 0;
        info.basePipelineIndex = -1;
        check(vk.vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &info,
            null, &hudPipeline), "creating the HUD pipeline");
    }

    private void createTexturedTerrain()
    {
        const(int) textureWidth = 1024;
        const(int) textureHeight = 1024;
        const(int) textureLayers = 16;
        const(int) textureFormat = 43; // VK_FORMAT_R8G8B8A8_SRGB
        const(string) textureName = "terrain_albedo_1024x16.rgba";
        const(string) texturePath = gShaderDir.length != 0
            ? buildPath(gShaderDir, textureName)
            : buildPath("shaders3d", textureName);
        auto textureBytes = cast(ubyte[]) read(texturePath);
        if (textureBytes.length != textureWidth * textureHeight * 4 *
            textureLayers)
            throw new Exception("terrain texture array has the wrong size");

        VkImageCreateInfo imageInfo;
        imageInfo.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        imageInfo.imageType = 0; // VK_IMAGE_TYPE_2D
        imageInfo.format = textureFormat;
        imageInfo.extent = VkExtent3D(textureWidth, textureHeight, 1);
        imageInfo.mipLevels = 1;
        imageInfo.arrayLayers = textureLayers;
        imageInfo.samples = 1;
        imageInfo.tiling = 0; // VK_IMAGE_TILING_OPTIMAL
        imageInfo.usage = 0x4 | 0x2; // SAMPLED | TRANSFER_DST
        imageInfo.sharingMode = 0;
        imageInfo.initialLayout = 0;
        check(vk.vkCreateImage(device, &imageInfo, null, &terrainImage),
            "creating terrain texture array");
        VkMemoryRequirements imageRequirements;
        vk.vkGetImageMemoryRequirements(device, terrainImage,
            &imageRequirements);
        VkMemoryAllocateInfo imageAllocation;
        imageAllocation.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        imageAllocation.allocationSize = imageRequirements.size;
        imageAllocation.memoryTypeIndex = memoryType(
            imageRequirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        check(vk.vkAllocateMemory(device, &imageAllocation, null,
            &terrainImageMemory), "allocating terrain texture memory");
        check(vk.vkBindImageMemory(device, terrainImage, terrainImageMemory, 0),
            "binding terrain texture memory");

        VkImageViewCreateInfo viewInfo;
        viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        viewInfo.image = terrainImage;
        viewInfo.viewType = 1; // VK_IMAGE_VIEW_TYPE_2D_ARRAY
        viewInfo.format = textureFormat;
        viewInfo.components = VkComponentMapping(0, 0, 0, 0);
        viewInfo.subresourceRange = VkImageSubresourceRange(
            VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, textureLayers);
        check(vk.vkCreateImageView(device, &viewInfo, null, &terrainImageView),
            "creating terrain texture view");

        VkSamplerCreateInfo samplerInfo;
        samplerInfo.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        samplerInfo.magFilter = 1;
        samplerInfo.minFilter = 1;
        samplerInfo.mipmapMode = 1;
        samplerInfo.addressModeU = 0;
        samplerInfo.addressModeV = 0;
        samplerInfo.addressModeW = 0;
        samplerInfo.maxAnisotropy = 1;
        samplerInfo.maxLod = 0;
        check(vk.vkCreateSampler(device, &samplerInfo, null, &terrainSampler),
            "creating terrain sampler");

        VkBuffer stagingBuffer;
        VkDeviceMemory stagingMemory;
        createBuffer(stagingBuffer, stagingMemory,
            cast(VkDeviceSize) textureBytes.length, 0x1); // TRANSFER_SRC
        upload(stagingMemory, textureBytes);

        VkCommandBufferBeginInfo begin;
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        check(vk.vkBeginCommandBuffer(commands, &begin),
            "beginning terrain texture upload");
        VkImageMemoryBarrier barrier;
        barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.oldLayout = 0;
        barrier.newLayout = 7; // TRANSFER_DST_OPTIMAL
        barrier.srcQueueFamilyIndex = 0xffffffff;
        barrier.dstQueueFamilyIndex = 0xffffffff;
        barrier.image = terrainImage;
        barrier.subresourceRange = VkImageSubresourceRange(
            VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, textureLayers);
        barrier.srcAccessMask = 0;
        barrier.dstAccessMask = 0x1000; // TRANSFER_WRITE
        vk.vkCmdPipelineBarrier(commands, 0x1, 0x1000, 0, 0, null, 0, null,
            1, &barrier);
        VkBufferImageCopy copy;
        copy.bufferOffset = 0;
        copy.bufferRowLength = 0;
        copy.bufferImageHeight = 0;
        copy.imageSubresource = VkImageSubresourceLayers(
            VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, textureLayers);
        copy.imageOffset = VkOffset3D(0, 0, 0);
        copy.imageExtent = VkExtent3D(textureWidth, textureHeight, 1);
        vk.vkCmdCopyBufferToImage(commands, stagingBuffer, terrainImage, 7,
            1, &copy);
        barrier.oldLayout = 7;
        barrier.newLayout = 5; // SHADER_READ_ONLY_OPTIMAL
        barrier.srcAccessMask = 0x1000;
        barrier.dstAccessMask = 0x20; // SHADER_READ
        vk.vkCmdPipelineBarrier(commands, 0x1000, 0x10, 0, 0, null, 0, null,
            1, &barrier);
        check(vk.vkEndCommandBuffer(commands),
            "ending terrain texture upload");
        VkSubmitInfo submit;
        submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &commands;
        check(vk.vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE),
            "submitting terrain texture upload");
        vk.vkQueueWaitIdle(queue);
        vk.vkDestroyBuffer(device, stagingBuffer, null);
        vk.vkFreeMemory(device, stagingMemory, null);

        createAuxTextureArray("terrain_normal_512x16.rgba", 512, 512, 16,
            37, terrainNormalImage, terrainNormalMemory, terrainNormalView);
        createAuxTextureArray("terrain_orm_512x16.rgba", 512, 512, 16,
            37, terrainOrmImage, terrainOrmMemory, terrainOrmView);

        createBuffer(terrainDetailBuffer, terrainDetailMemory, 4, 0x20);
        VkDescriptorSetLayoutBinding[4] descriptorBindings;
        foreach (index; 0 .. 3)
        {
            descriptorBindings[index].binding = index;
            descriptorBindings[index].descriptorType = 1; // COMBINED_IMAGE_SAMPLER
            descriptorBindings[index].descriptorCount = 1;
            descriptorBindings[index].stageFlags = 0x10; // FRAGMENT
        }
        descriptorBindings[3].binding = 3;
        descriptorBindings[3].descriptorType = 7; // STORAGE_BUFFER
        descriptorBindings[3].descriptorCount = 1;
        descriptorBindings[3].stageFlags = 0x30; // COMPUTE | FRAGMENT
        VkDescriptorSetLayoutCreateInfo descriptorLayout;
        descriptorLayout.sType =
            VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        descriptorLayout.bindingCount = 4;
        descriptorLayout.pBindings = descriptorBindings.ptr;
        check(vk.vkCreateDescriptorSetLayout(device, &descriptorLayout, null,
            &terrainDescriptorLayout), "creating terrain descriptor layout");
        VkDescriptorPoolSize poolSize;
        poolSize.type = 1;
        poolSize.descriptorCount = 4;
        VkDescriptorPoolCreateInfo poolInfo;
        poolInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        poolInfo.maxSets = 1;
        poolInfo.poolSizeCount = 1;
        poolInfo.pPoolSizes = &poolSize;
        check(vk.vkCreateDescriptorPool(device, &poolInfo, null,
            &terrainDescriptorPool), "creating terrain descriptor pool");
        VkDescriptorSetAllocateInfo allocate;
        allocate.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        allocate.descriptorPool = terrainDescriptorPool;
        allocate.descriptorSetCount = 1;
        allocate.pSetLayouts = &terrainDescriptorLayout;
        check(vk.vkAllocateDescriptorSets(device, &allocate,
            &terrainDescriptorSet), "allocating terrain descriptor set");
        VkDescriptorImageInfo[3] descriptorImageInfos;
        descriptorImageInfos[0].sampler = terrainSampler;
        descriptorImageInfos[0].imageView = terrainImageView;
        descriptorImageInfos[1].sampler = terrainSampler;
        descriptorImageInfos[1].imageView = terrainNormalView;
        descriptorImageInfos[2].sampler = terrainSampler;
        descriptorImageInfos[2].imageView = terrainOrmView;
        foreach (index; 0 .. 3)
            descriptorImageInfos[index].imageLayout = 5;
        VkDescriptorBufferInfo detailBufferInfo;
        detailBufferInfo.buffer = terrainDetailBuffer;
        detailBufferInfo.offset = 0;
        detailBufferInfo.range = 4;
        VkWriteDescriptorSet[4] writes;
        foreach (index; 0 .. 3)
        {
            writes[index].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[index].dstSet = terrainDescriptorSet;
            writes[index].dstBinding = index;
            writes[index].descriptorCount = 1;
            writes[index].descriptorType = 1;
            writes[index].pImageInfo = &descriptorImageInfos[index];
        }
        writes[3].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[3].dstSet = terrainDescriptorSet;
        writes[3].dstBinding = 3;
        writes[3].descriptorCount = 1;
        writes[3].descriptorType = 7;
        writes[3].pBufferInfo = &detailBufferInfo;
        vk.vkUpdateDescriptorSets(device, 4, writes.ptr, 0, null);

        auto vertex = shader("", "terrain.vert.spv");
        auto fragment = shader("", "terrain.frag.spv");
        VkPipelineShaderStageCreateInfo[2] stages;
        stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
        stages[0].module_ = vertex;
        stages[0].pName = toStringz("main");
        stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
        stages[1].module_ = fragment;
        stages[1].pName = toStringz("main");
        VkVertexInputBindingDescription binding;
        binding.binding = 0;
        binding.stride = MeshVertex.sizeof;
        binding.inputRate = 0;
        VkVertexInputAttributeDescription[3] attributes;
        attributes[0] = VkVertexInputAttributeDescription(0, 0, 106, 0);
        attributes[1] = VkVertexInputAttributeDescription(1, 0, 106, 12);
        attributes[2] = VkVertexInputAttributeDescription(2, 0, 100, 24);
        VkPipelineVertexInputStateCreateInfo vertexInput;
        vertexInput.sType =
            VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vertexInput.vertexBindingDescriptionCount = 1;
        vertexInput.pVertexBindingDescriptions = &binding;
        vertexInput.vertexAttributeDescriptionCount = 3;
        vertexInput.pVertexAttributeDescriptions = attributes.ptr;
        VkPipelineInputAssemblyStateCreateInfo assembly;
        assembly.sType =
            VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        assembly.topology = 3;
        VkViewport viewport = VkViewport(0, 0, Width, Height, 0, 1);
        VkRect2D scissor = VkRect2D(VkOffset2D(0, 0),
            VkExtent2D(Width, Height));
        VkPipelineViewportStateCreateInfo viewportState;
        viewportState.sType =
            VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        viewportState.viewportCount = 1;
        viewportState.pViewports = &viewport;
        viewportState.scissorCount = 1;
        viewportState.pScissors = &scissor;
        VkPipelineRasterizationStateCreateInfo raster;
        raster.sType =
            VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        raster.polygonMode = 0;
        raster.cullMode = 0;
        raster.frontFace = 1;
        raster.lineWidth = 1;
        VkPipelineMultisampleStateCreateInfo multisample;
        multisample.sType =
            VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        multisample.rasterizationSamples = 1;
        VkPipelineColorBlendAttachmentState blendAttachment;
        blendAttachment.colorWriteMask = 0xf;
        VkPipelineColorBlendStateCreateInfo blend;
        blend.sType =
            VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        blend.attachmentCount = 1;
        blend.pAttachments = &blendAttachment;
        DepthState depth;
        depth.sType = 46;
        depth.depthTestEnable = 1;
        depth.depthWriteEnable = 1;
        depth.depthCompareOp = 1;
        PushRange push;
        push.stageFlags = VK_SHADER_STAGE_VERTEX_BIT;
        push.size = 64;
        VkPipelineLayoutCreateInfo layoutInfo;
        layoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        layoutInfo.setLayoutCount = 1;
        layoutInfo.pSetLayouts = &terrainDescriptorLayout;
        layoutInfo.pushConstantRangeCount = 1;
        layoutInfo.pPushConstantRanges = &push;
        check(vk.vkCreatePipelineLayout(device, &layoutInfo, null,
            &terrainPipelineLayout), "creating terrain pipeline layout");
        VkGraphicsPipelineCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        info.stageCount = 2;
        info.pStages = stages.ptr;
        info.pVertexInputState = &vertexInput;
        info.pInputAssemblyState = &assembly;
        info.pViewportState = &viewportState;
        info.pRasterizationState = &raster;
        info.pMultisampleState = &multisample;
        info.pDepthStencilState = &depth;
        info.pColorBlendState = &blend;
        info.layout = terrainPipelineLayout;
        info.renderPass = renderPass;
        info.subpass = 0;
        info.basePipelineIndex = -1;
        check(vk.vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &info,
            null, &terrainPipeline), "creating textured terrain pipeline");

        auto detailModule = shader("", "terrain_detail.comp.spv");
        VkPipelineShaderStageCreateInfo detailStage;
        detailStage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        detailStage.stage = 0x20; // COMPUTE
        detailStage.module_ = detailModule;
        detailStage.pName = toStringz("main");
        VkComputePipelineCreateInfo computeInfo;
        computeInfo.sType = 29; // COMPUTE_PIPELINE_CREATE_INFO
        computeInfo.stage = detailStage;
        computeInfo.layout = terrainPipelineLayout;
        computeInfo.basePipelineIndex = -1;
        check(createComputePipelines(device, VK_NULL_HANDLE, 1,
            &computeInfo, null, &terrainDetailPipeline),
            "creating terrain compute pipeline");

        VkCommandBufferBeginInfo computeBegin;
        computeBegin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        computeBegin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        check(vk.vkBeginCommandBuffer(commands, &computeBegin),
            "beginning terrain compute pass");
        vk.vkCmdBindPipeline(commands, 1, terrainDetailPipeline);
        vk.vkCmdBindDescriptorSets(commands, 1, terrainPipelineLayout, 0, 1,
            &terrainDescriptorSet, 0, null);
        cmdDispatch(commands, 1, 1, 1);
        VkBufferMemoryBarrier bufferBarrier;
        bufferBarrier.sType = 44; // BUFFER_MEMORY_BARRIER
        bufferBarrier.srcAccessMask = 0x40; // SHADER_WRITE
        bufferBarrier.dstAccessMask = 0x20; // SHADER_READ
        bufferBarrier.srcQueueFamilyIndex = 0xffffffff;
        bufferBarrier.dstQueueFamilyIndex = 0xffffffff;
        bufferBarrier.buffer = terrainDetailBuffer;
        bufferBarrier.offset = 0;
        bufferBarrier.size = 4;
        vk.vkCmdPipelineBarrier(commands, 0x20, 0x10, 0, 0, null, 1,
            &bufferBarrier, 0, null);
        check(vk.vkEndCommandBuffer(commands),
            "ending terrain compute pass");
        VkSubmitInfo computeSubmit;
        computeSubmit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        computeSubmit.commandBufferCount = 1;
        computeSubmit.pCommandBuffers = &commands;
        check(vk.vkQueueSubmit(queue, 1, &computeSubmit, VK_NULL_HANDLE),
            "submitting terrain compute pass");
        vk.vkQueueWaitIdle(queue);
    }

    private void createAuxTextureArray(string name, int width, int height,
        int layers, int format, ref VkImage image, ref VkDeviceMemory memory,
        ref VkImageView view)
    {
        auto bytes = cast(ubyte[]) read(buildPath(gShaderDir, name));
        if (bytes.length != width * height * 4 * layers)
            throw new Exception("auxiliary texture array has the wrong size");
        VkImageCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        info.imageType = 0;
        info.format = format;
        info.extent = VkExtent3D(width, height, 1);
        info.mipLevels = 1;
        info.arrayLayers = layers;
        info.samples = 1;
        info.tiling = 0;
        info.usage = 0x4 | 0x2;
        info.sharingMode = 0;
        info.initialLayout = 0;
        check(vk.vkCreateImage(device, &info, null, &image),
            "creating auxiliary texture array");
        VkMemoryRequirements requirements;
        vk.vkGetImageMemoryRequirements(device, image, &requirements);
        VkMemoryAllocateInfo allocation;
        allocation.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        allocation.allocationSize = requirements.size;
        allocation.memoryTypeIndex = memoryType(requirements.memoryTypeBits,
            VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        check(vk.vkAllocateMemory(device, &allocation, null, &memory),
            "allocating auxiliary texture memory");
        check(vk.vkBindImageMemory(device, image, memory, 0),
            "binding auxiliary texture memory");
        VkImageViewCreateInfo viewInfo;
        viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        viewInfo.image = image;
        viewInfo.viewType = 1;
        viewInfo.format = format;
        viewInfo.components = VkComponentMapping(0, 0, 0, 0);
        viewInfo.subresourceRange = VkImageSubresourceRange(
            VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, layers);
        check(vk.vkCreateImageView(device, &viewInfo, null, &view),
            "creating auxiliary texture view");
        VkBuffer staging;
        VkDeviceMemory stagingMemory;
        createBuffer(staging, stagingMemory,
            cast(VkDeviceSize) bytes.length, 0x1);
        upload(stagingMemory, bytes);
        VkCommandBufferBeginInfo begin;
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        check(vk.vkBeginCommandBuffer(commands, &begin),
            "beginning auxiliary texture upload");
        VkImageMemoryBarrier barrier;
        barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.oldLayout = 0;
        barrier.newLayout = 7;
        barrier.srcQueueFamilyIndex = 0xffffffff;
        barrier.dstQueueFamilyIndex = 0xffffffff;
        barrier.image = image;
        barrier.subresourceRange = VkImageSubresourceRange(
            VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, layers);
        barrier.srcAccessMask = 0;
        barrier.dstAccessMask = 0x1000;
        vk.vkCmdPipelineBarrier(commands, 0x1, 0x1000, 0, 0, null, 0, null,
            1, &barrier);
        VkBufferImageCopy copy;
        copy.bufferOffset = 0;
        copy.bufferRowLength = 0;
        copy.bufferImageHeight = 0;
        copy.imageSubresource = VkImageSubresourceLayers(
            VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, layers);
        copy.imageOffset = VkOffset3D(0, 0, 0);
        copy.imageExtent = VkExtent3D(width, height, 1);
        vk.vkCmdCopyBufferToImage(commands, staging, image, 7, 1, &copy);
        barrier.oldLayout = 7;
        barrier.newLayout = 5;
        barrier.srcAccessMask = 0x1000;
        barrier.dstAccessMask = 0x20;
        vk.vkCmdPipelineBarrier(commands, 0x1000, 0x10, 0, 0, null, 0, null,
            1, &barrier);
        check(vk.vkEndCommandBuffer(commands),
            "ending auxiliary texture upload");
        VkSubmitInfo submit;
        submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &commands;
        check(vk.vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE),
            "submitting auxiliary texture upload");
        vk.vkQueueWaitIdle(queue);
        vk.vkDestroyBuffer(device, staging, null);
        vk.vkFreeMemory(device, stagingMemory, null);
    }

    private void createHudBuffers()
    {
        createBuffer(hudVertexBuffer, hudVertexMemory,
            cast(VkDeviceSize) MaxHudVertices * MeshVertex.sizeof,
            VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        createBuffer(hudIndexBuffer, hudIndexMemory,
            cast(VkDeviceSize) MaxHudIndices * uint.sizeof,
            VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
    }

    private void uploadHud(MeshVertex[] vertices, uint[] indices)
    {
        if (vertices.length > MaxHudVertices ||
            indices.length > MaxHudIndices)
        {
            hudIndexCount = 0;
            return;
        }
        hudIndexCount = cast(uint) indices.length;
        if (vertices.length != 0)
            upload(hudVertexMemory, vertices);
        if (indices.length != 0)
            upload(hudIndexMemory, indices);
    }

    private void createSkyBuffers()
    {
        MeshVertex[] vertices;
        uint[] indices;
        const auto zenith = runtime.sky.zenith;
        const auto horizon = runtime.sky.horizon;
        const auto ground = runtime.sky.ground;
        const auto sun = runtime.sky.sun;

        enum int Rings = 24;
        enum int Segments = 48;
        const double radius = 4000.0;
        foreach (ring; 0 .. Rings + 1)
        {
            const double theta = 3.14159265358979323846 * ring / Rings;
            const double y = cos(theta);
            const double r = sin(theta);
            float[3] color;
            if (y >= 0)
            {
                const float t = cast(float) y;
                color[0] = horizon[0] + (zenith[0] - horizon[0]) * t;
                color[1] = horizon[1] + (zenith[1] - horizon[1]) * t;
                color[2] = horizon[2] + (zenith[2] - horizon[2]) * t;
            }
            else
            {
                const float t = cast(float) -y;
                color[0] = horizon[0] + (ground[0] - horizon[0]) * t;
                color[1] = horizon[1] + (ground[1] - horizon[1]) * t;
                color[2] = horizon[2] + (ground[2] - horizon[2]) * t;
            }
            foreach (segment; 0 .. Segments + 1)
            {
                const double phi = 2.0 * 3.14159265358979323846 *
                    segment / Segments;
                vertices ~= MeshVertex(
                    cast(float) (r * cos(phi) * radius),
                    cast(float) (y * radius),
                    cast(float) (r * sin(phi) * radius),
                    color[0], color[1], color[2]);
            }
        }
        foreach (ring; 0 .. Rings)
            foreach (segment; 0 .. Segments)
            {
                const uint row = ring * (Segments + 1);
                const uint next = row + Segments + 1;
                const uint a = row + segment;
                const uint b = next + segment;
                indices ~= [a, b, a + 1, b, b + 1, a + 1];
            }

        const double sunLength = sqrt(0.55 * 0.55 + 0.35 * 0.35 +
            0.75 * 0.75);
        const double sunX = 0.55 / sunLength * 3700;
        const double sunY = 0.35 / sunLength * 3700;
        const double sunZ = -0.75 / sunLength * 3700;
        const uint sunBase = cast(uint) vertices.length;
        enum int SunRings = 8;
        enum int SunSegments = 16;
        foreach (ring; 0 .. SunRings + 1)
        {
            const double theta = 3.14159265358979323846 * ring / SunRings;
            const double y = cos(theta);
            const double r = sin(theta);
            foreach (segment; 0 .. SunSegments + 1)
            {
                const double phi = 2.0 * 3.14159265358979323846 *
                    segment / SunSegments;
                vertices ~= MeshVertex(
                    cast(float) (sunX + r * cos(phi) * 260),
                    cast(float) (sunY + y * 260),
                    cast(float) (sunZ + r * sin(phi) * 260),
                    sun[0], sun[1], sun[2]);
            }
        }
        foreach (ring; 0 .. SunRings)
            foreach (segment; 0 .. SunSegments)
            {
                const uint row = sunBase + ring * (SunSegments + 1);
                const uint next = row + SunSegments + 1;
                const uint a = row + segment;
                const uint b = next + segment;
                indices ~= [a, b, a + 1, b, b + 1, a + 1];
            }

        skyIndexCount = cast(uint) indices.length;
        createBuffer(skyVertexBuffer, skyVertexMemory,
            cast(VkDeviceSize) vertices.length * MeshVertex.sizeof,
            VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        upload(skyVertexMemory, vertices);
        createBuffer(skyIndexBuffer, skyIndexMemory,
            cast(VkDeviceSize) indices.length * uint.sizeof,
            VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
        upload(skyIndexMemory, indices);
    }

    private void drawSky(VkCommandBuffer commandBuffer, uint width, uint height)
    {
        if (skyIndexCount == 0 || width == 0 || height == 0) return;
        VkViewport viewport = VkViewport(0, 0, width, height, 0, 1);
        VkRect2D scissor = VkRect2D(VkOffset2D(0, 0),
            VkExtent2D(width, height));
        vk.vkCmdSetViewport(commandBuffer, 0, 1, &viewport);
        vk.vkCmdSetScissor(commandBuffer, 0, 1, &scissor);
        vk.vkCmdBindPipeline(commandBuffer, 0, pipeline);
        VkDeviceSize offset = 0;
        vk.vkCmdBindVertexBuffers(commandBuffer, 0, 1,
            &skyVertexBuffer, &offset);
        vk.vkCmdBindIndexBuffer(commandBuffer, skyIndexBuffer, 0,
            VK_INDEX_TYPE_UINT32);
        auto mvp = matrix(0, width, height, false);
        pushConstants(commandBuffer, pipelineLayout,
            VK_SHADER_STAGE_VERTEX_BIT, 0, 64, &mvp);
        vk.vkCmdDrawIndexed(commandBuffer, skyIndexCount, 1, 0, 0, 0);
    }

    private void addBox(ref MeshVertex[] vertices, ref uint[] indices,
        double cx, double cy, double cz, double sx, double sy, double sz,
        float r, float g, float b)
    {
        const uint base = cast(uint) vertices.length;
        const float x0 = cast(float) (cx - sx / 2);
        const float x1 = cast(float) (cx + sx / 2);
        const float y0 = cast(float) (cy - sy / 2);
        const float y1 = cast(float) (cy + sy / 2);
        const float z0 = cast(float) (cz - sz / 2);
        const float z1 = cast(float) (cz + sz / 2);
        vertices ~= MeshVertex(x0, y0, z0, r, g, b);
        vertices ~= MeshVertex(x1, y0, z0, r, g, b);
        vertices ~= MeshVertex(x1, y1, z0, r, g, b);
        vertices ~= MeshVertex(x0, y1, z0, r, g, b);
        vertices ~= MeshVertex(x0, y0, z1, r, g, b);
        vertices ~= MeshVertex(x1, y0, z1, r, g, b);
        vertices ~= MeshVertex(x1, y1, z1, r, g, b);
        vertices ~= MeshVertex(x0, y1, z1, r, g, b);
        indices ~= [
            base, base + 1, base + 2, base, base + 2, base + 3,
            base + 4, base + 6, base + 5, base + 4, base + 7, base + 6,
            base, base + 4, base + 5, base, base + 5, base + 1,
            base + 3, base + 2, base + 6, base + 3, base + 6, base + 7,
            base, base + 3, base + 7, base, base + 7, base + 4,
            base + 1, base + 5, base + 6, base + 1, base + 6, base + 2
        ];
    }

    private void createVegetationMesh()
    {
        MeshVertex[] vertices;
        uint[] indices;
        foreach (plant; game.plants)
        {
            const y = cast(float) runtime.world.terrainHeight(plant.x, plant.z);
            if (plant.kind == 1)
            {
                addBox(vertices, indices, plant.x, y + 1.1 * plant.scale,
                    plant.z, 0.24, 2.2 * plant.scale, 0.24,
                    0.24f, 0.16f, 0.08f);
                addBox(vertices, indices, plant.x, y + 2.8 * plant.scale,
                    plant.z, 1.2 * plant.scale, 1.8 * plant.scale,
                    1.2 * plant.scale, 0.13f, 0.38f, 0.12f);
            }
            else
            {
                addBox(vertices, indices, plant.x, y + 0.35 * plant.scale,
                    plant.z, 0.12, 0.7 * plant.scale, 0.12,
                    0.20f, 0.50f, 0.14f);
                addBox(vertices, indices, plant.x, y + 0.35 * plant.scale,
                    plant.z, 0.48, 0.08 * plant.scale, 0.12,
                    0.24f, 0.56f, 0.16f);
            }
        }
        vegetationIndexCount = cast(uint) indices.length;
        if (indices.length == 0) return;
        createBuffer(vegetationVertexBuffer, vegetationVertexMemory,
            cast(VkDeviceSize) vertices.length * MeshVertex.sizeof,
            VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        upload(vegetationVertexMemory, vertices);
        createBuffer(vegetationIndexBuffer, vegetationIndexMemory,
            cast(VkDeviceSize) indices.length * uint.sizeof,
            VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
        upload(vegetationIndexMemory, indices);
    }

    private void createActorMeshBuffers()
    {
        enum uint maxVertices = 8192;
        enum uint maxIndices = 16384;
        createBuffer(actorVertexBuffer, actorVertexMemory,
            cast(VkDeviceSize) maxVertices * MeshVertex.sizeof,
            VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        createBuffer(actorIndexBuffer, actorIndexMemory,
            cast(VkDeviceSize) maxIndices * uint.sizeof,
            VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
    }

    private void updateActorMesh()
    {
        actorVertexCache.length = 0;
        actorIndexCache.length = 0;
        foreach (actor; game.actors)
        {
            if (!actor.alive) continue;
            const float br = actor.zombie ? 0.62f : 0.18f;
            const float bg = actor.zombie ? 0.10f : 0.30f;
            const float bb = actor.zombie ? 0.08f : 0.62f;
            addBox(actorVertexCache, actorIndexCache, actor.x,
                actor.y + 1.0, actor.z, 0.72, 1.25, 0.42, br, bg, bb);
            addBox(actorVertexCache, actorIndexCache, actor.x,
                actor.y + 1.85, actor.z, 0.42, 0.42, 0.42,
                actor.zombie ? 0.78f : 0.58f,
                actor.zombie ? 0.42f : 0.68f,
                actor.zombie ? 0.34f : 0.45f);
            addBox(actorVertexCache, actorIndexCache, actor.x - 0.43,
                actor.y + 1.0, actor.z, 0.18, 0.75, 0.24, br, bg, bb);
            addBox(actorVertexCache, actorIndexCache, actor.x + 0.43,
                actor.y + 1.0, actor.z, 0.18, 0.75, 0.24, br, bg, bb);
            addBox(actorVertexCache, actorIndexCache, actor.x - 0.2,
                actor.y + 0.25, actor.z, 0.22, 0.75, 0.28, br, bg, bb);
            addBox(actorVertexCache, actorIndexCache, actor.x + 0.2,
                actor.y + 0.25, actor.z, 0.22, 0.75, 0.28, br, bg, bb);
        }
        const float cp = cast(float) cos(camPitch);
        const float fx = cast(float) (sin(camYaw) * cp);
        const float fy = cast(float) sin(camPitch);
        const float fz = cast(float) (-cos(camYaw) * cp);
        const float rx = cast(float) cos(camYaw);
        const float rz = cast(float) sin(camYaw);
        addBox(actorVertexCache, actorIndexCache,
            camX + fx * 1.0 + rx * 0.28,
            camY + fy * 1.0 - 0.25,
            camZ + fz * 1.0 + rz * 0.28,
            0.10, 0.10, 0.28, 0.10f, 0.12f, 0.16f);
        actorIndexCount = cast(uint) actorIndexCache.length;
        if (actorIndexCount == 0) return;
        upload(actorVertexMemory, actorVertexCache);
        upload(actorIndexMemory, actorIndexCache);
    }

    private void drawWorldProps(VkCommandBuffer commandBuffer, uint width,
        uint height, float[16] mvp)
    {
        if (vegetationIndexCount == 0 && actorIndexCount == 0) return;
        VkViewport viewport = VkViewport(0, 0, width, height, 0, 1);
        VkRect2D scissor = VkRect2D(VkOffset2D(0, 0),
            VkExtent2D(width, height));
        vk.vkCmdSetViewport(commandBuffer, 0, 1, &viewport);
        vk.vkCmdSetScissor(commandBuffer, 0, 1, &scissor);
        vk.vkCmdBindPipeline(commandBuffer, 0, pipeline);
        pushConstants(commandBuffer, pipelineLayout,
            VK_SHADER_STAGE_VERTEX_BIT, 0, 64, &mvp);
        VkDeviceSize offset = 0;
        if (vegetationIndexCount != 0)
        {
            vk.vkCmdBindVertexBuffers(commandBuffer, 0, 1,
                &vegetationVertexBuffer, &offset);
            vk.vkCmdBindIndexBuffer(commandBuffer, vegetationIndexBuffer, 0,
                VK_INDEX_TYPE_UINT32);
            vk.vkCmdDrawIndexed(commandBuffer, vegetationIndexCount, 1, 0, 0,
                0);
        }
        if (actorIndexCount != 0)
        {
            vk.vkCmdBindVertexBuffers(commandBuffer, 0, 1, &actorVertexBuffer,
                &offset);
            vk.vkCmdBindIndexBuffer(commandBuffer, actorIndexBuffer, 0,
                VK_INDEX_TYPE_UINT32);
            vk.vkCmdDrawIndexed(commandBuffer, actorIndexCount, 1, 0, 0, 0);
        }
    }

    private float[16] hudMatrix(uint width, uint height)
    {
        float[16] result;
        result[] = 0;
        if (width == 0 || height == 0) return result;
        result[0] = 2.0f / width;
        result[5] = 2.0f / height;
        result[10] = 1.0f;
        result[12] = -1.0f;
        result[13] = -1.0f;
        result[15] = 1.0f;
        return result;
    }

    private void hudQuad(ref MeshVertex[] vertices, ref uint[] indices,
        float x0, float y0, float x1, float y1, float r, float g, float b)
    {
        const uint base = cast(uint) vertices.length;
        vertices ~= MeshVertex(x0, y0, 0, r, g, b);
        vertices ~= MeshVertex(x1, y0, 0, r, g, b);
        vertices ~= MeshVertex(x1, y1, 0, r, g, b);
        vertices ~= MeshVertex(x0, y1, 0, r, g, b);
        indices ~= [base, base + 1, base + 2, base, base + 2, base + 3];
    }

    private void hudText(ref MeshVertex[] vertices, ref uint[] indices,
        float x, float y, string text, float r, float g, float b)
    {
        foreach (ch; text)
        {
            if (ch != ' ')
            {
                const glyph = glyphBits(ch);
                foreach (gy; 0 .. GlyphHeight)
                    foreach (gx; 0 .. GlyphWidth)
                        if (glyphPixel(glyph, gx, gy))
                            hudQuad(vertices, indices,
                                x + gx * HudScale, y + gy * HudScale,
                                x + (gx + 1) * HudScale,
                                y + (gy + 1) * HudScale, r, g, b);
            }
            x += GlyphAdvance * HudScale;
        }
    }

    private string cardinal(double yaw)
    {
        double degrees = yaw * 180.0 / 3.14159265358979323846;
        degrees = degrees % 360.0;
        if (degrees < 0) degrees += 360.0;
        static immutable string[] labels = [
            "N", "NE", "E", "SE", "S", "SW", "W", "NW",
        ];
        return labels[cast(int) ((degrees + 22.5) / 45.0) % 8];
    }

    private void updateHudToggle()
    {
        const bool down = keyDown(0x70); // F1
        const bool focused = !gStandaloneWindow ||
            GetForegroundWindow() == gChildWindow;
        if (focused && down && !hudToggleDown)
        {
            hudVisible = !hudVisible;
            hudDirty = true;
        }
        hudToggleDown = down;
    }

    private void updateHud(uint width, uint height)
    {
        if (hudVertexCache.capacity < MaxHudVertices)
            hudVertexCache.reserve(MaxHudVertices);
        if (hudIndexCache.capacity < MaxHudIndices)
            hudIndexCache.reserve(MaxHudIndices);
        hudVertexCache.length = 0;
        hudIndexCache.length = 0;
        MeshVertex[] vertices = hudVertexCache;
        uint[] indices = hudIndexCache;
        if (!hudVisible || width == 0 || height == 0)
        {
            hudIndexCount = 0;
            return;
        }

        char[64] fpsBuffer;
        char[64] positionBuffer;
        char[64] yawBuffer;
        char[64] materialBuffer;
        const fpsLength = snprintf(fpsBuffer.ptr, fpsBuffer.length,
            "FPS %.0f", hudFps);
        const positionLength = snprintf(positionBuffer.ptr,
            positionBuffer.length, "X %.1f  Z %.1f", camX, camZ);
        const yawLength = snprintf(yawBuffer.ptr, yawBuffer.length,
            "Y %.1f  YAW %.2f", camY, camYaw);
        const materialNameText = materialName(
            cast(TerrainMaterial) materialIndex);
        const materialLength = snprintf(materialBuffer.ptr,
            materialBuffer.length, "MATERIAL %.*s",
            cast(int) materialNameText.length, materialNameText.ptr);
        string[9] lines = [
            "TERRAIN INFO",
            cast(string) fpsBuffer[0 .. fpsLength],
            cast(string) positionBuffer[0 .. positionLength],
            cast(string) yawBuffer[0 .. yawLength],
            cast(string) materialBuffer[0 .. materialLength],
            "WASD MOVE  SHIFT SPRINT  SPACE JUMP",
            "LMB FIRE  RMB DIG  B BUILD",
            "1-4 MATERIAL  ESC RELEASE",
            "F1 HIDE INFO"
        ];
        size_t maxLine;
        foreach (line; lines)
            if (line.length > maxLine) maxLine = line.length;
        const float margin = 12;
        const float padding = 12;
        float panelWidth = cast(float) maxLine * GlyphAdvance * HudScale +
            padding * 2;
        const float available = cast(float) width - margin * 2;
        if (panelWidth > available) panelWidth = available;
        const float lineStep = cast(float) LineAdvance * HudScale + 4;
        const float panelHeight =
            cast(float) lines.length * lineStep + padding * 2;
        float panelX = cast(float) width - panelWidth - margin;
        if (panelX < margin) panelX = margin;
        const float panelY = margin;
        hudQuad(vertices, indices, panelX, panelY, panelX + panelWidth,
            panelY + panelHeight, 0.018f, 0.035f, 0.065f);
        const float border = 2;
        hudQuad(vertices, indices, panelX, panelY, panelX + panelWidth,
            panelY + border, 0.12f, 0.32f, 0.48f);
        hudQuad(vertices, indices, panelX, panelY + panelHeight - border,
            panelX + panelWidth, panelY + panelHeight, 0.12f, 0.32f, 0.48f);
        hudQuad(vertices, indices, panelX, panelY, panelX + border,
            panelY + panelHeight, 0.12f, 0.32f, 0.48f);
        hudQuad(vertices, indices, panelX + panelWidth - border, panelY,
            panelX + panelWidth, panelY + panelHeight, 0.12f, 0.32f, 0.48f);
        float y = panelY + padding;
        foreach (lineIndex, line; lines)
        {
            float x = panelX + padding;
            const bool title = lineIndex == 0;
            const bool hint = lineIndex >= 4;
            const float r = title ? 0.35f : hint ? 0.62f : 0.86f;
            const float g = title ? 0.85f : hint ? 0.78f : 0.94f;
            const float b = title ? 1.0f : hint ? 0.88f : 1.0f;
            hudText(vertices, indices, x, y, line, r, g, b);
            y += lineStep;
        }

        const float compassWidth = 470;
        const float compassHeight = 38;
        const float compassX = (cast(float) width - compassWidth) / 2;
        const float compassY = 8;
        hudQuad(vertices, indices, compassX, compassY,
            compassX + compassWidth, compassY + compassHeight,
            0.015f, 0.035f, 0.060f);
        hudQuad(vertices, indices, compassX, compassY,
            compassX + compassWidth, compassY + 2,
            0.20f, 0.55f, 0.75f);
        foreach (tick; 0 .. 9)
        {
            const float tickX = compassX + compassWidth / 2 +
                (tick - 4) * 52;
            hudQuad(vertices, indices, tickX, compassY + 25,
                tickX + 2, compassY + 33, 0.35f, 0.72f, 0.88f);
        }
        double degrees = camYaw * 180.0 /
            3.14159265358979323846;
        degrees = degrees % 360.0;
        if (degrees < 0) degrees += 360.0;
        char[32] compassBuffer;
        const compassDirection = cardinal(camYaw);
        const compassLength = snprintf(compassBuffer.ptr,
            compassBuffer.length, "%03d  %.*s",
            cast(int) degrees, cast(int) compassDirection.length,
            compassDirection.ptr);
        const string compass =
            cast(string) compassBuffer[0 .. compassLength];
        hudText(vertices, indices, compassX + compassWidth / 2 -
            cast(float) compass.length * GlyphAdvance * HudScale / 2,
            compassY + 7, compass, 0.75f, 0.93f, 1.0f);

        const float slotWidth = 118;
        const float slotHeight = 76;
        const float slotGap = 8;
        const float beltWidth = slotWidth * 4 + slotGap * 3;
        const float beltX = (cast(float) width - beltWidth) / 2;
        const float beltY = cast(float) height - slotHeight - 16;
        hudQuad(vertices, indices, beltX - 8, beltY - 8,
            beltX + beltWidth + 8, beltY + slotHeight + 8,
            0.012f, 0.025f, 0.045f);
        foreach (slot; 0 .. 4)
        {
            const float x0 = beltX + slot * (slotWidth + slotGap);
            const bool selected = slot == materialIndex;
            hudQuad(vertices, indices, x0, beltY, x0 + slotWidth,
                beltY + slotHeight, selected
                    ? 0.10f : 0.025f, selected ? 0.28f : 0.055f,
                selected ? 0.36f : 0.09f);
            hudQuad(vertices, indices, x0, beltY, x0 + slotWidth,
                beltY + 2, selected ? 0.45f : 0.22f,
                selected ? 0.85f : 0.38f, selected ? 1.0f : 0.48f);
            char[8] slotBuffer;
            const slotLength = snprintf(slotBuffer.ptr, slotBuffer.length,
                "%d", slot + 1);
            hudText(vertices, indices, x0 + 8, beltY + 12,
                cast(string) slotBuffer[0 .. slotLength],
                0.55f, 0.80f, 0.90f);
            hudText(vertices, indices, x0 + 8, beltY + 38,
                materialName(cast(TerrainMaterial) slot),
                0.82f, 0.92f, 0.95f);
        }

        const float barX = 16;
        const float barY = cast(float) height - 174;
        const float barWidth = 248;
        hudText(vertices, indices, barX, barY - 22, "HEALTH",
            0.86f, 0.40f, 0.38f);
        hudQuad(vertices, indices, barX, barY, barX + barWidth,
            barY + 16, 0.08f, 0.05f, 0.06f);
        hudQuad(vertices, indices, barX, barY,
            barX + barWidth * cast(float) (health / 100.0),
            barY + 16, 0.78f, 0.18f, 0.20f);
        hudQuad(vertices, indices, barX, barY, barX + 2,
            barY + 16, 0.92f, 0.40f, 0.38f);
        hudText(vertices, indices, barX, barY + 22, "STAMINA",
            0.52f, 0.82f, 0.42f);
        const float staminaY = barY + 44;
        hudQuad(vertices, indices, barX, staminaY, barX + barWidth,
            staminaY + 16, 0.05f, 0.07f, 0.05f);
        hudQuad(vertices, indices, barX, staminaY,
            barX + barWidth * cast(float) (stamina / 100.0),
            staminaY + 16, 0.30f, 0.72f, 0.30f);
        hudQuad(vertices, indices, barX, staminaY, barX + 2,
            staminaY + 16, 0.55f, 0.88f, 0.45f);

        const float crossX = cast(float) width / 2;
        const float crossY = cast(float) height / 2;
        const float crossColor = game.hitFlash > 0 ? 1.0f : 0.86f;
        hudQuad(vertices, indices, crossX - 12, crossY - 1,
            crossX + 12, crossY + 1, crossColor, 0.86f, 0.86f);
        hudQuad(vertices, indices, crossX - 1, crossY - 12,
            crossX + 1, crossY + 12, crossColor, 0.86f, 0.86f);
        const float combatX = cast(float) width - 430;
        const float combatY = cast(float) height - 320;
        hudQuad(vertices, indices, combatX - 10, combatY - 10,
            cast(float) width - 16, combatY + 64,
            0.012f, 0.025f, 0.045f);
        char[96] combatBuffer;
        int aliveZombies;
        foreach (actor; game.actors)
            if (actor.zombie && actor.alive) ++aliveZombies;
        const combatLength = snprintf(combatBuffer.ptr, combatBuffer.length,
            "AMMO %d / %d   SCORE %d", game.ammo, game.reserve,
            game.score);
        hudText(vertices, indices, combatX, combatY,
            cast(string) combatBuffer[0 .. combatLength],
            0.90f, 0.82f, 0.42f);
        char[64] zombieBuffer;
        const zombieLength = snprintf(zombieBuffer.ptr, zombieBuffer.length,
            "ZOMBIES %d   KILLS %d", aliveZombies,
            game.zombieKills);
        hudText(vertices, indices, combatX, combatY + 28,
            cast(string) zombieBuffer[0 .. zombieLength],
            0.55f, 0.82f, 0.62f);

        const float notifyWidth = 350;
        const float notifyHeight = 116;
        const float notifyX = cast(float) width - notifyWidth - 16;
        const float notifyY = cast(float) height - notifyHeight - 112;
        hudQuad(vertices, indices, notifyX, notifyY,
            notifyX + notifyWidth, notifyY + notifyHeight,
            0.012f, 0.025f, 0.045f);
        hudQuad(vertices, indices, notifyX, notifyY,
            notifyX + notifyWidth, notifyY + 2,
            0.35f, 0.55f, 0.65f);
        hudText(vertices, indices, notifyX + 10, notifyY + 10,
            "EVENTS", 0.55f, 0.82f, 0.92f);
        if (notifications.length == 0)
            hudText(vertices, indices, notifyX + 10, notifyY + 38,
                "SYSTEM READY", 0.42f, 0.58f, 0.64f);
        else
        {
            const int first = notifications.length > 4
                ? cast(int) notifications.length - 4 : 0;
            foreach (index; first .. cast(int) notifications.length)
                hudText(vertices, indices, notifyX + 10,
                    notifyY + 38 + (index - first) * 18,
                    notifications[index], 0.72f, 0.86f, 0.88f);
        }
        hudVertexCache = vertices;
        hudIndexCache = indices;
        uploadHud(vertices, indices);
    }

    private void createBuffer(ref VkBuffer buffer, ref VkDeviceMemory memory,
        VkDeviceSize size, VkFlags usage)
    {
        VkBufferCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        info.size = size;
        info.usage = usage;
        info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        check(vk.vkCreateBuffer(device, &info, null, &buffer),
            "creating a buffer");
        VkMemoryRequirements requirements;
        vk.vkGetBufferMemoryRequirements(device, buffer, &requirements);
        VkMemoryAllocateInfo allocation;
        allocation.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        allocation.allocationSize = requirements.size;
        allocation.memoryTypeIndex = memoryType(requirements.memoryTypeBits,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
            VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        check(vk.vkAllocateMemory(device, &allocation, null, &memory),
            "allocating buffer memory");
        check(vk.vkBindBufferMemory(device, buffer, memory, 0),
            "binding buffer memory");
    }

    private void createReadbackBuffer()
    {
        VkBufferCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        info.size = cast(VkDeviceSize) Width * Height * 4;
        info.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
        info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        check(vk.vkCreateBuffer(device, &info, null, &readBuffer),
            "creating the readback buffer");
        VkMemoryRequirements requirements;
        vk.vkGetBufferMemoryRequirements(device, readBuffer, &requirements);
        const wanted = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
            VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        enum uint hostCached = 0x8;
        uint typeIndex = uint.max;
        foreach (index; 0 .. memoryProperties.memoryTypeCount)
            if ((requirements.memoryTypeBits & (1u << index)) != 0 &&
                (memoryProperties.memoryTypes[index].propertyFlags &
                    (wanted | hostCached)) == (wanted | hostCached))
            {
                typeIndex = index;
                break;
            }
        if (typeIndex == uint.max)
            typeIndex = memoryType(requirements.memoryTypeBits, wanted);
        VkMemoryAllocateInfo allocation;
        allocation.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        allocation.allocationSize = requirements.size;
        allocation.memoryTypeIndex = typeIndex;
        check(vk.vkAllocateMemory(device, &allocation, null, &readMemory),
            "allocating readback memory");
        check(vk.vkBindBufferMemory(device, readBuffer, readMemory, 0),
            "binding readback memory");
    }


    private void upload(VkDeviceMemory memory, const(void)[] data)
    {
        void* mapped;
        check(vk.vkMapMemory(device, memory, 0, data.length, 0, &mapped),
            "mapping buffer memory");
        memcpy(mapped, data.ptr, data.length);
        vk.vkUnmapMemory(device, memory);
    }

    private void createBuffers(TerrainChunk[] terrainChunks)
    {
        chunkData = terrainChunks;
        chunkLods.length = terrainChunks.length;
        uint vertexTotal;
        uint indexTotal;
        foreach (index, chunk; terrainChunks)
        {
            chunkLods[index].length = 2;
            foreach (lod; 0 .. 2)
            {
                auto mesh = chunk.lods[lod];
                auto gpu = ChunkGpu();
                gpu.centerX = chunk.centerX;
                gpu.centerZ = chunk.centerZ;
                gpu.indexCount = cast(uint) mesh.indices.length;
                if (gpu.indexCount != 0)
                {
                    createBuffer(gpu.vertexBuffer, gpu.vertexMemory,
                        cast(VkDeviceSize) mesh.vertices.length * MeshVertex.sizeof,
                        VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
                    upload(gpu.vertexMemory, mesh.vertices);
                    createBuffer(gpu.indexBuffer, gpu.indexMemory,
                        cast(VkDeviceSize) mesh.indices.length * uint.sizeof,
                        VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
                    upload(gpu.indexMemory, mesh.indices);
                }
                vertexTotal += cast(uint) mesh.vertices.length;
                indexTotal += cast(uint) mesh.indices.length;
                chunkLods[index][lod] = gpu;
            }
        }
        stdout.writeln("vulkan3d: chunks=", terrainChunks.length,
            " lods=2 vertices=", vertexTotal, " indices=", indexTotal);
        stdout.flush();
        createReadbackBuffer();
    }

    private void uploadChunkGpu(int index, TerrainChunk chunk,
        bool waitForDevice = true)
    {
        chunkData[index] = chunk;
        if (waitForDevice)
            vk.vkDeviceWaitIdle(device);
        foreach (lod; 0 .. 2)
        {
            auto previous = chunkLods[index][lod];
            if (previous.vertexBuffer != VkBuffer.init)
                vk.vkDestroyBuffer(device, previous.vertexBuffer, null);
            if (previous.vertexMemory != VkDeviceMemory.init)
                vk.vkFreeMemory(device, previous.vertexMemory, null);
            if (previous.indexBuffer != VkBuffer.init)
                vk.vkDestroyBuffer(device, previous.indexBuffer, null);
            if (previous.indexMemory != VkDeviceMemory.init)
                vk.vkFreeMemory(device, previous.indexMemory, null);

            auto mesh = chunk.lods[lod];
            auto gpu = ChunkGpu();
            gpu.centerX = chunk.centerX;
            gpu.centerZ = chunk.centerZ;
            gpu.indexCount = cast(uint) mesh.indices.length;
            if (gpu.indexCount != 0)
            {
                createBuffer(gpu.vertexBuffer, gpu.vertexMemory,
                    cast(VkDeviceSize) mesh.vertices.length * MeshVertex.sizeof,
                    VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
                upload(gpu.vertexMemory, mesh.vertices);
                createBuffer(gpu.indexBuffer, gpu.indexMemory,
                    cast(VkDeviceSize) mesh.indices.length * uint.sizeof,
                    VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
                upload(gpu.indexMemory, mesh.indices);
            }
            chunkLods[index][lod] = gpu;
        }
    }

    private void rebuildTerrainAround(double x, double z, double radius)
    {
        const config = runtime.world;
        int cx0 = cast(int) floor((x - radius - config.minX) /
            config.chunkSizeX);
        int cx1 = cast(int) floor((x + radius - config.minX) /
            config.chunkSizeX);
        int cz0 = cast(int) floor((z - radius - config.minZ) /
            config.chunkSizeZ);
        int cz1 = cast(int) floor((z + radius - config.minZ) /
            config.chunkSizeZ);
        if (cx0 < 0) cx0 = 0;
        if (cz0 < 0) cz0 = 0;
        if (cx1 >= config.chunksX) cx1 = config.chunksX - 1;
        if (cz1 >= config.chunksZ) cz1 = config.chunksZ - 1;
        int[] indices;
        foreach (cz; cz0 .. cz1 + 1)
            foreach (cx; cx0 .. cx1 + 1)
                indices ~= cz * config.chunksX + cx;
        if (indices.length == 0)
            return;
        if (rebuildJob !is null)
        {
            if (!rebuildJob.finished)
            {
                queueDirty(indices);
                return;
            }
            pollTerrainRebuild();
            if (rebuildJob !is null)
            {
                queueDirty(indices);
                return;
            }
        }
        startRebuild(indices);
    }

    private void startRebuild(int[] indices)
    {
        if (indices.length == 0) return;
        enum int editBatchChunks = 4;
        if (indices.length > editBatchChunks)
        {
            queueDirty(indices[editBatchChunks .. $]);
            indices = indices[0 .. editBatchChunks];
        }
        rebuildJob = new TerrainChunkRebuild(runtime.world, runtime.lights,
            indices);
        rebuildJob.start();
    }

    private void queueDirty(const int[] indices)
    {
        const total = runtime.world.chunksX * runtime.world.chunksZ;
        if (pendingDirty.length < total)
            pendingDirty.length = total;
        foreach (index; indices)
        {
            if (index < 0 || index >= total || pendingDirty[index])
                continue;
            pendingDirty[index] = true;
            pendingDirtyList ~= index;
        }
    }

    private void pollTerrainRebuild()
    {
        if (rebuildJob is null || !rebuildJob.finished)
            return;
        auto job = rebuildJob;
        rebuildJob = null;
        job.take();
        if (job.chunks.length != 0)
            vk.vkDeviceWaitIdle(device);
        foreach (slot, index; job.indices)
            uploadChunkGpu(index, job.chunks[slot], false);
        hudDirty = true;
        if (pendingDirtyList.length != 0)
        {
            auto next = pendingDirtyList;
            pendingDirtyList = [ ];
            foreach (index; next)
                pendingDirty[index] = false;
            startRebuild(next);
        }
    }

    private void updateTerrainTools()
    {
        int requestedMaterial = materialIndex;
        if (keyDown(0x31)) requestedMaterial = 0;
        else if (keyDown(0x32)) requestedMaterial = 1;
        else if (keyDown(0x33)) requestedMaterial = 2;
        else if (keyDown(0x34)) requestedMaterial = 3;
        if (requestedMaterial != materialIndex)
        {
            materialIndex = requestedMaterial;
            notifications ~= format("MATERIAL  %s",
                materialName(cast(TerrainMaterial) materialIndex));
            if (notifications.length > 4)
                notifications = notifications[$ - 4 .. $];
            hudDirty = true;
        }
        if (!mouseCaptured)
        {
            digHeld = false;
            buildHeld = false;
            return;
        }
        const bool dig = keyDown(0x02);
        const bool build = keyDown(0x42);
        if (!dig && !build)
        {
            digHeld = false;
            buildHeld = false;
            return;
        }
        if ((dig && digHeld) || (build && buildHeld)) return;

        const double cp = cos(camPitch);
        const double fx = sin(camYaw) * cp;
        const double fy = sin(camPitch);
        const double fz = -cos(camYaw) * cp;
        bool found;
        double hitX, hitZ;
        for (double distance = 1.0; distance < 90.0; distance += 0.5)
        {
            const x = camX + fx * distance;
            const y = camY + fy * distance;
            const z = camZ + fz * distance;
            if (y <= runtime.world.terrainHeight(x, z))
            {
                hitX = x;
                hitZ = z;
                found = true;
                break;
            }
        }
        if (!found)
        {
            digHeld = dig;
            buildHeld = build;
            return;
        }
        const material = cast(TerrainMaterial) materialIndex;
        runtime.world.addEdit(hitX, hitZ, 8.0, dig ? -5.0 : 5.0, material);
        rebuildTerrainAround(hitX, hitZ, 8.0);
        notifications ~= format("%s  %s", dig ? "DIG" : "BUILD",
            materialName(material));
        if (notifications.length > 4)
            notifications = notifications[$ - 4 .. $];
        hudDirty = true;
        digHeld = dig;
        buildHeld = build;
    }

    private void drawTerrain(VkCommandBuffer commandBuffer)
    {
        vk.vkCmdBindDescriptorSets(commandBuffer, 0, terrainPipelineLayout,
            0, 1, &terrainDescriptorSet, 0, null);
        VkDeviceSize offset = 0;
        foreach (chunk; chunkLods)
        {
            const dx = chunk[0].centerX - camX;
            const dz = chunk[0].centerZ - camZ;
            const lodDistance = runtime.world.lodNearDistance;
            const lod = (dx * dx + dz * dz) > lodDistance * lodDistance
                ? 1 : 0;
            auto gpu = chunk[lod];
            if (gpu.indexCount == 0) continue;
            vk.vkCmdBindVertexBuffers(commandBuffer, 0, 1,
                &gpu.vertexBuffer, &offset);
            vk.vkCmdBindIndexBuffer(commandBuffer, gpu.indexBuffer, 0,
                VK_INDEX_TYPE_UINT32);
            vk.vkCmdDrawIndexed(commandBuffer, gpu.indexCount, 1, 0, 0, 0);
        }
    }

    private void drawHud(VkCommandBuffer commandBuffer, uint width, uint height)
    {
        if (!hudVisible || hudIndexCount == 0) return;
        VkViewport viewport = VkViewport(0, 0, width, height, 0, 1);
        VkRect2D scissor = VkRect2D(VkOffset2D(0, 0),
            VkExtent2D(width, height));
        vk.vkCmdSetViewport(commandBuffer, 0, 1, &viewport);
        vk.vkCmdSetScissor(commandBuffer, 0, 1, &scissor);
        vk.vkCmdBindPipeline(commandBuffer, 0, hudPipeline);
        VkDeviceSize offset = 0;
        vk.vkCmdBindVertexBuffers(commandBuffer, 0, 1,
            &hudVertexBuffer, &offset);
        vk.vkCmdBindIndexBuffer(commandBuffer, hudIndexBuffer, 0,
            VK_INDEX_TYPE_UINT32);
        auto mvp = hudMatrix(width, height);
        pushConstants(commandBuffer, pipelineLayout,
            VK_SHADER_STAGE_VERTEX_BIT, 0, 64, &mvp);
        vk.vkCmdDrawIndexed(commandBuffer, hudIndexCount, 1, 0, 0, 0);
    }

    private void createCommands()
    {
        VkCommandPoolCreateInfo poolInfo;
        poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        poolInfo.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        poolInfo.queueFamilyIndex = queueFamily;
        check(vk.vkCreateCommandPool(device, &poolInfo, null, &commandPool),
            "creating a command pool");
        VkCommandBufferAllocateInfo allocate;
        allocate.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        allocate.commandPool = commandPool;
        allocate.level = 0;
        allocate.commandBufferCount = 1;
        check(vk.vkAllocateCommandBuffers(device, &allocate, &commands),
            "allocating a command buffer");
        VkFenceCreateInfo fenceInfo;
        fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        check(vk.vkCreateFence(device, &fenceInfo, null, &fence),
            "creating a submit fence");
    }

    private bool keyDown(int key)
    {
        return (cast(int) GetAsyncKeyState(key) & 0x8000) != 0;
    }

    private void updateCamera(double seconds, double dt)
    {
        if (dt <= 0) return;
        if (dt > 0.1) dt = 0.1;
        if (keyDown(0x25)) camYaw -= 2.0 * dt;
        if (keyDown(0x27)) camYaw += 2.0 * dt;
        if (keyDown(0x26)) camPitch += 1.4 * dt;
        if (keyDown(0x28)) camPitch -= 1.4 * dt;
        if (camPitch < -1.15) camPitch = -1.15;
        if (camPitch > 1.15) camPitch = 1.15;
        PlayerInput input;
        input.forward = keyDown(0x57);
        input.back = keyDown(0x53);
        input.left = keyDown(0x41);
        input.right = keyDown(0x44);
        input.sprint = keyDown(0x10) && stamina > 2;
        input.jump = keyDown(0x20);
        player.x = camX;
        player.y = camY;
        player.z = camZ;
        player.yaw = camYaw;
        player.velocityX = velocityX;
        player.velocityZ = velocityZ;
        updatePlayer(player, runtime.world, input, dt);
        camX = player.x;
        camY = player.y;
        camZ = player.z;
        velocityX = player.velocityX;
        velocityZ = player.velocityZ;
        const bool moving = input.forward || input.back ||
            input.left || input.right;
        if (input.sprint && moving)
            stamina = stamina - 22.0 * dt < 0 ? 0 :
                stamina - 22.0 * dt;
        else
            stamina = stamina + 12.0 * dt > 100 ? 100 :
                stamina + 12.0 * dt;
        pollTerrainRebuild();
        updateTerrainTools();
        bool didFire;
        updateGame(game, runtime.world, camX, camZ, camY, camYaw, dt,
            mouseCaptured && keyDown(0x01), mouseCaptured, didFire);
        health = game.playerHealth;
        if (didFire || game.damageFlash > 0)
            hudDirty = true;
    }

    private void setMouseCapture(bool captured)
    {
        if (mouseCaptured == captured) return;
        mouseCaptured = captured;
        if (!gStandaloneWindow) return;
        if (captured)
        {
            if (!cursorHidden)
            {
                ShowCursor(0);
                cursorHidden = true;
            }
        }
        else if (cursorHidden)
        {
            ShowCursor(1);
            cursorHidden = false;
        }
    }

    private void updateMouse()
    {
        if (mouseWindow !is null && !IsWindow(mouseWindow))
        {
            setMouseCapture(false);
            mouseWindow = null;
        }
        if (mouseWindow is null)
            mouseWindow = FindWindowA(null, mouseTitle.toStringz);
        if (mouseWindow is null)
        {
            setMouseCapture(false);
            return;
        }
        if (IsIconic(mouseWindow))
        {
            setMouseCapture(false);
            return;
        }
        if (GetForegroundWindow() != mouseWindow)
        {
            setMouseCapture(false);
            return;
        }
        RECT client;
        GetClientRect(mouseWindow, &client);
        POINT center;
        center.x = client.right / 2;
        center.y = client.bottom / 2;
        if (center.x <= 0 || center.y <= 0) return;
        ClientToScreen(mouseWindow, &center);
        POINT cursor;
        if (!GetCursorPos(&cursor)) return;
        POINT local = cursor;
        ScreenToClient(mouseWindow, &local);
        const int renderTop = gStandaloneWindow ? 0 : 32;
        const bool inRender = local.x >= 0 && local.y >= renderTop &&
            local.x < client.right && local.y < client.bottom;
        if (keyDown(0x5B) || keyDown(0x5C) || keyDown(0x1B))
        {
            setMouseCapture(false);
            return;
        }
        if (!mouseCaptured)
        {
            if (!inRender || !keyDown(0x01)) return;
            SetCursorPos(center.x, center.y);
            setMouseCapture(true);
            buildHeld = true;
            return;
        }
        camYaw += (cursor.x - center.x) * 0.0026;
        camPitch -= (cursor.y - center.y) * 0.0026;
        if (camPitch < -1.15) camPitch = -1.15;
        if (camPitch > 1.15) camPitch = 1.15;
        SetCursorPos(center.x, center.y);
    }

    private float[16] multiply(const float[16] a, const float[16] b)
    {
        float[16] result;
        result[] = 0;
        foreach (column; 0 .. 4)
            foreach (row; 0 .. 4)
            {
                float sum = 0;
                foreach (k; 0 .. 4)
                    sum += a[k * 4 + row] * b[column * 4 + k];
                result[column * 4 + row] = sum;
            }
        return result;
    }

    private float[16] matrix(double seconds, uint width, uint height,
        bool translate = true)
    {
        const aspect = height != 0
            ? cast(float) width / height
            : cast(float) Width / Height;
        const f = 1.0f / cast(float) tan(3.14159265358979323846 / 6.0);
        const near = 0.1f;
        const far = cast(float) runtime.world.farPlane;
        float[16] projection;
        projection[] = 0;
        projection[0] = f / aspect;
        projection[5] = f;
        projection[10] = far / (near - far);
        projection[11] = -1;
        projection[14] = far * near / (near - far);

        const yaw = camYaw + 0.012 * sin(seconds * 0.4);
        const cy = cos(yaw);
        const sy = sin(yaw);
        const cp = cos(camPitch);
        const sp = sin(camPitch);
        const fx = sy * cp;
        const fy = sp;
        const fz = -cy * cp;
        const rightLength = sqrt(fx * fx + fz * fz);
        const rx = rightLength > 1e-9 ? -fz / rightLength : 1;
        const ry = 0;
        const rz = rightLength > 1e-9 ? fx / rightLength : 0;
        const ux = ry * fz - rz * fy;
        const uy = rz * fx - rx * fz;
        const uz = rx * fy - ry * fx;
        float[16] view;
        view[] = 0;
        view[0] = cast(float) rx;
        view[1] = cast(float) ux;
        view[2] = cast(float) -fx;
        view[4] = cast(float) ry;
        view[5] = cast(float) uy;
        view[6] = cast(float) -fy;
        view[8] = cast(float) rz;
        view[9] = cast(float) uz;
        view[10] = cast(float) -fz;
        view[12] = translate
            ? cast(float) -(rx * camX + ry * camY + rz * camZ) : 0;
        view[13] = translate
            ? cast(float) -(ux * camX + uy * camY + uz * camZ) : 0;
        view[14] = translate
            ? cast(float) (fx * camX + fy * camY + fz * camZ) : 0;
        view[15] = 1;
        const a = far / (near - far);
        const b = far * near / (near - far);
        const sx = f / aspect;
        const rightDot = translate ? rx * camX + ry * camY + rz * camZ : 0;
        const upDot = translate ? ux * camX + uy * camY + uz * camZ : 0;
        const forwardDot = translate ? fx * camX + fy * camY + fz * camZ : 0;
        float[16] result;
        result[] = 0;
        result[0] = cast(float) (sx * rx);
        result[4] = cast(float) (sx * ry);
        result[8] = cast(float) (sx * rz);
        result[12] = cast(float) (-sx * rightDot);
        result[1] = cast(float) (-f * ux);
        result[5] = cast(float) (-f * uy);
        result[9] = cast(float) (-f * uz);
        result[13] = cast(float) (f * upDot);
        result[2] = cast(float) (-a * fx);
        result[6] = cast(float) (-a * fy);
        result[10] = cast(float) (-a * fz);
        result[14] = cast(float) (a * forwardDot + b);
        result[3] = cast(float) fx;
        result[7] = cast(float) fy;
        result[11] = cast(float) fz;
        result[15] = cast(float) -forwardDot;
        return result;
    }

    void render(string output, string surfaceOutput, double seconds)
    {
        VkCommandBufferBeginInfo begin;
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        check(vk.vkBeginCommandBuffer(commands, &begin), "begin command buffer");
        VkClearValue[2] clears;
        clears[0].color.float32 = [0.02f, 0.03f, 0.06f, 1.0f];
        clears[1].depthStencil = VkClearDepthStencilValue(1.0f, 0);
        VkRenderPassBeginInfo pass;
        pass.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        pass.renderPass = renderPass;
        pass.framebuffer = framebuffer;
        pass.renderArea = VkRect2D(VkOffset2D(0, 0),
            VkExtent2D(Width, Height));
        pass.clearValueCount = 2;
        pass.pClearValues = clears.ptr;
        vk.vkCmdBeginRenderPass(commands, &pass, 1);
        drawSky(commands, Width, Height);
        vk.vkCmdBindPipeline(commands, 0, terrainPipeline);
        VkViewport viewport = VkViewport(0, 0, Width, Height, 0, 1);
        VkRect2D scissor = VkRect2D(VkOffset2D(0, 0),
            VkExtent2D(Width, Height));
        vk.vkCmdSetViewport(commands, 0, 1, &viewport);
        vk.vkCmdSetScissor(commands, 0, 1, &scissor);
        updateCamera(seconds, 0);
        auto matrix = this.matrix(seconds, Width, Height);
        pushConstants(commands, terrainPipelineLayout, VK_SHADER_STAGE_VERTEX_BIT,
            0, 64, &matrix);
        drawTerrain(commands);
        updateActorMesh();
        drawWorldProps(commands, Width, Height, matrix);
        vk.vkCmdEndRenderPass(commands);

        VkImageMemoryBarrier barrier;
        barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        barrier.dstAccessMask = 0x800; // TRANSFER_READ
        barrier.oldLayout = 6;
        barrier.newLayout = 6;
        barrier.srcQueueFamilyIndex = 0xffffffff;
        barrier.dstQueueFamilyIndex = 0xffffffff;
        barrier.image = colorImage;
        barrier.subresourceRange = VkImageSubresourceRange(
            VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1);
        vk.vkCmdPipelineBarrier(commands,
            VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &barrier);
        VkBufferImageCopy region;
        region.imageSubresource = VkImageSubresourceLayers(
            VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1);
        region.imageOffset = VkOffset3D(0, 0, 0);
        region.imageExtent = VkExtent3D(Width, Height, 1);
        copyImageToBuffer(commands, colorImage, 6, readBuffer, 1, &region);
        check(vk.vkEndCommandBuffer(commands), "end command buffer");
        VkSubmitInfo submit;
        submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &commands;
        check(vk.vkQueueSubmit(queue, 1, &submit, fence), "submitting 3D commands");
        check(vk.vkWaitForFences(device, 1, &fence, 1, ulong.max),
            "waiting for 3D frame");
        vk.vkResetFences(device, 1, &fence);

        void* pixels;
        check(vk.vkMapMemory(device, readMemory, 0, Width * Height * 4, 0,
            &pixels), "mapping readback");
        auto data = cast(ubyte[]) pixels[0 .. Width * Height * 4];
        if (surfaceOutput.length != 0)
            writeSurface(surfaceOutput, data);
        ubyte[] ppm;
        ppm ~= cast(ubyte[]) ("P6\n" ~ to!string(Width) ~ " " ~
            to!string(Height) ~ "\n255\n");
        foreach (i; 0 .. Width * Height)
        {
            ppm ~= data[i * 4];
            ppm ~= data[i * 4 + 1];
            ppm ~= data[i * 4 + 2];
        }
        vk.vkUnmapMemory(device, readMemory);
        write(output, ppm);
        stdout.writeln("PASS Vulkan 3D frame ", Width, "x", Height,
            " hostPid=", GetCurrentProcessId());
        stdout.flush();
    }

    void renderAnimated(string surfacePath, int seconds)
    {
        if (presenter is null)
            presenter = new SurfacePresenter(surfacePath);
        stdout.writeln("vulkan3d: animated surface ", surfacePath); stdout.flush();
        const frames = seconds * 60;
        void* readPixels;
        check(vk.vkMapMemory(device, readMemory, 0, Width * Height * 4, 0,
            &readPixels), "mapping animated readback");
        auto readData = cast(ubyte[]) readPixels[0 .. Width * Height * 4];

        auto lastTime = MonoTime.currTime;
        double renderMs;
        double publishMs;
        double budgetMs;
        int timingSamples;
        MonoTime previousFrame;
        int over16;
        int over20;
        int warmOver16;
        int warmOver20;
        double maxIntervalMs = 0.0;
        double cadenceSumMs = 0;
        double cadenceMaxMs = 0;
        int cadenceSamples;
        int cadenceOver16;
        int cadenceOver20;
        foreach (frame; 0 .. frames)
        {
            auto frameStart = MonoTime.currTime;
            if (previousFrame != MonoTime.init)
            {
                const intervalMs = (frameStart - previousFrame)
                    .total!"usecs" / 1000.0;
                if (frame < 60)
                {
                    if (intervalMs > 16.667) ++warmOver16;
                    if (intervalMs > 20.0) ++warmOver20;
                }
                else
                {
                    if (intervalMs > 16.667) ++over16;
                    if (intervalMs > 20.0) ++over20;
                }
                if (intervalMs > maxIntervalMs) maxIntervalMs = intervalMs;
                cadenceSumMs += intervalMs;
                if (intervalMs > cadenceMaxMs) cadenceMaxMs = intervalMs;
                ++cadenceSamples;
                if (intervalMs > 16.667) ++cadenceOver16;
                if (intervalMs > 20.0) ++cadenceOver20;
                if (cadenceSamples >= 120)
                {
                    stdout.writeln("producer cadence avgMs=",
                        cadenceSumMs / cadenceSamples, " maxMs=",
                        cadenceMaxMs, " over16=", cadenceOver16,
                        " over20=", cadenceOver20);
                    stdout.flush();
                    cadenceSumMs = 0;
                    cadenceMaxMs = 0;
                    cadenceSamples = 0;
                    cadenceOver16 = 0;
                    cadenceOver20 = 0;
                }
            }
            if (!hudClockStarted)
            {
                hudLastUpdate = frameStart;
                hudClockStarted = true;
            }
            ++hudFrameCount;
            const hudElapsed =
                (frameStart - hudLastUpdate).total!"usecs" / 1000000.0;
            if (hudElapsed >= 0.5)
            {
                hudFps = hudFrameCount / hudElapsed;
                hudFrameCount = 0;
                hudLastUpdate = frameStart;
                hudDirty = true;
            }
            previousFrame = frameStart;
            auto now = MonoTime.currTime;
            auto dt = (now - lastTime).total!"msecs" / 1000.0;
            lastTime = now;
            if (dt <= 0 || dt > 0.1) dt = 1.0 / 60.0;
            vk.vkResetFences(device, 1, &fence);
            vk.vkResetCommandBuffer(commands, 0);
            VkCommandBufferBeginInfo begin;
            begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
            begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
            check(vk.vkBeginCommandBuffer(commands, &begin),
                "begin animated frame");
            VkClearValue[2] clears;
            clears[0].color.float32 = [0.02f, 0.03f, 0.06f, 1.0f];
            clears[1].depthStencil = VkClearDepthStencilValue(1.0f, 0);
            VkRenderPassBeginInfo pass;
            pass.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
            pass.renderPass = renderPass;
            pass.framebuffer = framebuffer;
            pass.renderArea = VkRect2D(VkOffset2D(0, 0),
                VkExtent2D(Width, Height));
            pass.clearValueCount = 2;
            pass.pClearValues = clears.ptr;
            vk.vkCmdBeginRenderPass(commands, &pass, 1);
            drawSky(commands, Width, Height);
            vk.vkCmdBindPipeline(commands, 0, terrainPipeline);
            VkViewport viewport = VkViewport(0, 0, Width, Height, 0, 1);
            VkRect2D scissor = VkRect2D(VkOffset2D(0, 0),
                VkExtent2D(Width, Height));
            vk.vkCmdSetViewport(commands, 0, 1, &viewport);
            vk.vkCmdSetScissor(commands, 0, 1, &scissor);
            if (testMotion)
            {
                const t = frame / 60.0;
                mouseCaptured = false;
                if (extremeMotion)
                {
                    camYaw += dt * 3.8;
                    camX = 55.0 * sin(t * 2.7);
                    camZ = 95.0 + 35.0 * cos(t * 2.1);
                    camPitch = 0.75 * sin(t * 2.3);
                }
                else
                {
                    camYaw += dt * 0.9;
                    camX = 12.0 * sin(t * 0.6);
                    camZ = 40.0 + 8.0 * cos(t * 0.4);
                    camPitch = 0.2 * sin(t * 0.5);
                }
            }
            else
                updateMouse();
            updateCamera(frame / 60.0, dt);
            hudRefreshAccumulator += dt;
            if (hudRefreshAccumulator >= 0.1)
            {
                hudRefreshAccumulator = 0;
                hudDirty = true;
            }
            updateHudToggle();
            if (hudDirty)
            {
                updateHud(Width, Height);
                hudDirty = false;
            }

            auto matrix = this.matrix(frame / 60.0, Width, Height);
            pushConstants(commands, terrainPipelineLayout, VK_SHADER_STAGE_VERTEX_BIT,
                0, 64, &matrix);
            drawTerrain(commands);
            updateActorMesh();
            drawWorldProps(commands, Width, Height, matrix);
            drawHud(commands, Width, Height);
            vk.vkCmdEndRenderPass(commands);

            VkImageMemoryBarrier barrier;
            barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
            barrier.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
            barrier.dstAccessMask = 0x800;
            barrier.oldLayout = 6;
            barrier.newLayout = 6;
            barrier.srcQueueFamilyIndex = 0xffffffff;
            barrier.dstQueueFamilyIndex = 0xffffffff;
            barrier.image = colorImage;
            barrier.subresourceRange = VkImageSubresourceRange(
                VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1);
            vk.vkCmdPipelineBarrier(commands,
                VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1,
                &barrier);
            VkBufferImageCopy region;
            region.imageSubresource = VkImageSubresourceLayers(
                VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1);
            region.imageOffset = VkOffset3D(0, 0, 0);
            region.imageExtent = VkExtent3D(Width, Height, 1);
            copyImageToBuffer(commands, colorImage, 6, readBuffer, 1,
                &region);
            check(vk.vkEndCommandBuffer(commands), "end animated frame");
            VkSubmitInfo submit;
            submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
            submit.commandBufferCount = 1;
            submit.pCommandBuffers = &commands;
            check(vk.vkQueueSubmit(queue, 1, &submit, fence),
                "submitting animated frame");
            check(vk.vkWaitForFences(device, 1, &fence, 1, ulong.max),
                "waiting for animated frame");
            const renderDone = MonoTime.currTime;
            presenter.submit(readData, mouseCaptured);
            const publishDone = MonoTime.currTime;
            runtime.clock.waitUntil(frameStart);
            const frameDone = MonoTime.currTime;
            renderMs += (renderDone - frameStart).total!"usecs" / 1000.0;
            publishMs += (publishDone - renderDone).total!"usecs" / 1000.0;
            budgetMs += (frameDone - publishDone).total!"usecs" / 1000.0;
            ++timingSamples;
        }
        vk.vkUnmapMemory(device, readMemory);

        presenter.stop();
        stdout.writeln("terrain cadence over16=", over16, " over20=", over20,
            " warmOver16=", warmOver16, " warmOver20=", warmOver20,
            " maxMs=", maxIntervalMs, " frames=", frames);
        stdout.writeln("PASS Vulkan animated surface frames=", frames);
        stdout.flush();
    }

    private void pumpMessages()
    {
        MSG message;
        while (PeekMessageA(&message, null, 0, 0, 1))
        {
            TranslateMessage(&message);
            DispatchMessageA(&message);
        }
    }

    private VkExtent2D targetExtent()
    {
        VkExtent2D target;
        target.width = extent.width != 0 && extent.width < Width
            ? extent.width : Width;
        target.height = extent.height != 0 && extent.height < Height
            ? extent.height : Height;
        return target;
    }

    private void presentFrame(double seconds)
    {
        const target = targetExtent();
        updateHudToggle();
        const now = MonoTime.currTime;
        if (!hudClockStarted)
        {
            hudLastUpdate = now;
            hudClockStarted = true;
        }
        ++hudFrameCount;
        const double hudElapsed =
            (now - hudLastUpdate).total!"usecs" / 1000000.0;
        if (hudElapsed >= 0.5)
        {
            hudFps = hudFrameCount / hudElapsed;
            hudFrameCount = 0;
            hudLastUpdate = now;
            hudDirty = true;
            if (hudTrace)
            {
                stdout.writeln("hud fps=", hudFps);
                stdout.flush();
            }
        }
        if (hudWidth != target.width || hudHeight != target.height)
        {
            hudWidth = target.width;
            hudHeight = target.height;
            hudDirty = true;
        }
        if (hudDirty)
        {
            updateHud(target.width, target.height);
            hudDirty = false;
        }
        uint imageIndex;
        auto acquired = vk.vkAcquireNextImageKHR(device, swapchain, ulong.max,
            acquireSemaphore, VK_NULL_HANDLE, &imageIndex);
        if (acquired == VK_ERROR_OUT_OF_DATE_KHR)
        {
            recreateSwapchain();
            return;
        }
        if (acquired != VK_SUCCESS && acquired != VK_SUBOPTIMAL_KHR)
            check(acquired, "acquiring a child swapchain image");
        vk.vkResetFences(device, 1, &fence);
        vk.vkResetCommandBuffer(commands, 0);
        VkCommandBufferBeginInfo begin;
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        check(vk.vkBeginCommandBuffer(commands, &begin), "begin child frame");
        VkClearValue[2] clears;
        clears[0].color.float32 = [0.02f, 0.03f, 0.06f, 1.0f];
        clears[1].depthStencil = VkClearDepthStencilValue(1.0f, 0);
        VkRenderPassBeginInfo pass;
        pass.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        pass.renderPass = renderPass;
        pass.framebuffer = framebuffer;
        pass.renderArea = VkRect2D(VkOffset2D(0, 0),
            VkExtent2D(target.width, target.height));
        pass.clearValueCount = 2;
        pass.pClearValues = clears.ptr;
        vk.vkCmdBeginRenderPass(commands, &pass, 1);
        drawSky(commands, Width, Height);
        vk.vkCmdBindPipeline(commands, 0, terrainPipeline);
        VkViewport viewport = VkViewport(0, 0, target.width, target.height, 0, 1);
        VkRect2D scissor = VkRect2D(VkOffset2D(0, 0),
            VkExtent2D(target.width, target.height));
        vk.vkCmdSetViewport(commands, 0, 1, &viewport);
        vk.vkCmdSetScissor(commands, 0, 1, &scissor);
        updateMouse();
        updateCamera(seconds, 1.0 / 60.0);
        auto matrix = this.matrix(seconds, target.width, target.height);
        pushConstants(commands, terrainPipelineLayout, VK_SHADER_STAGE_VERTEX_BIT,
            0, 64, &matrix);
        drawTerrain(commands);
        updateActorMesh();
        drawWorldProps(commands, target.width, target.height, matrix);
        if (hudVisible && hudIndexCount != 0)
        {
            VkViewport hudViewport = VkViewport(0, 0, target.width,
                target.height, 0, 1);
            VkRect2D hudScissor = VkRect2D(VkOffset2D(0, 0),
                VkExtent2D(target.width, target.height));
            vk.vkCmdSetViewport(commands, 0, 1, &hudViewport);
            vk.vkCmdSetScissor(commands, 0, 1, &hudScissor);
            vk.vkCmdBindPipeline(commands, 0, hudPipeline);
            VkDeviceSize hudOffset = 0;
            vk.vkCmdBindVertexBuffers(commands, 0, 1, &hudVertexBuffer,
                &hudOffset);
            vk.vkCmdBindIndexBuffer(commands, hudIndexBuffer, 0,
                VK_INDEX_TYPE_UINT32);
            auto hudMvp = hudMatrix(target.width, target.height);
            pushConstants(commands, pipelineLayout, VK_SHADER_STAGE_VERTEX_BIT,
                0, 64, &hudMvp);
            vk.vkCmdDrawIndexed(commands, hudIndexCount, 1, 0, 0, 0);
        }
        vk.vkCmdEndRenderPass(commands);

        VkImageMemoryBarrier colorBarrier;
        colorBarrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        colorBarrier.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        colorBarrier.dstAccessMask = 0x800;
        colorBarrier.oldLayout = 6;
        colorBarrier.newLayout = 6;
        colorBarrier.srcQueueFamilyIndex = 0xffffffff;
        colorBarrier.dstQueueFamilyIndex = 0xffffffff;
        colorBarrier.image = colorImage;
        colorBarrier.subresourceRange = VkImageSubresourceRange(
            VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1);
        vk.vkCmdPipelineBarrier(commands,
            VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1,
            &colorBarrier);
        VkImageMemoryBarrier swapBarrier;
        swapBarrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        swapBarrier.srcAccessMask = 0;
        swapBarrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        swapBarrier.oldLayout = 0;
        swapBarrier.newLayout = 7;
        swapBarrier.srcQueueFamilyIndex = 0xffffffff;
        swapBarrier.dstQueueFamilyIndex = 0xffffffff;
        swapBarrier.image = swapImages[imageIndex];
        swapBarrier.subresourceRange = VkImageSubresourceRange(
            VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1);
        vk.vkCmdPipelineBarrier(commands, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1,
            &swapBarrier);
        ImageCopy region;
        region.srcSubresource = VkImageSubresourceLayers(
            VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1);
        region.dstSubresource = region.srcSubresource;
        region.srcOffset = VkOffset3D(0, 0, 0);
        region.dstOffset = VkOffset3D(0, 0, 0);
        region.extent = VkExtent3D(target.width, target.height, 1);
        copyImage(commands, colorImage, 6, swapImages[imageIndex], 7, 1,
            &region);
        swapBarrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        swapBarrier.dstAccessMask = 0;
        swapBarrier.oldLayout = 7;
        swapBarrier.newLayout = 1000001002; // PRESENT_SRC_KHR
        vk.vkCmdPipelineBarrier(commands, VK_PIPELINE_STAGE_TRANSFER_BIT,
            0x2000, 0, 0, null, 0, null, 1, &swapBarrier);
        check(vk.vkEndCommandBuffer(commands), "end child frame");
        uint waitStage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        VkSubmitInfo submit;
        submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.waitSemaphoreCount = 1;
        submit.pWaitSemaphores = &acquireSemaphore;
        submit.pWaitDstStageMask = &waitStage;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &commands;
        submit.signalSemaphoreCount = 1;
        submit.pSignalSemaphores = &presentSemaphore;
        check(vk.vkQueueSubmit(queue, 1, &submit, fence), "submitting child frame");
        VkPresentInfoKHR present;
        present.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
        present.waitSemaphoreCount = 1;
        present.pWaitSemaphores = &presentSemaphore;
        present.swapchainCount = 1;
        present.pSwapchains = &swapchain;
        present.pImageIndices = &imageIndex;
        const presented = vk.vkQueuePresentKHR(queue, &present);
        if (presented == VK_ERROR_OUT_OF_DATE_KHR)
        {
            stdout.writeln("vulkan3d: swapchain out of date; recreating");
            stdout.flush();
            recreateSwapchain();
            return;
        }
        check(presented, "presenting child frame");
        check(vk.vkWaitForFences(device, 1, &fence, 1, ulong.max),
            "waiting for child frame");
        pumpMessages();
    }

    void present(int seconds)
    {
        const frames = seconds * 60;
        stdout.writeln("vulkan3d: present start"); stdout.flush();
        foreach (frame; 0 .. frames)
        {
            if (frame == 0) { stdout.writeln("vulkan3d: frame 1"); stdout.flush(); }
            const frameStart = MonoTime.currTime;
            presentFrame(frame / 60.0);
            runtime.clock.waitUntil(frameStart);
        }
        vk.vkDeviceWaitIdle(device);
        stdout.writeln("PASS Vulkan 3D child swapchain hostPid=",
            GetCurrentProcessId(), " frames=", frames);
        stdout.flush();
    }

    void presentStandalone()
    {
        scope(exit) setMouseCapture(false);
        stdout.writeln("vulkan3d: standalone window start"); stdout.flush();
        ulong frame;
        while (!gWindowClosed && IsWindow(gChildWindow))
        {
            if (IsIconic(gChildWindow))
            {
                Thread.sleep(16.msecs);
                continue;
            }
            const frameStart = MonoTime.currTime;
            presentFrame(frame / 60.0);
            if ((frame % 30) == 0)
            {
                stdout.writeln("terrain camera x=", camX, " y=", camY,
                    " z=", camZ, " yaw=", camYaw);
                stdout.flush();
            }
            ++frame;
            runtime.clock.waitUntil(frameStart);
        }
        vk.vkDeviceWaitIdle(device);
        stdout.writeln("PASS Vulkan 3D standalone window frames=", frame);
        stdout.flush();
    }
}

private void put(T)(ubyte[] data, size_t offset, T value)
{
    memcpy(data.ptr + offset, &value, T.sizeof);
}

private void writeSurface(string path, const(ubyte)[] pixels)
{
    const frameBytes = Width * Height * 4;
    const size = SurfaceHeader + EventCapacity * EventBytes + 2 * frameBytes;
    auto data = new ubyte[size];
    foreach (i, ch; "AURSFACE")
        data[i] = cast(ubyte) ch;
    put!uint(data, 8, 2);
    put!uint(data, 12, SurfaceHeader);
    put!uint(data, 16, Width);
    put!uint(data, 20, Height);
    put!uint(data, 24, 0);
    put!uint(data, 28, EventCapacity);
    put!ulong(data, 32, 1);
    put!ulong(data, 40, 0);
    put!uint(data, 48, 0);
    put!uint(data, 52, 0);
    put!uint(data, 56, EventBytes);
    put!uint(data, 60, 2);
    put!uint(data, 64, frameBytes);
    memcpy(data.ptr + SurfaceHeader + EventCapacity * EventBytes,
        pixels.ptr, frameBytes);
    write(path, data);
}

private extern(Windows) nothrow LRESULT childWindowProc(HWND window,
    UINT message, WPARAM wParam, LPARAM lParam)
{
    return DefWindowProcA(window, message, wParam, lParam);
}

private extern(Windows) nothrow LRESULT standaloneWindowProc(HWND window,
    UINT message, WPARAM wParam, LPARAM lParam)
{
    switch (message)
    {
        case WM_CLOSE:
        case WM_DESTROY:
            gWindowClosed = true;
            return 0;
        default:
            return DefWindowProcA(window, message, wParam, lParam);
    }
}

void main(string[] args)
{
    version (Windows)
    {
        if (SetProcessDpiAwarenessContext(cast(void*) cast(intptr_t) -4) == 0)
            SetProcessDPIAware();
        SetThreadDpiAwarenessContext(cast(void*) cast(intptr_t) -4);
    }
    string shaderDir;
    string output = "vulkan3d.ppm";
    string surfaceOutput;
    string hostTitle;
    double seconds = 0.7;
    bool animate;
    bool offscreen;
    bool testMotion;
    bool extremeMotion;
    bool hudTrace;
    for (size_t i = 0; i < args.length; ++i)
    {
        if (args[i] == "--shaders" && i + 1 < args.length)
            shaderDir = args[++i];
        else if (args[i] == "--out" && i + 1 < args.length)
            output = args[++i];
        else if (args[i] == "--surface" && i + 1 < args.length)
            surfaceOutput = args[++i];
        else if (args[i] == "--host-title" && i + 1 < args.length)
            hostTitle = args[++i];
        else if (args[i] == "--time" && i + 1 < args.length)
            seconds = to!double(args[++i]);
        else if (args[i] == "--animate")
            animate = true;
        else if (args[i] == "--render")
            offscreen = true;
        else if (args[i] == "--test-motion")
            testMotion = true;
        else if (args[i] == "--extreme-motion")
            extremeMotion = true;
        else if (args[i] == "--trace-hud")
            hudTrace = true;
    }
    if (shaderDir.length != 0)
    {
        if (!exists(buildPath(shaderDir, "cube.vert.spv")))
            throw new Exception("missing cube.vert.spv in " ~ shaderDir);
        version (Windows)
        {
            import core.sys.windows.windows : SetCurrentDirectoryA;
            SetCurrentDirectoryA(toStringz(shaderDir));
        }
    }
    gShaderDir = shaderDir;
    if (hostTitle.length != 0)
    {
        auto parent = FindWindowA(null, toStringz(hostTitle));
        if (parent is null)
            throw new Exception("cannot find host window: " ~ hostTitle);
        HINSTANCE instanceHandle = GetModuleHandleA(null);
        WNDCLASSA windowClass;
        windowClass.lpfnWndProc = &childWindowProc;
        windowClass.hInstance = instanceHandle;
        windowClass.lpszClassName = toStringz("AuroraVk3D");
        RegisterClassA(&windowClass);
        gChildWindow = CreateWindowExA(0, toStringz("AuroraVk3D"), "",
            WS_CHILD | WS_VISIBLE, 0, 32, Width, Height, parent, null,
            instanceHandle, null);
        if (gChildWindow is null)
            throw new Exception("cannot create the in-host Vulkan child window");
        stdout.writeln("vulkan3d: child ", cast(ulong) gChildWindow);
        stdout.flush();
        ShowWindow(gChildWindow, SW_SHOW);
        RECT childClient;
        GetClientRect(gChildWindow, &childClient);
        if (childClient.right > 0 && childClient.bottom > 0)
        {
            const scaleX = cast(double) Width / childClient.right;
            const scaleY = cast(double) Height / childClient.bottom;
            SetWindowPos(gChildWindow, null, 0, cast(int) (32 * scaleY),
                cast(int) (Width * scaleX), cast(int) (Height * scaleY),
                0x0004 | 0x0040);
        }
    }
    else if (!animate && surfaceOutput.length == 0 && !offscreen &&
        output == "vulkan3d.ppm")
    {
        HINSTANCE instanceHandle = GetModuleHandleA(null);
        WNDCLASSA windowClass;
        windowClass.lpfnWndProc = &standaloneWindowProc;
        windowClass.hInstance = instanceHandle;
        windowClass.hCursor = LoadCursorA(null, cast(const(char)*) 32512);
        windowClass.lpszClassName = toStringz("AuroraVk3DStandalone");
        RegisterClassA(&windowClass);
        gStandaloneWindow = true;
        gChildWindow = CreateWindowExA(0, toStringz("AuroraVk3DStandalone"),
            toStringz("Large Marching Cubes Terrain"),
            WS_OVERLAPPEDWINDOW | WS_VISIBLE, 80, 80, 1280, 720,
            null, null, instanceHandle, null);
        if (gChildWindow is null)
            throw new Exception("cannot create the standalone window");
        ShowWindow(gChildWindow, SW_SHOW);
        SetForegroundWindow(gChildWindow);
    }
    auto app = new App(animate && surfaceOutput.length != 0
        ? surfaceOutput : null);
    if (gStandaloneWindow)
        app.mouseWindow = gChildWindow;
    timeBeginPeriod(1);
    scope(exit) timeEndPeriod(1);
    SetPriorityClass(GetCurrentProcess(), 0x80);
    SetThreadPriority(GetCurrentThread(), 2);
    app.testMotion = testMotion;
    app.extremeMotion = extremeMotion;
    app.hudTrace = hudTrace;
    app.mouseTitle = "Large Marching Cubes Terrain";
    if (hostTitle.length != 0)
        app.present(cast(int) seconds);
    else if (animate && surfaceOutput.length != 0)
        app.renderAnimated(surfaceOutput, cast(int) seconds);
    else if (offscreen || output != "vulkan3d.ppm" ||
        surfaceOutput.length != 0)
        app.render(output, surfaceOutput, seconds);
    else
        app.presentStandalone();
}
