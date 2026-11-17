module marchingcubesgpu;

pragma(lib, "user32.lib");

import aurora.vulkan.api;
import mcmesh : MeshData, MeshVertex, buildTorusMesh;

import core.stdc.string : memcpy;
import core.thread : Thread;
import core.time : msecs;
import core.sys.windows.windows : CreateWindowExA, DefWindowProcA, DispatchMessageA,
    FindWindowA, GetCurrentProcessId, GetModuleHandleA, HINSTANCE, HWND, LPARAM,
    LRESULT, MSG, PeekMessageA, RegisterClassA, SW_SHOW, ShowWindow,
    TranslateMessage, UINT, WNDCLASSA, WPARAM, WS_CHILD, WS_VISIBLE;
import std.conv : to;
import std.file : exists, read, write;
import std.math : cos, sin, tan;
import std.path : buildPath;
import std.stdio : stderr, stdout;
import std.string : toStringz;

enum int Width = 360;
enum int Height = 240;
enum int ColorFormat = VK_FORMAT_R8G8B8A8_UNORM;
enum int DepthFormat = 126; // VK_FORMAT_D32_SFLOAT
enum int EventBytes = 24;
enum int EventCapacity = 64;
enum int SurfaceHeader = 80;

struct PushConstants
{
    float[16] mvp;
}

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
    VkBuffer readBuffer;
    VkDeviceMemory readMemory;
    CmdPushConstants pushConstants;
    CmdCopyImageToBuffer copyImageToBuffer;
    CmdCopyImage copyImage;
    int colorFormat = ColorFormat;
    VkSurfaceKHR surface;
    VkSwapchainKHR swapchain;
    VkImage[] swapImages;
    VkImageView[] swapViews;
    VkSemaphore acquireSemaphore;
    VkSemaphore presentSemaphore;
    VkExtent2D extent = VkExtent2D(Width, Height);
    VkPhysicalDeviceMemoryProperties memoryProperties;

    this()
    {
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
        if (pushConstants is null || copyImageToBuffer is null)
            throw new Exception("required Vulkan device entry points unavailable");
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
        auto mesh = buildTorusMesh();
        createBuffers(mesh);
        if (gChildWindow !is null) { stdout.writeln("vulkan3d: buffers"); stdout.flush(); }
        createCommands();
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
        info.presentMode = VK_PRESENT_MODE_FIFO_KHR;
        info.clipped = 1;
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

    private VkShaderModule shader(string path)
    {
        auto bytes = cast(ubyte[]) read(path);
        VkShaderModuleCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
        info.codeSize = bytes.length;
        info.pCode = cast(const(uint)*) bytes.ptr;
        VkShaderModule shaderModule;
        check(vk.vkCreateShaderModule(device, &info, null, &shaderModule),
            "creating shader module " ~ path);
        return shaderModule;
    }

    private void createPipeline()
    {
        auto vertex = shader("cube.vert.spv");
        auto fragment = shader("cube.frag.spv");
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
        binding.stride = 24;
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

    private void upload(VkDeviceMemory memory, const(void)[] data)
    {
        void* mapped;
        check(vk.vkMapMemory(device, memory, 0, data.length, 0, &mapped),
            "mapping buffer memory");
        memcpy(mapped, data.ptr, data.length);
        vk.vkUnmapMemory(device, memory);
    }

    private void createBuffers(MeshData mesh)
    {
        indexCount = cast(uint) mesh.indices.length;
        stdout.writeln("vulkan3d: mesh vertices=", mesh.vertices.length,
            " indices=", mesh.indices.length); stdout.flush();
        createBuffer(vertexBuffer, vertexMemory,
            cast(VkDeviceSize) mesh.vertices.length * MeshVertex.sizeof,
            VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        upload(vertexMemory, mesh.vertices);
        createBuffer(indexBuffer, indexMemory,
            cast(VkDeviceSize) mesh.indices.length * uint.sizeof,
            VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
        upload(indexMemory, mesh.indices);
        createBuffer(readBuffer, readMemory,
            cast(VkDeviceSize) Width * Height * 4,
            VK_BUFFER_USAGE_TRANSFER_DST_BIT);
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

    private float[16] matrix(double seconds)
    {
        const angle = cast(float) (seconds * 0.7);
        const c = cos(angle);
        const s = sin(angle);
        const aspect = cast(float) Width / Height;
        const f = 1.0f / cast(float) tan(3.14159265358979323846 / 6.0);
        const near = 0.1f;
        const far = 100.0f;
        const a = far / (near - far);
        const b = far * near / (near - far);
        float[16] m;
        m[0] = f / aspect * c;
        m[1] = 0;
        m[2] = -a * s;
        m[3] = s;
        m[4] = 0;
        m[5] = -f;
        m[6] = 0;
        m[7] = 0;
        m[8] = 0;
        m[8] = f / aspect * s;
        m[9] = 0;
        m[10] = a * c;
        m[11] = -c;
        m[12] = 0;
        m[13] = 0;
        m[14] = a * -4.0f + b;
        m[15] = 4.0f;
        return m;
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
        vk.vkCmdBindPipeline(commands, 0, pipeline);
        VkViewport viewport = VkViewport(0, 0, Width, Height, 0, 1);
        VkRect2D scissor = VkRect2D(VkOffset2D(0, 0),
            VkExtent2D(Width, Height));
        vk.vkCmdSetViewport(commands, 0, 1, &viewport);
        vk.vkCmdSetScissor(commands, 0, 1, &scissor);
        VkDeviceSize offset = 0;
        vk.vkCmdBindVertexBuffers(commands, 0, 1, &vertexBuffer, &offset);
        vk.vkCmdBindIndexBuffer(commands, indexBuffer, 0, VK_INDEX_TYPE_UINT32);
        auto matrix = this.matrix(seconds);
        pushConstants(commands, pipelineLayout, VK_SHADER_STAGE_VERTEX_BIT,
            0, 64, &matrix);
        vk.vkCmdDrawIndexed(commands, indexCount, 1, 0, 0, 0);
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

    private void pumpMessages()
    {
        MSG message;
        while (PeekMessageA(&message, null, 0, 0, 1))
        {
            TranslateMessage(&message);
            DispatchMessageA(&message);
        }
    }

    private void presentFrame(double seconds)
    {
        uint imageIndex;
        auto acquired = vk.vkAcquireNextImageKHR(device, swapchain, ulong.max,
            acquireSemaphore, VK_NULL_HANDLE, &imageIndex);
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
            VkExtent2D(Width, Height));
        pass.clearValueCount = 2;
        pass.pClearValues = clears.ptr;
        vk.vkCmdBeginRenderPass(commands, &pass, 1);
        vk.vkCmdBindPipeline(commands, 0, pipeline);
        VkViewport viewport = VkViewport(0, 0, Width, Height, 0, 1);
        VkRect2D scissor = VkRect2D(VkOffset2D(0, 0),
            VkExtent2D(Width, Height));
        vk.vkCmdSetViewport(commands, 0, 1, &viewport);
        vk.vkCmdSetScissor(commands, 0, 1, &scissor);
        VkDeviceSize offset = 0;
        vk.vkCmdBindVertexBuffers(commands, 0, 1, &vertexBuffer, &offset);
        vk.vkCmdBindIndexBuffer(commands, indexBuffer, 0, VK_INDEX_TYPE_UINT32);
        auto matrix = this.matrix(seconds);
        pushConstants(commands, pipelineLayout, VK_SHADER_STAGE_VERTEX_BIT,
            0, 64, &matrix);
        vk.vkCmdDrawIndexed(commands, indexCount, 1, 0, 0, 0);
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
        const copyWidth = Width < extent.width ? Width : extent.width;
        const copyHeight = Height < extent.height ? Height : extent.height;
        region.extent = VkExtent3D(copyWidth, copyHeight, 1);
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
            presentFrame(frame / 60.0);
            Thread.sleep(16.msecs);
        }
        vk.vkDeviceWaitIdle(device);
        stdout.writeln("PASS Vulkan 3D child swapchain hostPid=",
            GetCurrentProcessId(), " frames=", frames);
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

void main(string[] args)
{
    string shaderDir = ".";
    string output = "vulkan3d.ppm";
    string surfaceOutput;
    string hostTitle;
    double seconds = 0.7;
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
    }
    if (!exists(buildPath(shaderDir, "cube.vert.spv")))
        throw new Exception("missing cube.vert.spv in " ~ shaderDir);
    version (Windows)
    {
        import core.sys.windows.windows : SetCurrentDirectoryA;
        SetCurrentDirectoryA(toStringz(shaderDir));
    }
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
    }
    auto app = new App();
    if (hostTitle.length != 0)
        app.present(cast(int) seconds);
    else
        app.render(output, surfaceOutput, seconds);
}
