module aurora.render.vulkan;

import aurora.platform.base : NativeSurfaceInfo, NativeSurfaceKind, WindowOptions;
import aurora.image : RgbaImage;
import aurora.render.base : RenderBackend, RendererStats;
import aurora.render.drawlist : DrawBatchKind, DrawList, DrawVertex;
import aurora.render.scene : RenderScene;
import aurora.surface : Surface;
import aurora.types : Rect, Size, maxInt, minInt;
import aurora.vulkan.api;
import aurora.vulkan.shaders : fragmentShaderSpirv, imageFragmentShaderSpirv,
    vertexShaderSpirv;
import core.stdc.config : c_ulong;
import core.stdc.string : memcpy;
import std.algorithm : max, min;
import std.conv : to;
import std.string : fromStringz, toStringz;

private struct HostBuffer
{
    VkBuffer buffer;
    VkDeviceMemory memory;
    void* mapped;
    VkDeviceSize capacity;
}

private final class GpuLayerGeometry
{
    HostBuffer vertexBuffer;
    HostBuffer indexBuffer;
    ulong revision;
    Size viewport;
    int atlasWidth;
    int atlasHeight;
    uint indexCount;
    ulong lastSeenScene;
}

private final class GpuImageTexture
{
    HostBuffer staging;
    VkImage image;
    VkDeviceMemory memory;
    VkImageView view;
    VkDescriptorSet linearDescriptorSet;
    VkDescriptorSet nearestDescriptorSet;
    ulong revision;
    ulong submittedRevision;
    int width;
    int height;
    bool initialized;
}

private struct FrameResources
{
    VkCommandBuffer commandBuffer;
    VkSemaphore imageAvailable;
    VkFence fence;
}

private struct GpuVertex
{
    float x;
    float y;
    float u;
    float v;
    float r;
    float g;
    float b;
    float a;
}

enum uint imageDescriptorSetLimit = 1024;
private enum ulong resizedSwapchainAcquireTimeoutNs = 16_000_000UL;

private bool supportsPresentMode(const(int)[] modes, int expected)
    @safe pure nothrow @nogc
{
    foreach (mode; modes)
        if (mode == expected) return true;
    return false;
}

/** Choose enough images for the selected presentation model without building a stale FIFO. */
private uint chooseSwapchainImageCount(uint minimum, uint maximum,
    int presentMode, bool lowLatency) @safe pure nothrow @nogc
{
    uint result;
    // MAILBOX needs a displayed image, a pending image, and an image the
    // application can acquire to replace the pending entry. With only two
    // images, replacement can be starved until the next vertical blank.
    if (presentMode == VK_PRESENT_MODE_MAILBOX_KHR)
        result = minimum < 3 ? 3 : minimum;
    else
        result = lowLatency ? minimum : minimum + 1;
    if (maximum > 0 && result > maximum) result = maximum;
    if (result < minimum) result = minimum;
    return result;
}

/** Choose the lowest-latency mode compatible with the requested tear policy. */
private int choosePresentMode(const(int)[] modes, bool vsync, bool lowLatency)
    @safe pure nothrow @nogc
{
    const fallback = modes.length == 0 ? VK_PRESENT_MODE_FIFO_KHR : modes[0];
    if (vsync)
    {
        // MAILBOX remains synchronized but replaces queued frames with the
        // newest one. It avoids the extra FIFO queueing that is noticeable
        // while dragging; FIFO remains the universally supported fallback.
        if (lowLatency && supportsPresentMode(modes, VK_PRESENT_MODE_MAILBOX_KHR))
            return VK_PRESENT_MODE_MAILBOX_KHR;
        if (lowLatency && supportsPresentMode(modes, VK_PRESENT_MODE_FIFO_RELAXED_KHR))
            return VK_PRESENT_MODE_FIFO_RELAXED_KHR;
        if (supportsPresentMode(modes, VK_PRESENT_MODE_FIFO_KHR))
            return VK_PRESENT_MODE_FIFO_KHR;
        return fallback;
    }

    // Vsync off explicitly permits tearing, so IMMEDIATE is the intended
    // lowest-latency mode. MAILBOX is the best non-tearing fallback.
    if (supportsPresentMode(modes, VK_PRESENT_MODE_IMMEDIATE_KHR))
        return VK_PRESENT_MODE_IMMEDIATE_KHR;
    if (supportsPresentMode(modes, VK_PRESENT_MODE_MAILBOX_KHR))
        return VK_PRESENT_MODE_MAILBOX_KHR;
    if (supportsPresentMode(modes, VK_PRESENT_MODE_FIFO_KHR))
        return VK_PRESENT_MODE_FIFO_KHR;
    return fallback;
}

unittest
{
    int[] allModes = [VK_PRESENT_MODE_FIFO_KHR, VK_PRESENT_MODE_FIFO_RELAXED_KHR,
        VK_PRESENT_MODE_IMMEDIATE_KHR, VK_PRESENT_MODE_MAILBOX_KHR];
    assert(choosePresentMode(allModes, true, true) == VK_PRESENT_MODE_MAILBOX_KHR);
    assert(choosePresentMode(allModes, true, false) == VK_PRESENT_MODE_FIFO_KHR);
    assert(choosePresentMode(allModes, false, true) == VK_PRESENT_MODE_IMMEDIATE_KHR);
    int[] fifoOnly = [VK_PRESENT_MODE_FIFO_KHR];
    assert(choosePresentMode(fifoOnly, true, true) == VK_PRESENT_MODE_FIFO_KHR);
    assert(choosePresentMode(fifoOnly, false, true) == VK_PRESENT_MODE_FIFO_KHR);
    assert(chooseSwapchainImageCount(2, 0, VK_PRESENT_MODE_MAILBOX_KHR, true) == 3);
    assert(chooseSwapchainImageCount(2, 2, VK_PRESENT_MODE_MAILBOX_KHR, true) == 2);
    assert(chooseSwapchainImageCount(2, 0, VK_PRESENT_MODE_FIFO_KHR, true) == 2);
    assert(chooseSwapchainImageCount(2, 0, VK_PRESENT_MODE_FIFO_KHR, false) == 3);
}

/** Vulkan 1.0 renderer for Aurora's ordered 2D draw list. */
final class VulkanRenderer : RenderBackend
{
    private VulkanApi _vk;
    private WindowOptions _options;
    private NativeSurfaceInfo _native;
    private Size _requestedSize;
    private VkInstance _instance;
    private VkSurfaceKHR _surface;
    private VkPhysicalDevice _physicalDevice;
    private VkDevice _device;
    private uint _graphicsFamily = uint.max;
    private uint _presentFamily = uint.max;
    private VkQueue _graphicsQueue;
    private VkQueue _presentQueue;
    private VkPhysicalDeviceMemoryProperties _memoryProperties;

    private VkSwapchainKHR _swapchain;
    private VkImage[] _swapchainImages;
    private VkImageView[] _swapchainViews;
    private VkFramebuffer[] _framebuffers;
    private VkExtent2D _extent;
    private int _swapchainFormat;
    private bool _swapchainDirty;

    private VkRenderPass _renderPass;
    private VkDescriptorSetLayout _descriptorSetLayout;
    private VkPipelineLayout _pipelineLayout;
    private VkPipeline _pipeline;
    private VkPipeline _imagePipeline;
    private VkDescriptorPool _descriptorPool;
    private VkDescriptorSet _descriptorSet;

    private VkCommandPool _commandPool;
    private FrameResources[] _frames;
    private VkSemaphore[] _presentSemaphores;
    private uint _frameCursor;
    private int _presentMode = VK_PRESENT_MODE_FIFO_KHR;

    private GpuLayerGeometry[ulong] _geometryCaches;
    private ulong _sceneGeneration;
    private ulong _immediateRevision;
    private RendererStats _stats;
    private HostBuffer _atlasStaging;
    private VkImage _atlasImage;
    private VkDeviceMemory _atlasMemory;
    private VkImageView _atlasView;
    private VkSampler _atlasSampler;
    private VkSampler _imageLinearSampler;
    private VkSampler _imageNearestSampler;
    private int _atlasWidth;
    private int _atlasHeight;
    private ulong _atlasRevision;
    private ulong _submittedAtlasRevision;
    private VkImage _submittedAtlasImage;
    private bool _atlasInitialized;
    private GpuImageTexture[ulong] _imageTextures;
    private bool _closed;
    private bool _usingXcb;

    this(WindowOptions options, NativeSurfaceInfo nativeInfo, Size initialSize)
    {
        _options = options;
        _native = nativeInfo;
        _requestedSize = initialSize;
        try
        {
            _vk = new VulkanApi();
            createInstance();
            _vk.loadInstance(_instance);
            createSurface();
            choosePhysicalDevice();
            createDevice();
            _vk.loadDevice(_device);
            _vk.vkGetDeviceQueue(_device, _graphicsFamily, 0, &_graphicsQueue);
            _vk.vkGetDeviceQueue(_device, _presentFamily, 0, &_presentQueue);
            _vk.vkGetPhysicalDeviceMemoryProperties(_physicalDevice, &_memoryProperties);
            createDescriptorResources();
            createCommandResources();
            createSyncResources();
            createSwapchain();
        }
        catch (Exception error)
        {
            shutdown();
            throw error;
        }
    }

    override string name() const { return "Vulkan"; }
    override bool hardwareAccelerated() const { return true; }
    override Surface softwareSurface() { return null; }
    override RendererStats stats() const { return _stats; }
    override void resetStats() { _stats = RendererStats.init; }

    override void resize(Size size)
    {
        const requested = Size(maxInt(1, size.width), maxInt(1, size.height));
        if (_requestedSize == requested) return;
        _requestedSize = requested;
        _swapchainDirty = true;
    }

    override bool render(DrawList list)
    {
        if (list is null) return true;
        auto scene = new RenderScene();
        scene.reset(list, ++_immediateRevision, list.viewport);
        return renderScene(scene);
    }

    override bool renderScene(RenderScene scene)
    {
        if (_closed || scene is null || scene.base is null) return true;
        if (_requestedSize.width <= 0 || _requestedSize.height <= 0) return true;
        bool recreatedSwapchain;
        if (_swapchainDirty || _swapchain == VK_NULL_HANDLE)
        {
            recreateSwapchain();
            recreatedSwapchain = true;
        }
        if (_swapchain == VK_NULL_HANDLE || _extent.width == 0 || _extent.height == 0)
            return true;

        // Content changes may rewrite or destroy retained buffers and atlas
        // resources. Wait until every in-flight draw has completed before that
        // rare mutation. Transform-only interaction never takes this path and
        // may use either frame context immediately.
        const requiresMutation = sceneRequiresGpuMutation(scene);
        uint frameIndex;
        auto frame = availableFrame(requiresMutation, frameIndex);
        if (frame is null)
        {
            ++_stats.frameDeferrals;
            return false;
        }

        uint imageIndex;
        VkResult acquire;
        foreach (attempt; 0 .. 2)
        {
            const timeout = recreatedSwapchain ? resizedSwapchainAcquireTimeoutNs : 0UL;
            acquire = _vk.vkAcquireNextImageKHR(_device, _swapchain, timeout,
                frame.imageAvailable, VK_NULL_HANDLE, &imageIndex);
            if (acquire == VK_ERROR_OUT_OF_DATE_KHR && attempt == 0)
            {
                recreateSwapchain();
                recreatedSwapchain = true;
                continue;
            }
            break;
        }
        if (acquire == VK_NOT_READY || acquire == VK_TIMEOUT)
        {
            ++_stats.frameDeferrals;
            return false;
        }
        if (acquire == VK_ERROR_OUT_OF_DATE_KHR)
        {
            ++_stats.frameDeferrals;
            return false;
        }
        if (acquire != VK_SUCCESS && acquire != VK_SUBOPTIMAL_KHR)
            check(acquire, "acquiring a swapchain image");
        if (acquire == VK_SUBOPTIMAL_KHR) _swapchainDirty = true;
        if (imageIndex >= _presentSemaphores.length)
            throw new Exception("Vulkan returned an invalid swapchain image index");

        // Acquire first, then sample the captured native pointer at the last
        // practical moment before command recording. This removes event-queue
        // age from drag transforms without rebuilding any Aurora content.
        scene.lateLatch();
        ensureAtlas(scene.base);
        ensureSceneImages(scene);
        ++_sceneGeneration;
        if (_sceneGeneration == 0) ++_sceneGeneration;
        auto baseGeometry = ensureGeometryBuffers(scene.base, 0, scene.baseRevision);
        baseGeometry.lastSeenScene = _sceneGeneration;
        foreach (layer; scene.layers)
        {
            auto existing = layer.id in _geometryCaches;
            if (existing !is null)
                (*existing).lastSeenScene = _sceneGeneration;
            if (layer.visible && layer.drawList !is null)
            {
                auto geometry = ensureGeometryBuffers(layer.drawList, layer.id,
                    layer.revision);
                geometry.lastSeenScene = _sceneGeneration;
            }
        }
        retireUnusedGeometry();

        check(_vk.vkResetFences(_device, 1, &frame.fence),
            "resetting a Vulkan frame fence");
        check(_vk.vkResetCommandBuffer(frame.commandBuffer, 0),
            "resetting a Vulkan command buffer");
        recordCommandBuffer(scene, imageIndex, frame.commandBuffer);

        VkFlags waitStage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        VkSubmitInfo submit;
        submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.waitSemaphoreCount = 1;
        submit.pWaitSemaphores = &frame.imageAvailable;
        submit.pWaitDstStageMask = &waitStage;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &frame.commandBuffer;
        submit.signalSemaphoreCount = 1;
        submit.pSignalSemaphores = &_presentSemaphores[imageIndex];
        check(_vk.vkQueueSubmit(_graphicsQueue, 1, &submit, frame.fence),
            "submitting the Vulkan frame");

        VkPresentInfoKHR present;
        present.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
        present.waitSemaphoreCount = 1;
        present.pWaitSemaphores = &_presentSemaphores[imageIndex];
        present.swapchainCount = 1;
        present.pSwapchains = &_swapchain;
        present.pImageIndices = &imageIndex;
        const presented = _vk.vkQueuePresentKHR(_presentQueue, &present);
        if (presented == VK_ERROR_OUT_OF_DATE_KHR || presented == VK_SUBOPTIMAL_KHR)
            _swapchainDirty = true;
        else
            check(presented, "presenting the Vulkan frame");
        _frameCursor = (frameIndex + 1) % activeFrameCount();
        ++_stats.frames;
        return true;
    }

    private uint activeFrameCount() const @safe pure nothrow @nogc
    {
        if (_frames.length == 0) return 0;
        // MAILBOX and IMMEDIATE benefit from CPU/GPU overlap without retaining
        // stale visible frames. Ordered FIFO modes deliberately use one submit
        // context so Aurora does not deepen their presentation queue.
        if (_presentMode == VK_PRESENT_MODE_MAILBOX_KHR ||
            _presentMode == VK_PRESENT_MODE_IMMEDIATE_KHR)
            return cast(uint) _frames.length;
        return 1;
    }

    private FrameResources* availableFrame(bool requireAllIdle, out uint selected)
    {
        selected = 0;
        if (_frames.length == 0) return null;
        if (requireAllIdle)
        {
            foreach (ref frame; _frames)
            {
                if (frame.fence == VK_NULL_HANDLE) continue;
                check(_vk.vkWaitForFences(_device, 1, &frame.fence, VK_TRUE,
                    ulong.max), "waiting for Vulkan content-mutation fences");
            }
        }

        const count = activeFrameCount();
        foreach (offset; 0 .. count)
        {
            const index = (_frameCursor + offset) % count;
            const status = _vk.vkGetFenceStatus(_device, _frames[index].fence);
            if (status == VK_SUCCESS)
            {
                selected = index;
                return &_frames[index];
            }
            if (status != VK_NOT_READY)
                check(status, "checking a Vulkan frame fence");
        }
        return null;
    }

    private bool geometryNeedsUpload(DrawList list, ulong id, ulong revision) const
    {
        if (list is null) return false;
        auto found = id in _geometryCaches;
        if (found is null || *found is null) return true;
        const cache = *found;
        return cache.revision != revision || cache.viewport != list.viewport ||
            cache.atlasWidth != maxInt(1, list.fonts.atlas.width()) ||
            cache.atlasHeight != maxInt(1, list.fonts.atlas.height());
    }

    private bool sceneRequiresGpuMutation(RenderScene scene)
    {
        const atlas = scene.base.fonts.atlas;
        if (_atlasImage == VK_NULL_HANDLE || _atlasWidth != atlas.width() ||
            _atlasHeight != atlas.height() || _atlasRevision != atlas.revision() ||
            _submittedAtlasRevision != atlas.revision())
            return true;
        if (drawListRequiresImageMutation(scene.base)) return true;
        if (geometryNeedsUpload(scene.base, 0, scene.baseRevision)) return true;
        foreach (layer; scene.layers)
            if (layer.visible && layer.drawList !is null &&
                (drawListRequiresImageMutation(layer.drawList) ||
                geometryNeedsUpload(layer.drawList, layer.id, layer.revision)))
                return true;

        // Removing a retained layer destroys its buffers, so it is also a GPU
        // mutation rather than a transform-only frame.
        foreach (id, cache; _geometryCaches)
        {
            if (id == 0) continue;
            bool live;
            foreach (layer; scene.layers)
            {
                if (layer.id == id)
                {
                    live = true;
                    break;
                }
            }
            if (!live) return true;
        }
        return false;
    }

    private bool drawListRequiresImageMutation(DrawList list)
    {
        if (list is null) return false;
        foreach (command; list.rgbaImages)
        {
            auto image = command.image;
            if (image is null) continue;
            auto found = image.id() in _imageTextures;
            if (found is null || *found is null) return true;
            auto texture = *found;
            if (texture.image == VK_NULL_HANDLE ||
                texture.width != image.width() || texture.height != image.height() ||
                texture.revision != image.revision() ||
                texture.submittedRevision != image.revision())
                return true;
        }
        return false;
    }

    override void shutdown()
    {
        if (_closed) return;
        _closed = true;
        if (_device !is null && _vk !is null && _vk.vkDeviceWaitIdle !is null)
            _vk.vkDeviceWaitIdle(_device);

        destroySwapchain();
        destroyGeometryCaches();
        destroyImageTextures();
        destroyHostBuffer(_atlasStaging);
        destroyAtlasImage();

        if (_device !is null && _vk !is null)
        {
            if (_imageNearestSampler != VK_NULL_HANDLE && _vk.vkDestroySampler !is null)
                _vk.vkDestroySampler(_device, _imageNearestSampler, null);
            if (_imageLinearSampler != VK_NULL_HANDLE && _vk.vkDestroySampler !is null)
                _vk.vkDestroySampler(_device, _imageLinearSampler, null);
            if (_atlasSampler != VK_NULL_HANDLE && _vk.vkDestroySampler !is null)
                _vk.vkDestroySampler(_device, _atlasSampler, null);
            if (_descriptorPool != VK_NULL_HANDLE && _vk.vkDestroyDescriptorPool !is null)
                _vk.vkDestroyDescriptorPool(_device, _descriptorPool, null);
            if (_pipelineLayout != VK_NULL_HANDLE && _vk.vkDestroyPipelineLayout !is null)
                _vk.vkDestroyPipelineLayout(_device, _pipelineLayout, null);
            if (_descriptorSetLayout != VK_NULL_HANDLE && _vk.vkDestroyDescriptorSetLayout !is null)
                _vk.vkDestroyDescriptorSetLayout(_device, _descriptorSetLayout, null);
            foreach (ref frame; _frames)
            {
                if (frame.imageAvailable != VK_NULL_HANDLE && _vk.vkDestroySemaphore !is null)
                    _vk.vkDestroySemaphore(_device, frame.imageAvailable, null);
                if (frame.fence != VK_NULL_HANDLE && _vk.vkDestroyFence !is null)
                    _vk.vkDestroyFence(_device, frame.fence, null);
                frame = FrameResources.init;
            }
            _frames.length = 0;
            if (_commandPool != VK_NULL_HANDLE && _vk.vkDestroyCommandPool !is null)
                _vk.vkDestroyCommandPool(_device, _commandPool, null);
            if (_vk.vkDestroyDevice !is null)
                _vk.vkDestroyDevice(_device, null);
        }
        _device = null;
        if (_surface != VK_NULL_HANDLE && _instance !is null && _vk !is null &&
            _vk.vkDestroySurfaceKHR !is null)
            _vk.vkDestroySurfaceKHR(_instance, _surface, null);
        _surface = VK_NULL_HANDLE;
        if (_instance !is null && _vk !is null && _vk.vkDestroyInstance !is null)
            _vk.vkDestroyInstance(_instance, null);
        _instance = null;
        if (_vk !is null) _vk.close();
        _vk = null;
    }

    private void createInstance()
    {
        auto availableExtensions = enumerateInstanceExtensions();
        string[] extensions = ["VK_KHR_surface"];
        requireExtension(availableExtensions, "VK_KHR_surface");
        final switch (_native.kind)
        {
            case NativeSurfaceKind.xlib:
                if (contains(availableExtensions, "VK_KHR_xlib_surface"))
                    extensions ~= "VK_KHR_xlib_surface";
                else if (_native.handleB !is null && contains(availableExtensions, "VK_KHR_xcb_surface"))
                {
                    extensions ~= "VK_KHR_xcb_surface";
                    _usingXcb = true;
                }
                else
                    throw new Exception("Vulkan has neither a usable VK_KHR_xlib_surface nor VK_KHR_xcb_surface extension");
                break;
            case NativeSurfaceKind.win32:
                requireExtension(availableExtensions, "VK_KHR_win32_surface");
                extensions ~= "VK_KHR_win32_surface";
                break;
            case NativeSurfaceKind.metal:
                requireExtension(availableExtensions, "VK_EXT_metal_surface");
                extensions ~= "VK_EXT_metal_surface";
                break;
            case NativeSurfaceKind.none:
                throw new Exception("The selected native window does not expose a Vulkan surface");
        }
        VkFlags instanceFlags;
        if (contains(availableExtensions, "VK_KHR_portability_enumeration"))
        {
            extensions ~= "VK_KHR_portability_enumeration";
            instanceFlags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
        }

        string[] layers;
        if (_options.vulkanValidation && contains(enumerateInstanceLayers(), "VK_LAYER_KHRONOS_validation"))
            layers ~= "VK_LAYER_KHRONOS_validation";
        auto extensionPointers = makePointers(extensions);
        auto layerPointers = makePointers(layers);
        VkApplicationInfo application;
        application.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
        application.pApplicationName = toStringz(_options.title);
        application.applicationVersion = 1;
        application.pEngineName = "Aurora-D".ptr;
        application.engineVersion = 2;
        application.apiVersion = VK_API_VERSION_1_0;
        VkInstanceCreateInfo createInfo;
        createInfo.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        createInfo.flags = instanceFlags;
        createInfo.pApplicationInfo = &application;
        createInfo.enabledLayerCount = cast(uint) layerPointers.length;
        createInfo.ppEnabledLayerNames = layerPointers.ptr;
        createInfo.enabledExtensionCount = cast(uint) extensionPointers.length;
        createInfo.ppEnabledExtensionNames = extensionPointers.ptr;
        check(_vk.vkCreateInstance(&createInfo, null, &_instance), "creating the Vulkan instance");
    }

    private void createSurface()
    {
        final switch (_native.kind)
        {
            case NativeSurfaceKind.xlib:
                if (_usingXcb)
                {
                    if (_vk.vkCreateXcbSurfaceKHR is null)
                        throw new Exception("vkCreateXcbSurfaceKHR is unavailable");
                    VkXcbSurfaceCreateInfoKHR info;
                    info.sType = VK_STRUCTURE_TYPE_XCB_SURFACE_CREATE_INFO_KHR;
                    info.connection = _native.handleB;
                    info.window = cast(uint) _native.value;
                    check(_vk.vkCreateXcbSurfaceKHR(_instance, &info, null, &_surface),
                        "creating the Vulkan XCB surface");
                }
                else
                {
                    if (_vk.vkCreateXlibSurfaceKHR is null)
                        throw new Exception("vkCreateXlibSurfaceKHR is unavailable");
                    VkXlibSurfaceCreateInfoKHR info;
                    info.sType = VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR;
                    info.dpy = _native.handleA;
                    info.window = cast(c_ulong) _native.value;
                    check(_vk.vkCreateXlibSurfaceKHR(_instance, &info, null, &_surface),
                        "creating the Vulkan Xlib surface");
                }
                break;
            case NativeSurfaceKind.win32:
                if (_vk.vkCreateWin32SurfaceKHR is null)
                    throw new Exception("vkCreateWin32SurfaceKHR is unavailable");
                VkWin32SurfaceCreateInfoKHR win32;
                win32.sType = VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR;
                win32.hinstance = _native.handleA;
                win32.hwnd = _native.handleB;
                check(_vk.vkCreateWin32SurfaceKHR(_instance, &win32, null, &_surface),
                    "creating the Vulkan Win32 surface");
                break;
            case NativeSurfaceKind.metal:
                if (_vk.vkCreateMetalSurfaceEXT is null)
                    throw new Exception("vkCreateMetalSurfaceEXT is unavailable");
                VkMetalSurfaceCreateInfoEXT metal;
                metal.sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT;
                metal.pLayer = _native.handleA;
                check(_vk.vkCreateMetalSurfaceEXT(_instance, &metal, null, &_surface),
                    "creating the Vulkan Metal surface");
                break;
            case NativeSurfaceKind.none:
                throw new Exception("The selected native window does not expose a Vulkan surface");
        }
    }

    private void choosePhysicalDevice()
    {
        uint count;
        check(_vk.vkEnumeratePhysicalDevices(_instance, &count, null),
            "enumerating Vulkan physical devices");
        if (count == 0) throw new Exception("No Vulkan physical device is available");
        VkPhysicalDevice[] devices;
        devices.length = count;
        check(_vk.vkEnumeratePhysicalDevices(_instance, &count, devices.ptr),
            "enumerating Vulkan physical devices");
        foreach (device; devices)
        {
            uint graphics;
            uint present;
            if (findQueueFamilies(device, graphics, present) &&
                contains(enumerateDeviceExtensions(device), "VK_KHR_swapchain"))
            {
                _physicalDevice = device;
                _graphicsFamily = graphics;
                _presentFamily = present;
                return;
            }
        }
        throw new Exception("No Vulkan device supports graphics, presentation, and VK_KHR_swapchain");
    }

    private bool findQueueFamilies(VkPhysicalDevice device, out uint graphics, out uint present)
    {
        graphics = uint.max;
        present = uint.max;
        uint count;
        _vk.vkGetPhysicalDeviceQueueFamilyProperties(device, &count, null);
        VkQueueFamilyProperties[] families;
        families.length = count;
        _vk.vkGetPhysicalDeviceQueueFamilyProperties(device, &count, families.ptr);
        foreach (index, family; families)
        {
            if (family.queueCount > 0 && (family.queueFlags & VK_QUEUE_GRAPHICS_BIT) != 0 &&
                graphics == uint.max)
                graphics = cast(uint) index;
            VkBool32 supported;
            if (family.queueCount > 0 &&
                _vk.vkGetPhysicalDeviceSurfaceSupportKHR(device, cast(uint) index, _surface, &supported) == VK_SUCCESS &&
                supported != 0 && present == uint.max)
                present = cast(uint) index;
        }
        return graphics != uint.max && present != uint.max;
    }

    private void createDevice()
    {
        float priority = 1.0f;
        VkDeviceQueueCreateInfo[] queues;
        VkDeviceQueueCreateInfo graphics;
        graphics.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        graphics.queueFamilyIndex = _graphicsFamily;
        graphics.queueCount = 1;
        graphics.pQueuePriorities = &priority;
        queues ~= graphics;
        if (_presentFamily != _graphicsFamily)
        {
            auto presentation = graphics;
            presentation.queueFamilyIndex = _presentFamily;
            queues ~= presentation;
        }
        auto available = enumerateDeviceExtensions(_physicalDevice);
        string[] extensions = ["VK_KHR_swapchain"];
        if (contains(available, "VK_KHR_portability_subset"))
            extensions ~= "VK_KHR_portability_subset";
        auto pointers = makePointers(extensions);
        VkDeviceCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        info.queueCreateInfoCount = cast(uint) queues.length;
        info.pQueueCreateInfos = queues.ptr;
        info.enabledExtensionCount = cast(uint) pointers.length;
        info.ppEnabledExtensionNames = pointers.ptr;
        check(_vk.vkCreateDevice(_physicalDevice, &info, null, &_device),
            "creating the Vulkan logical device");
    }

    private void createDescriptorResources()
    {
        VkDescriptorSetLayoutBinding binding;
        binding.binding = 0;
        binding.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        binding.descriptorCount = 1;
        binding.stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
        VkDescriptorSetLayoutCreateInfo layoutInfo;
        layoutInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        layoutInfo.bindingCount = 1;
        layoutInfo.pBindings = &binding;
        check(_vk.vkCreateDescriptorSetLayout(_device, &layoutInfo, null, &_descriptorSetLayout),
            "creating the Vulkan descriptor layout");

        VkPipelineLayoutCreateInfo pipelineLayout;
        pipelineLayout.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        pipelineLayout.setLayoutCount = 1;
        pipelineLayout.pSetLayouts = &_descriptorSetLayout;
        check(_vk.vkCreatePipelineLayout(_device, &pipelineLayout, null, &_pipelineLayout),
            "creating the Vulkan pipeline layout");

        VkDescriptorPoolSize poolSize;
        poolSize.type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        poolSize.descriptorCount = imageDescriptorSetLimit;
        VkDescriptorPoolCreateInfo pool;
        pool.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        pool.maxSets = imageDescriptorSetLimit;
        pool.poolSizeCount = 1;
        pool.pPoolSizes = &poolSize;
        check(_vk.vkCreateDescriptorPool(_device, &pool, null, &_descriptorPool),
            "creating the Vulkan descriptor pool");
        VkDescriptorSetAllocateInfo allocation;
        allocation.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        allocation.descriptorPool = _descriptorPool;
        allocation.descriptorSetCount = 1;
        allocation.pSetLayouts = &_descriptorSetLayout;
        check(_vk.vkAllocateDescriptorSets(_device, &allocation, &_descriptorSet),
            "allocating the Vulkan descriptor set");

        VkSamplerCreateInfo sampler;
        sampler.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        // Glyph quads are emitted at their physical atlas size and snapped to
        // framebuffer pixels. Nearest sampling preserves the rasterizer's A8
        // coverage exactly instead of adding a second blur at the GPU stage.
        sampler.magFilter = VK_FILTER_NEAREST;
        sampler.minFilter = VK_FILTER_NEAREST;
        sampler.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
        sampler.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler.compareOp = VK_COMPARE_OP_ALWAYS;
        sampler.maxLod = 0.0f;
        sampler.borderColor = VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK;
        check(_vk.vkCreateSampler(_device, &sampler, null, &_atlasSampler),
            "creating the Vulkan glyph sampler");

        sampler.magFilter = VK_FILTER_LINEAR;
        sampler.minFilter = VK_FILTER_LINEAR;
        check(_vk.vkCreateSampler(_device, &sampler, null, &_imageLinearSampler),
            "creating the Vulkan linear image sampler");

        sampler.magFilter = VK_FILTER_NEAREST;
        sampler.minFilter = VK_FILTER_NEAREST;
        check(_vk.vkCreateSampler(_device, &sampler, null, &_imageNearestSampler),
            "creating the Vulkan nearest image sampler");
    }

    private void createCommandResources()
    {
        VkCommandPoolCreateInfo pool;
        pool.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        pool.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        pool.queueFamilyIndex = _graphicsFamily;
        check(_vk.vkCreateCommandPool(_device, &pool, null, &_commandPool),
            "creating the Vulkan command pool");

        enum uint frameCount = 2;
        VkCommandBuffer[] commandBuffers;
        commandBuffers.length = frameCount;
        VkCommandBufferAllocateInfo allocation;
        allocation.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        allocation.commandPool = _commandPool;
        allocation.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        allocation.commandBufferCount = frameCount;
        check(_vk.vkAllocateCommandBuffers(_device, &allocation, commandBuffers.ptr),
            "allocating Vulkan command buffers");
        _frames.length = frameCount;
        foreach (index, commandBuffer; commandBuffers)
            _frames[index].commandBuffer = commandBuffer;
    }

    private void createSyncResources()
    {
        VkSemaphoreCreateInfo semaphore;
        semaphore.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        VkFenceCreateInfo fence;
        fence.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        fence.flags = VK_FENCE_CREATE_SIGNALED_BIT;
        foreach (index, ref frame; _frames)
        {
            check(_vk.vkCreateSemaphore(_device, &semaphore, null,
                &frame.imageAvailable),
                "creating a Vulkan acquire semaphore");
            check(_vk.vkCreateFence(_device, &fence, null, &frame.fence),
                "creating a Vulkan frame fence");
        }
    }

    private void createPresentSemaphores()
    {
        _presentSemaphores.length = _swapchainImages.length;
        VkSemaphoreCreateInfo semaphore;
        semaphore.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        foreach (ref value; _presentSemaphores)
            check(_vk.vkCreateSemaphore(_device, &semaphore, null, &value),
                "creating a per-image Vulkan present semaphore");
    }

    private void destroyPresentSemaphores()
    {
        if (_device is null || _vk is null)
        {
            _presentSemaphores.length = 0;
            return;
        }
        foreach (value; _presentSemaphores)
            if (value != VK_NULL_HANDLE && _vk.vkDestroySemaphore !is null)
                _vk.vkDestroySemaphore(_device, value, null);
        _presentSemaphores.length = 0;
    }

    private void createSwapchain()
    {
        VkSurfaceCapabilitiesKHR capabilities;
        check(_vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(_physicalDevice, _surface, &capabilities),
            "querying Vulkan surface capabilities");
        auto formats = surfaceFormats();
        auto modes = presentModes();
        if (formats.length == 0 || modes.length == 0)
            throw new Exception("The Vulkan surface has no formats or presentation modes");
        auto chosen = formats[0];
        foreach (format; formats)
        {
            if (format.format == VK_FORMAT_B8G8R8A8_UNORM || format.format == VK_FORMAT_R8G8B8A8_UNORM)
            {
                chosen = format;
                if (format.format == VK_FORMAT_B8G8R8A8_UNORM) break;
            }
        }
        if (formats.length == 1 && formats[0].format == VK_FORMAT_UNDEFINED)
        {
            chosen.format = VK_FORMAT_B8G8R8A8_UNORM;
            chosen.colorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
        }
        const nextFormat = chosen.format;
        const needsFormatResources = _renderPass == VK_NULL_HANDLE ||
            _pipeline == VK_NULL_HANDLE || _imagePipeline == VK_NULL_HANDLE ||
            _swapchainFormat != nextFormat;
        if (needsFormatResources)
            destroyFormatResources();
        _swapchainFormat = nextFormat;
        if (capabilities.currentExtent.width != uint.max)
            _extent = capabilities.currentExtent;
        else
        {
            _extent.width = clampUInt(cast(uint) maxInt(1, _requestedSize.width),
                capabilities.minImageExtent.width, capabilities.maxImageExtent.width);
            _extent.height = clampUInt(cast(uint) maxInt(1, _requestedSize.height),
                capabilities.minImageExtent.height, capabilities.maxImageExtent.height);
        }
        _presentMode = choosePresentMode(modes, _options.vsync,
            _options.lowLatency);
        const imageCount = chooseSwapchainImageCount(capabilities.minImageCount,
            capabilities.maxImageCount, _presentMode, _options.lowLatency);
        uint[2] queueIndices = [_graphicsFamily, _presentFamily];
        VkSwapchainCreateInfoKHR info;
        info.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
        info.surface = _surface;
        info.minImageCount = imageCount;
        info.imageFormat = chosen.format;
        info.imageColorSpace = chosen.colorSpace;
        info.imageExtent = _extent;
        info.imageArrayLayers = 1;
        info.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
        if (_graphicsFamily != _presentFamily)
        {
            info.imageSharingMode = VK_SHARING_MODE_CONCURRENT;
            info.queueFamilyIndexCount = 2;
            info.pQueueFamilyIndices = queueIndices.ptr;
        }
        else
            info.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
        info.preTransform = (capabilities.supportedTransforms & VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR) != 0 ?
            VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR : capabilities.currentTransform;
        info.compositeAlpha = chooseBit(capabilities.supportedCompositeAlpha,
            VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR);
        info.presentMode = _presentMode;
        info.clipped = VK_TRUE;
        check(_vk.vkCreateSwapchainKHR(_device, &info, null, &_swapchain),
            "creating the Vulkan swapchain");

        uint actualCount;
        check(_vk.vkGetSwapchainImagesKHR(_device, _swapchain, &actualCount, null),
            "querying Vulkan swapchain images");
        _swapchainImages.length = actualCount;
        check(_vk.vkGetSwapchainImagesKHR(_device, _swapchain, &actualCount, _swapchainImages.ptr),
            "retrieving Vulkan swapchain images");
        createPresentSemaphores();
        createSwapchainViews();
        if (needsFormatResources)
        {
            createRenderPass();
            createPipelines();
        }
        createFramebuffers();
        _swapchainDirty = false;
    }

    private void recreateSwapchain()
    {
        if (_device is null) return;
        waitForSubmittedFrames();
        destroySwapchainImages();
        createSwapchain();
    }

    private void createSwapchainViews()
    {
        _swapchainViews.length = _swapchainImages.length;
        foreach (index, image; _swapchainImages)
        {
            VkImageViewCreateInfo info;
            info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
            info.image = image;
            info.viewType = VK_IMAGE_VIEW_TYPE_2D;
            info.format = _swapchainFormat;
            info.components = VkComponentMapping(
                VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY,
                VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY);
            info.subresourceRange = colorRange();
            check(_vk.vkCreateImageView(_device, &info, null, &_swapchainViews[index]),
                "creating a Vulkan swapchain image view");
        }
    }

    private void createRenderPass()
    {
        VkAttachmentDescription attachment;
        attachment.format = _swapchainFormat;
        attachment.samples = VK_SAMPLE_COUNT_1_BIT;
        attachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
        attachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
        attachment.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        attachment.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
        attachment.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        attachment.finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        VkAttachmentReference color;
        color.attachment = 0;
        color.layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        VkSubpassDescription subpass;
        subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &color;
        VkSubpassDependency dependency;
        dependency.srcSubpass = VK_SUBPASS_EXTERNAL;
        dependency.dstSubpass = 0;
        dependency.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dependency.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dependency.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        dependency.dependencyFlags = VK_DEPENDENCY_BY_REGION_BIT;
        VkRenderPassCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        info.attachmentCount = 1;
        info.pAttachments = &attachment;
        info.subpassCount = 1;
        info.pSubpasses = &subpass;
        info.dependencyCount = 1;
        info.pDependencies = &dependency;
        check(_vk.vkCreateRenderPass(_device, &info, null, &_renderPass),
            "creating the Vulkan render pass");
    }

    private void createPipelines()
    {
        _pipeline = createGraphicsPipeline(fragmentShaderSpirv,
            "creating the Vulkan glyph graphics pipeline (check embedded SPIR-V compatibility)");
        _imagePipeline = createGraphicsPipeline(imageFragmentShaderSpirv,
            "creating the Vulkan RGBA image graphics pipeline (check embedded SPIR-V compatibility)");
    }

    private VkPipeline createGraphicsPipeline(const(uint)[] fragmentCode, string operation)
    {
        const vertexModule = createShader(vertexShaderSpirv);
        const fragmentModule = createShader(fragmentCode);
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
        VkVertexInputAttributeDescription[3] attributes;
        attributes[0] = VkVertexInputAttributeDescription(0, 0, VK_FORMAT_R32G32_SFLOAT,
            cast(uint) GpuVertex.x.offsetof);
        attributes[1] = VkVertexInputAttributeDescription(1, 0, VK_FORMAT_R32G32_SFLOAT,
            cast(uint) GpuVertex.u.offsetof);
        attributes[2] = VkVertexInputAttributeDescription(2, 0, VK_FORMAT_R32G32B32A32_SFLOAT,
            cast(uint) GpuVertex.r.offsetof);
        VkPipelineVertexInputStateCreateInfo vertexInput;
        vertexInput.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vertexInput.vertexBindingDescriptionCount = 1;
        vertexInput.pVertexBindingDescriptions = &binding;
        vertexInput.vertexAttributeDescriptionCount = attributes.length;
        vertexInput.pVertexAttributeDescriptions = attributes.ptr;
        VkPipelineInputAssemblyStateCreateInfo inputAssembly;
        inputAssembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        inputAssembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
        VkPipelineViewportStateCreateInfo viewport;
        viewport.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        viewport.viewportCount = 1;
        viewport.scissorCount = 1;
        VkPipelineRasterizationStateCreateInfo rasterization;
        rasterization.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        rasterization.polygonMode = VK_POLYGON_MODE_FILL;
        rasterization.cullMode = 0;
        rasterization.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
        rasterization.lineWidth = 1.0f;
        VkPipelineMultisampleStateCreateInfo multisample;
        multisample.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
        VkPipelineColorBlendAttachmentState blend;
        blend.blendEnable = VK_TRUE;
        blend.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
        blend.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        blend.colorBlendOp = VK_BLEND_OP_ADD;
        blend.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
        blend.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        blend.alphaBlendOp = VK_BLEND_OP_ADD;
        blend.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
            VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
        VkPipelineColorBlendStateCreateInfo colorBlend;
        colorBlend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        colorBlend.attachmentCount = 1;
        colorBlend.pAttachments = &blend;
        int[2] dynamicStates = [VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR];
        VkPipelineDynamicStateCreateInfo dynamic;
        dynamic.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dynamic.dynamicStateCount = dynamicStates.length;
        dynamic.pDynamicStates = dynamicStates.ptr;
        VkGraphicsPipelineCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        info.stageCount = stages.length;
        info.pStages = stages.ptr;
        info.pVertexInputState = &vertexInput;
        info.pInputAssemblyState = &inputAssembly;
        info.pViewportState = &viewport;
        info.pRasterizationState = &rasterization;
        info.pMultisampleState = &multisample;
        info.pColorBlendState = &colorBlend;
        info.pDynamicState = &dynamic;
        info.layout = _pipelineLayout;
        info.renderPass = _renderPass;
        info.subpass = 0;
        info.basePipelineIndex = -1;
        VkPipeline pipeline;
        check(_vk.vkCreateGraphicsPipelines(_device, VK_NULL_HANDLE, 1, &info, null,
            &pipeline), operation);
        return pipeline;
    }

    private VkShaderModule createShader(const(uint)[] code)
    {
        VkShaderModuleCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
        info.codeSize = code.length * uint.sizeof;
        info.pCode = code.ptr;
        VkShaderModule result;
        check(_vk.vkCreateShaderModule(_device, &info, null, &result),
            "creating a Vulkan shader module");
        return result;
    }

    private void createFramebuffers()
    {
        _framebuffers.length = _swapchainViews.length;
        foreach (index, view; _swapchainViews)
        {
            VkFramebufferCreateInfo info;
            info.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
            info.renderPass = _renderPass;
            info.attachmentCount = 1;
            info.pAttachments = &view;
            info.width = _extent.width;
            info.height = _extent.height;
            info.layers = 1;
            check(_vk.vkCreateFramebuffer(_device, &info, null, &_framebuffers[index]),
                "creating a Vulkan framebuffer");
        }
    }

    private GpuLayerGeometry ensureGeometryBuffers(DrawList list,
        ulong id, ulong revision)
    {
        auto found = id in _geometryCaches;
        GpuLayerGeometry cache;
        if (found is null)
        {
            cache = new GpuLayerGeometry();
            _geometryCaches[id] = cache;
        }
        else
            cache = *found;

        const atlasWidthInt = maxInt(1, list.fonts.atlas.width());
        const atlasHeightInt = maxInt(1, list.fonts.atlas.height());
        if (cache.revision == revision && cache.viewport == list.viewport &&
            cache.atlasWidth == atlasWidthInt && cache.atlasHeight == atlasHeightInt)
            return cache;

        const vertexBytes = max(cast(VkDeviceSize) 256,
            cast(VkDeviceSize) list.vertices.length * GpuVertex.sizeof);
        const indexBytes = max(cast(VkDeviceSize) 256,
            cast(VkDeviceSize) list.indices.length * uint.sizeof);
        ensureHostBuffer(cache.vertexBuffer, vertexBytes, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        ensureHostBuffer(cache.indexBuffer, indexBytes, VK_BUFFER_USAGE_INDEX_BUFFER_BIT);

        auto destination = cast(GpuVertex*) cache.vertexBuffer.mapped;
        const width = cast(float) maxInt(1, list.viewport.width);
        const height = cast(float) maxInt(1, list.viewport.height);
        const atlasWidth = cast(float) atlasWidthInt;
        const atlasHeight = cast(float) atlasHeightInt;
        foreach (index, source; list.vertices)
        {
            GpuVertex value;
            // Vertices are normalized to this layer's own local viewport.
            // Moving the layer later requires only vkCmdSetViewport.
            value.x = source.x * 2.0f / width - 1.0f;
            value.y = source.y * 2.0f / height - 1.0f;
            value.u = source.u / atlasWidth;
            value.v = source.v / atlasHeight;
            value.r = source.r;
            value.g = source.g;
            value.b = source.b;
            value.a = source.a;
            destination[index] = value;
        }
        foreach (batch; list.batches)
        {
            if (batch.kind != DrawBatchKind.rgbaImage ||
                batch.imageIndex >= list.rgbaImages.length)
                continue;
            auto command = list.rgbaImages[batch.imageIndex];
            if (command.image is null) continue;
            const imageWidth = cast(float) maxInt(1, command.image.width());
            const imageHeight = cast(float) maxInt(1, command.image.height());
            foreach (offset; 0 .. batch.indexCount)
            {
                const indexOffset = cast(size_t) batch.firstIndex + cast(size_t) offset;
                if (indexOffset >= list.indices.length) break;
                const vertexIndex = list.indices[indexOffset];
                if (vertexIndex >= list.vertices.length) continue;
                destination[vertexIndex].u = list.vertices[vertexIndex].u / imageWidth;
                destination[vertexIndex].v = list.vertices[vertexIndex].v / imageHeight;
            }
        }
        if (list.indices.length > 0)
            memcpy(cache.indexBuffer.mapped, list.indices.ptr,
                list.indices.length * uint.sizeof);
        ++_stats.geometryUploads;
        _stats.geometryUploadBytes += cast(ulong) list.vertices.length * GpuVertex.sizeof +
            cast(ulong) list.indices.length * uint.sizeof;
        cache.revision = revision;
        cache.viewport = list.viewport;
        cache.atlasWidth = atlasWidthInt;
        cache.atlasHeight = atlasHeightInt;
        cache.indexCount = cast(uint) list.indices.length;
        return cache;
    }

    private void retireUnusedGeometry()
    {
        // The normal transform path marks caches in place and allocates no
        // live-ID scratch array. A removal list exists only when a layer has
        // actually left the retained scene.
        ulong[] stale;
        foreach (id, cache; _geometryCaches)
            if (id != 0 && cache.lastSeenScene != _sceneGeneration) stale ~= id;
        foreach (id; stale)
        {
            auto cache = _geometryCaches[id];
            destroyGpuGeometry(cache);
            _geometryCaches.remove(id);
        }
    }

    private void destroyGpuGeometry(GpuLayerGeometry cache)
    {
        if (cache is null) return;
        destroyHostBuffer(cache.vertexBuffer);
        destroyHostBuffer(cache.indexBuffer);
    }

    private void destroyGeometryCaches()
    {
        foreach (id, cache; _geometryCaches)
            destroyGpuGeometry(cache);
        _geometryCaches = null;
    }

    private void ensureAtlas(DrawList list)
    {
        const atlas = list.fonts.atlas;
        if (_atlasImage == VK_NULL_HANDLE || _atlasWidth != atlas.width() ||
            _atlasHeight != atlas.height())
        {
            destroyAtlasImage();
            _atlasWidth = atlas.width();
            _atlasHeight = atlas.height();
            createAtlasImage();
            _atlasRevision = 0;
            _atlasInitialized = false;
        }
        const byteCount = cast(VkDeviceSize) _atlasWidth * cast(VkDeviceSize) _atlasHeight;
        ensureHostBuffer(_atlasStaging, max(cast(VkDeviceSize) 256, byteCount),
            VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
        if (_atlasRevision != atlas.revision())
        {
            memcpy(_atlasStaging.mapped, atlas.pixels().ptr, cast(size_t) byteCount);
            _atlasRevision = atlas.revision();
        }
    }

    private void createAtlasImage()
    {
        VkImageCreateInfo image;
        image.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        image.imageType = VK_IMAGE_TYPE_2D;
        image.format = VK_FORMAT_R8_UNORM;
        image.extent = VkExtent3D(cast(uint) _atlasWidth, cast(uint) _atlasHeight, 1);
        image.mipLevels = 1;
        image.arrayLayers = 1;
        image.samples = VK_SAMPLE_COUNT_1_BIT;
        image.tiling = VK_IMAGE_TILING_OPTIMAL;
        image.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
        image.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        image.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        check(_vk.vkCreateImage(_device, &image, null, &_atlasImage),
            "creating the Vulkan glyph atlas image");
        VkMemoryRequirements requirements;
        _vk.vkGetImageMemoryRequirements(_device, _atlasImage, &requirements);
        VkMemoryAllocateInfo allocation;
        allocation.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        allocation.allocationSize = requirements.size;
        allocation.memoryTypeIndex = findMemoryType(requirements.memoryTypeBits,
            VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        check(_vk.vkAllocateMemory(_device, &allocation, null, &_atlasMemory),
            "allocating Vulkan glyph atlas memory");
        check(_vk.vkBindImageMemory(_device, _atlasImage, _atlasMemory, 0),
            "binding Vulkan glyph atlas memory");
        VkImageViewCreateInfo view;
        view.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view.image = _atlasImage;
        view.viewType = VK_IMAGE_VIEW_TYPE_2D;
        view.format = VK_FORMAT_R8_UNORM;
        view.components = VkComponentMapping(VK_COMPONENT_SWIZZLE_IDENTITY,
            VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY,
            VK_COMPONENT_SWIZZLE_IDENTITY);
        view.subresourceRange = colorRange();
        check(_vk.vkCreateImageView(_device, &view, null, &_atlasView),
            "creating the Vulkan glyph atlas view");
        VkDescriptorImageInfo imageInfo;
        imageInfo.sampler = _atlasSampler;
        imageInfo.imageView = _atlasView;
        imageInfo.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        VkWriteDescriptorSet write;
        write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write.dstSet = _descriptorSet;
        write.dstBinding = 0;
        write.descriptorCount = 1;
        write.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        write.pImageInfo = &imageInfo;
        _vk.vkUpdateDescriptorSets(_device, 1, &write, 0, null);
    }

    private void ensureSceneImages(RenderScene scene)
    {
        ensureDrawListImages(scene.base);
        foreach (layer; scene.layers)
            if (layer.visible && layer.drawList !is null)
                ensureDrawListImages(layer.drawList);
    }

    private void ensureDrawListImages(DrawList list)
    {
        if (list is null) return;
        foreach (command; list.rgbaImages)
            ensureImageTexture(command.image);
    }

    private GpuImageTexture ensureImageTexture(RgbaImage image)
    {
        if (image is null) return null;
        auto found = image.id() in _imageTextures;
        GpuImageTexture texture;
        if (found is null)
        {
            texture = new GpuImageTexture();
            _imageTextures[image.id()] = texture;
        }
        else
            texture = *found;

        if (texture.image == VK_NULL_HANDLE ||
            texture.width != image.width() || texture.height != image.height())
        {
            destroyGpuImageStorage(texture);
            texture.width = image.width();
            texture.height = image.height();
            createGpuImageStorage(texture);
            texture.revision = 0;
            texture.submittedRevision = 0;
            texture.initialized = false;
        }

        const byteCount = cast(VkDeviceSize) image.width() *
            cast(VkDeviceSize) image.height() * 4;
        ensureHostBuffer(texture.staging, max(cast(VkDeviceSize) 256, byteCount),
            VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
        if (texture.revision != image.revision())
        {
            memcpy(texture.staging.mapped, image.pixels().ptr, cast(size_t) byteCount);
            texture.revision = image.revision();
        }
        if (texture.linearDescriptorSet == VK_NULL_HANDLE ||
            texture.nearestDescriptorSet == VK_NULL_HANDLE)
            allocateGpuImageDescriptors(texture);
        updateGpuImageDescriptors(texture);
        return texture;
    }

    private GpuImageTexture imageTexture(RgbaImage image)
    {
        if (image is null) return null;
        auto found = image.id() in _imageTextures;
        return found is null ? null : *found;
    }

    private void createGpuImageStorage(GpuImageTexture texture)
    {
        VkImageCreateInfo image;
        image.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        image.imageType = VK_IMAGE_TYPE_2D;
        image.format = VK_FORMAT_R8G8B8A8_UNORM;
        image.extent = VkExtent3D(cast(uint) texture.width, cast(uint) texture.height, 1);
        image.mipLevels = 1;
        image.arrayLayers = 1;
        image.samples = VK_SAMPLE_COUNT_1_BIT;
        image.tiling = VK_IMAGE_TILING_OPTIMAL;
        image.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
        image.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        image.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        check(_vk.vkCreateImage(_device, &image, null, &texture.image),
            "creating a Vulkan RGBA image");

        VkMemoryRequirements requirements;
        _vk.vkGetImageMemoryRequirements(_device, texture.image, &requirements);
        VkMemoryAllocateInfo allocation;
        allocation.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        allocation.allocationSize = requirements.size;
        allocation.memoryTypeIndex = findMemoryType(requirements.memoryTypeBits,
            VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        check(_vk.vkAllocateMemory(_device, &allocation, null, &texture.memory),
            "allocating Vulkan RGBA image memory");
        check(_vk.vkBindImageMemory(_device, texture.image, texture.memory, 0),
            "binding Vulkan RGBA image memory");

        VkImageViewCreateInfo view;
        view.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view.image = texture.image;
        view.viewType = VK_IMAGE_VIEW_TYPE_2D;
        view.format = VK_FORMAT_R8G8B8A8_UNORM;
        view.components = VkComponentMapping(VK_COMPONENT_SWIZZLE_IDENTITY,
            VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY,
            VK_COMPONENT_SWIZZLE_IDENTITY);
        view.subresourceRange = colorRange();
        check(_vk.vkCreateImageView(_device, &view, null, &texture.view),
            "creating a Vulkan RGBA image view");
    }

    private void allocateGpuImageDescriptors(GpuImageTexture texture)
    {
        VkDescriptorSetLayout[2] layouts = [_descriptorSetLayout, _descriptorSetLayout];
        VkDescriptorSet[2] sets;
        VkDescriptorSetAllocateInfo allocation;
        allocation.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        allocation.descriptorPool = _descriptorPool;
        allocation.descriptorSetCount = sets.length;
        allocation.pSetLayouts = layouts.ptr;
        check(_vk.vkAllocateDescriptorSets(_device, &allocation, sets.ptr),
            "allocating Vulkan RGBA image descriptor sets");
        texture.linearDescriptorSet = sets[0];
        texture.nearestDescriptorSet = sets[1];
    }

    private void updateGpuImageDescriptors(GpuImageTexture texture)
    {
        if (texture.view == VK_NULL_HANDLE ||
            texture.linearDescriptorSet == VK_NULL_HANDLE ||
            texture.nearestDescriptorSet == VK_NULL_HANDLE)
            return;

        VkDescriptorImageInfo[2] imageInfos;
        imageInfos[0].sampler = _imageLinearSampler;
        imageInfos[0].imageView = texture.view;
        imageInfos[0].imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        imageInfos[1].sampler = _imageNearestSampler;
        imageInfos[1].imageView = texture.view;
        imageInfos[1].imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

        VkWriteDescriptorSet[2] writes;
        writes[0].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[0].dstSet = texture.linearDescriptorSet;
        writes[0].dstBinding = 0;
        writes[0].descriptorCount = 1;
        writes[0].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        writes[0].pImageInfo = &imageInfos[0];
        writes[1].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[1].dstSet = texture.nearestDescriptorSet;
        writes[1].dstBinding = 0;
        writes[1].descriptorCount = 1;
        writes[1].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        writes[1].pImageInfo = &imageInfos[1];
        _vk.vkUpdateDescriptorSets(_device, writes.length, writes.ptr, 0, null);
    }

    private void recordCommandBuffer(RenderScene scene, uint imageIndex,
        VkCommandBuffer commandBuffer)
    {
        VkCommandBufferBeginInfo begin;
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        check(_vk.vkBeginCommandBuffer(commandBuffer, &begin),
            "beginning the Vulkan command buffer");
        uploadAtlas(commandBuffer, scene.base);
        uploadSceneImages(commandBuffer, scene);

        VkClearValue clear;
        clear.color.float32[0] = scene.base.clearColor.r / 255.0f;
        clear.color.float32[1] = scene.base.clearColor.g / 255.0f;
        clear.color.float32[2] = scene.base.clearColor.b / 255.0f;
        clear.color.float32[3] = scene.base.clearColor.a / 255.0f;
        VkRenderPassBeginInfo pass;
        pass.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        pass.renderPass = _renderPass;
        pass.framebuffer = _framebuffers[imageIndex];
        pass.renderArea = VkRect2D(VkOffset2D(0, 0), _extent);
        pass.clearValueCount = 1;
        pass.pClearValues = &clear;
        _vk.vkCmdBeginRenderPass(commandBuffer, &pass, 0);

        auto baseCache = _geometryCaches[0];
        recordRetainedLayer(commandBuffer, scene.base, baseCache,
            Rect(0, 0, cast(int) _extent.width, cast(int) _extent.height));
        foreach (layer; scene.layers)
        {
            if (!layer.visible || layer.drawList is null || layer.deviceBounds.empty())
                continue;
            auto found = layer.id in _geometryCaches;
            if (found is null) continue;
            recordRetainedLayer(commandBuffer, layer.drawList, *found, layer.deviceBounds);
        }

        _vk.vkCmdEndRenderPass(commandBuffer);
        check(_vk.vkEndCommandBuffer(commandBuffer), "ending the Vulkan command buffer");
    }

    private void recordRetainedLayer(VkCommandBuffer commandBuffer, DrawList list,
        GpuLayerGeometry geometry,
        Rect deviceBounds)
    {
        if (list is null || geometry is null || geometry.indexCount == 0 ||
            deviceBounds.empty()) return;
        ++_stats.layerDraws;
        const framebufferBounds = Rect(0, 0, cast(int) _extent.width,
            cast(int) _extent.height);
        if (deviceBounds.intersection(framebufferBounds).empty()) return;

        // Each cache stores NDC coordinates relative to its own local size.
        // Changing x/y here moves the complete Aurora window without touching
        // its vertex/index buffers or executing any widget paint code.
        VkViewport viewport = VkViewport(cast(float) deviceBounds.x,
            cast(float) deviceBounds.y, cast(float) deviceBounds.width,
            cast(float) deviceBounds.height, 0.0f, 1.0f);
        _vk.vkCmdSetViewport(commandBuffer, 0, 1, &viewport);
        VkDeviceSize zero;
        _vk.vkCmdBindVertexBuffers(commandBuffer, 0, 1,
            &geometry.vertexBuffer.buffer, &zero);
        _vk.vkCmdBindIndexBuffer(commandBuffer, geometry.indexBuffer.buffer,
            0, VK_INDEX_TYPE_UINT32);

        VkPipeline currentPipeline = VK_NULL_HANDLE;
        VkDescriptorSet currentDescriptorSet = VK_NULL_HANDLE;
        foreach (batch; list.batches)
        {
            VkPipeline pipeline = _pipeline;
            VkDescriptorSet descriptorSet = _descriptorSet;
            switch (batch.kind)
            {
                case DrawBatchKind.triangles:
                    break;
                case DrawBatchKind.rgbaImage:
                    if (batch.imageIndex >= list.rgbaImages.length) continue;
                    auto command = list.rgbaImages[batch.imageIndex];
                    auto texture = imageTexture(command.image);
                    if (texture is null) continue;
                    descriptorSet = command.linearFiltering ?
                        texture.linearDescriptorSet : texture.nearestDescriptorSet;
                    if (descriptorSet == VK_NULL_HANDLE) continue;
                    pipeline = _imagePipeline;
                    break;
                case DrawBatchKind.rgbImage:
                    continue;
                default:
                    continue;
            }
            auto clipped = batch.clip.translated(deviceBounds.x, deviceBounds.y)
                .intersection(deviceBounds).intersection(framebufferBounds);
            if (clipped.empty() || batch.indexCount == 0) continue;
            if (pipeline != currentPipeline)
            {
                _vk.vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
                currentPipeline = pipeline;
                currentDescriptorSet = VK_NULL_HANDLE;
            }
            if (descriptorSet != currentDescriptorSet)
            {
                _vk.vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                    _pipelineLayout, 0, 1, &descriptorSet, 0, null);
                currentDescriptorSet = descriptorSet;
            }
            VkRect2D scissor;
            scissor.offset = VkOffset2D(clipped.x, clipped.y);
            scissor.extent = VkExtent2D(cast(uint) clipped.width,
                cast(uint) clipped.height);
            _vk.vkCmdSetScissor(commandBuffer, 0, 1, &scissor);
            _vk.vkCmdDrawIndexed(commandBuffer, batch.indexCount, 1,
                batch.firstIndex, 0, 0);
        }
    }

    private void uploadAtlas(VkCommandBuffer commandBuffer, DrawList list)
    {
        if (_atlasRevision != list.fonts.atlas.revision()) return;
        // The staging bytes were refreshed in ensureAtlas. Upload every revision once
        // per renderer instance; process-wide statics break multiple windows/devices.
        if (_submittedAtlasRevision == _atlasRevision &&
            _submittedAtlasImage == _atlasImage && _atlasInitialized)
            return;

        VkImageMemoryBarrier toTransfer;
        toTransfer.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        toTransfer.oldLayout = _atlasInitialized ? VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL :
            VK_IMAGE_LAYOUT_UNDEFINED;
        toTransfer.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        toTransfer.srcQueueFamilyIndex = uint.max;
        toTransfer.dstQueueFamilyIndex = uint.max;
        toTransfer.image = _atlasImage;
        toTransfer.subresourceRange = colorRange();
        toTransfer.srcAccessMask = _atlasInitialized ? VK_ACCESS_SHADER_READ_BIT : 0;
        toTransfer.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        _vk.vkCmdPipelineBarrier(commandBuffer,
            _atlasInitialized ? VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT : VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &toTransfer);
        VkBufferImageCopy region;
        region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.layerCount = 1;
        region.imageExtent = VkExtent3D(cast(uint) _atlasWidth, cast(uint) _atlasHeight, 1);
        _vk.vkCmdCopyBufferToImage(commandBuffer, _atlasStaging.buffer, _atlasImage,
            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
        VkImageMemoryBarrier toShader = toTransfer;
        toShader.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        toShader.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        toShader.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        toShader.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
        _vk.vkCmdPipelineBarrier(commandBuffer, VK_PIPELINE_STAGE_TRANSFER_BIT,
            VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &toShader);
        _atlasInitialized = true;
        ++_stats.atlasUploads;
        _submittedAtlasRevision = _atlasRevision;
        _submittedAtlasImage = _atlasImage;
    }

    private void uploadSceneImages(VkCommandBuffer commandBuffer, RenderScene scene)
    {
        uploadDrawListImages(commandBuffer, scene.base);
        foreach (layer; scene.layers)
            if (layer.visible && layer.drawList !is null)
                uploadDrawListImages(commandBuffer, layer.drawList);
    }

    private void uploadDrawListImages(VkCommandBuffer commandBuffer, DrawList list)
    {
        if (list is null) return;
        foreach (command; list.rgbaImages)
        {
            auto texture = imageTexture(command.image);
            if (texture is null) continue;
            uploadImageTexture(commandBuffer, texture);
        }
    }

    private void uploadImageTexture(VkCommandBuffer commandBuffer, GpuImageTexture texture)
    {
        if (texture is null || texture.image == VK_NULL_HANDLE || texture.revision == 0)
            return;
        if (texture.submittedRevision == texture.revision && texture.initialized)
            return;

        VkImageMemoryBarrier toTransfer;
        toTransfer.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        toTransfer.oldLayout = texture.initialized ? VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL :
            VK_IMAGE_LAYOUT_UNDEFINED;
        toTransfer.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        toTransfer.srcQueueFamilyIndex = uint.max;
        toTransfer.dstQueueFamilyIndex = uint.max;
        toTransfer.image = texture.image;
        toTransfer.subresourceRange = colorRange();
        toTransfer.srcAccessMask = texture.initialized ? VK_ACCESS_SHADER_READ_BIT : 0;
        toTransfer.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        _vk.vkCmdPipelineBarrier(commandBuffer,
            texture.initialized ? VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT : VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &toTransfer);

        VkBufferImageCopy region;
        region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.layerCount = 1;
        region.imageExtent = VkExtent3D(cast(uint) texture.width, cast(uint) texture.height, 1);
        _vk.vkCmdCopyBufferToImage(commandBuffer, texture.staging.buffer, texture.image,
            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

        VkImageMemoryBarrier toShader = toTransfer;
        toShader.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        toShader.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        toShader.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        toShader.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
        _vk.vkCmdPipelineBarrier(commandBuffer, VK_PIPELINE_STAGE_TRANSFER_BIT,
            VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &toShader);

        texture.initialized = true;
        texture.submittedRevision = texture.revision;
    }

    private void ensureHostBuffer(ref HostBuffer buffer, VkDeviceSize required, VkFlags usage)
    {
        if (buffer.buffer != VK_NULL_HANDLE && buffer.capacity >= required) return;
        destroyHostBuffer(buffer);
        VkDeviceSize capacity = 256;
        while (capacity < required) capacity *= 2;
        VkBufferCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        info.size = capacity;
        info.usage = usage;
        info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        check(_vk.vkCreateBuffer(_device, &info, null, &buffer.buffer),
            "creating a Vulkan host buffer");
        VkMemoryRequirements requirements;
        _vk.vkGetBufferMemoryRequirements(_device, buffer.buffer, &requirements);
        VkMemoryAllocateInfo allocation;
        allocation.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        allocation.allocationSize = requirements.size;
        allocation.memoryTypeIndex = findMemoryType(requirements.memoryTypeBits,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        check(_vk.vkAllocateMemory(_device, &allocation, null, &buffer.memory),
            "allocating Vulkan host buffer memory");
        check(_vk.vkBindBufferMemory(_device, buffer.buffer, buffer.memory, 0),
            "binding Vulkan host buffer memory");
        check(_vk.vkMapMemory(_device, buffer.memory, 0, capacity, 0, &buffer.mapped),
            "mapping Vulkan host buffer memory");
        buffer.capacity = capacity;
    }

    private void destroyHostBuffer(ref HostBuffer buffer)
    {
        if (_device is null || _vk is null)
        {
            buffer = HostBuffer.init;
            return;
        }
        if (buffer.mapped !is null && buffer.memory != VK_NULL_HANDLE && _vk.vkUnmapMemory !is null)
            _vk.vkUnmapMemory(_device, buffer.memory);
        if (buffer.buffer != VK_NULL_HANDLE && _vk.vkDestroyBuffer !is null)
            _vk.vkDestroyBuffer(_device, buffer.buffer, null);
        if (buffer.memory != VK_NULL_HANDLE && _vk.vkFreeMemory !is null)
            _vk.vkFreeMemory(_device, buffer.memory, null);
        buffer = HostBuffer.init;
    }

    private void destroyAtlasImage()
    {
        if (_device !is null && _vk !is null)
        {
            if (_atlasView != VK_NULL_HANDLE && _vk.vkDestroyImageView !is null)
                _vk.vkDestroyImageView(_device, _atlasView, null);
            if (_atlasImage != VK_NULL_HANDLE && _vk.vkDestroyImage !is null)
                _vk.vkDestroyImage(_device, _atlasImage, null);
            if (_atlasMemory != VK_NULL_HANDLE && _vk.vkFreeMemory !is null)
                _vk.vkFreeMemory(_device, _atlasMemory, null);
        }
        _atlasView = VK_NULL_HANDLE;
        _atlasImage = VK_NULL_HANDLE;
        _atlasMemory = VK_NULL_HANDLE;
        _submittedAtlasRevision = 0;
        _submittedAtlasImage = VK_NULL_HANDLE;
        _atlasInitialized = false;
    }

    private void destroyImageTextures()
    {
        foreach (id, texture; _imageTextures)
            destroyGpuImageTexture(texture);
        _imageTextures = null;
    }

    private void destroyGpuImageTexture(GpuImageTexture texture)
    {
        if (texture is null) return;
        destroyHostBuffer(texture.staging);
        destroyGpuImageStorage(texture);
        texture.linearDescriptorSet = VK_NULL_HANDLE;
        texture.nearestDescriptorSet = VK_NULL_HANDLE;
    }

    private void destroyGpuImageStorage(GpuImageTexture texture)
    {
        if (texture is null) return;
        if (_device !is null && _vk !is null)
        {
            if (texture.view != VK_NULL_HANDLE && _vk.vkDestroyImageView !is null)
                _vk.vkDestroyImageView(_device, texture.view, null);
            if (texture.image != VK_NULL_HANDLE && _vk.vkDestroyImage !is null)
                _vk.vkDestroyImage(_device, texture.image, null);
            if (texture.memory != VK_NULL_HANDLE && _vk.vkFreeMemory !is null)
                _vk.vkFreeMemory(_device, texture.memory, null);
        }
        texture.view = VK_NULL_HANDLE;
        texture.image = VK_NULL_HANDLE;
        texture.memory = VK_NULL_HANDLE;
        texture.submittedRevision = 0;
        texture.initialized = false;
    }

    private void waitForSubmittedFrames()
    {
        if (_device is null || _vk is null || _vk.vkWaitForFences is null) return;
        foreach (ref frame; _frames)
        {
            if (frame.fence == VK_NULL_HANDLE) continue;
            check(_vk.vkWaitForFences(_device, 1, &frame.fence, VK_TRUE,
                ulong.max), "waiting for submitted Vulkan resize work");
        }
    }

    private void destroySwapchain()
    {
        destroySwapchainImages();
        destroyFormatResources();
    }

    private void destroySwapchainImages()
    {
        if (_device is null || _vk is null) return;
        destroyPresentSemaphores();
        foreach (framebuffer; _framebuffers)
            if (framebuffer != VK_NULL_HANDLE && _vk.vkDestroyFramebuffer !is null)
                _vk.vkDestroyFramebuffer(_device, framebuffer, null);
        _framebuffers.length = 0;
        foreach (view; _swapchainViews)
            if (view != VK_NULL_HANDLE && _vk.vkDestroyImageView !is null)
                _vk.vkDestroyImageView(_device, view, null);
        _swapchainViews.length = 0;
        _swapchainImages.length = 0;
        if (_swapchain != VK_NULL_HANDLE && _vk.vkDestroySwapchainKHR !is null)
            _vk.vkDestroySwapchainKHR(_device, _swapchain, null);
        _swapchain = VK_NULL_HANDLE;
        _frameCursor = 0;
    }

    private void destroyFormatResources()
    {
        if (_device is null || _vk is null) return;
        if (_pipeline != VK_NULL_HANDLE && _vk.vkDestroyPipeline !is null)
            _vk.vkDestroyPipeline(_device, _pipeline, null);
        _pipeline = VK_NULL_HANDLE;
        if (_imagePipeline != VK_NULL_HANDLE && _vk.vkDestroyPipeline !is null)
            _vk.vkDestroyPipeline(_device, _imagePipeline, null);
        _imagePipeline = VK_NULL_HANDLE;
        if (_renderPass != VK_NULL_HANDLE && _vk.vkDestroyRenderPass !is null)
            _vk.vkDestroyRenderPass(_device, _renderPass, null);
        _renderPass = VK_NULL_HANDLE;
    }

    private uint findMemoryType(uint allowedBits, VkFlags required) const
    {
        foreach (index; 0 .. _memoryProperties.memoryTypeCount)
        {
            if ((allowedBits & (1u << index)) != 0 &&
                (_memoryProperties.memoryTypes[index].propertyFlags & required) == required)
                return index;
        }
        throw new Exception("No Vulkan memory type satisfies flags 0x" ~ required.to!string);
    }

    private string[] enumerateInstanceExtensions()
    {
        uint count;
        check(_vk.vkEnumerateInstanceExtensionProperties(null, &count, null),
            "enumerating Vulkan instance extensions");
        VkExtensionProperties[] values;
        values.length = count;
        const result = _vk.vkEnumerateInstanceExtensionProperties(null, &count, values.ptr);
        if (result != VK_SUCCESS && result != VK_INCOMPLETE)
            check(result, "enumerating Vulkan instance extensions");
        string[] names;
        foreach (value; values) names ~= cString(value.extensionName[]);
        return names;
    }

    private string[] enumerateInstanceLayers()
    {
        uint count;
        const first = _vk.vkEnumerateInstanceLayerProperties(&count, null);
        if (first != VK_SUCCESS) return null;
        VkLayerProperties[] values;
        values.length = count;
        if (_vk.vkEnumerateInstanceLayerProperties(&count, values.ptr) != VK_SUCCESS) return null;
        string[] names;
        foreach (value; values) names ~= cString(value.layerName[]);
        return names;
    }

    private string[] enumerateDeviceExtensions(VkPhysicalDevice device)
    {
        uint count;
        const first = _vk.vkEnumerateDeviceExtensionProperties(device, null, &count, null);
        if (first != VK_SUCCESS) return null;
        VkExtensionProperties[] values;
        values.length = count;
        const result = _vk.vkEnumerateDeviceExtensionProperties(device, null, &count, values.ptr);
        if (result != VK_SUCCESS && result != VK_INCOMPLETE) return null;
        string[] names;
        foreach (value; values) names ~= cString(value.extensionName[]);
        return names;
    }

    private VkSurfaceFormatKHR[] surfaceFormats()
    {
        uint count;
        check(_vk.vkGetPhysicalDeviceSurfaceFormatsKHR(_physicalDevice, _surface, &count, null),
            "querying Vulkan surface formats");
        VkSurfaceFormatKHR[] values;
        values.length = count;
        check(_vk.vkGetPhysicalDeviceSurfaceFormatsKHR(_physicalDevice, _surface, &count, values.ptr),
            "querying Vulkan surface formats");
        return values;
    }

    private int[] presentModes()
    {
        uint count;
        check(_vk.vkGetPhysicalDeviceSurfacePresentModesKHR(_physicalDevice, _surface, &count, null),
            "querying Vulkan presentation modes");
        int[] values;
        values.length = count;
        check(_vk.vkGetPhysicalDeviceSurfacePresentModesKHR(_physicalDevice, _surface, &count, values.ptr),
            "querying Vulkan presentation modes");
        return values;
    }

    private static const(char)*[] makePointers(string[] values)
    {
        const(char)*[] result;
        result.reserve(values.length);
        foreach (value; values) result ~= toStringz(value);
        return result;
    }

    private static bool contains(string[] values, string requested)
    {
        foreach (value; values) if (value == requested) return true;
        return false;
    }

    private static void requireExtension(string[] available, string name)
    {
        if (!contains(available, name))
            throw new Exception("Vulkan instance extension is unavailable: " ~ name);
    }

    private static string cString(const(char)[] value)
    {
        size_t length;
        while (length < value.length && value[length] != 0) ++length;
        return value[0 .. length].idup;
    }

    private static uint clampUInt(uint value, uint low, uint high)
    {
        if (value < low) return low;
        if (value > high) return high;
        return value;
    }

    private static VkFlags chooseBit(VkFlags supported, VkFlags preferred)
    {
        if ((supported & preferred) != 0) return preferred;
        foreach (bit; 0 .. 32)
        {
            const value = 1u << bit;
            if ((supported & value) != 0) return value;
        }
        return preferred;
    }

    private static VkImageSubresourceRange colorRange()
    {
        return VkImageSubresourceRange(VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1);
    }

    private static void check(VkResult result, string operation)
    {
        if (result != VK_SUCCESS)
            throw new Exception("Vulkan failed while " ~ operation ~ ": " ~ vkResultName(result));
    }
}
