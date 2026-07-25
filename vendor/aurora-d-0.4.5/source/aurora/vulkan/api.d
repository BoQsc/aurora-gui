module aurora.vulkan.api;

/** Minimal Vulkan 1.0/WSI declarations used by Aurora. No binding package required. */

import core.stdc.config : c_ulong;
import std.string : toStringz;

alias VkFlags = uint;
alias VkBool32 = uint;
alias VkDeviceSize = ulong;
alias VkResult = int;
alias VkInstance = void*;
alias VkPhysicalDevice = void*;
alias VkDevice = void*;
alias VkQueue = void*;
alias VkCommandBuffer = void*;
alias VkSurfaceKHR = ulong;
alias VkSwapchainKHR = ulong;
alias VkImage = ulong;
alias VkImageView = ulong;
alias VkRenderPass = ulong;
alias VkShaderModule = ulong;
alias VkPipelineLayout = ulong;
alias VkPipeline = ulong;
alias VkFramebuffer = ulong;
alias VkCommandPool = ulong;
alias VkSemaphore = ulong;
alias VkFence = ulong;
alias VkBuffer = ulong;
alias VkDeviceMemory = ulong;
alias VkSampler = ulong;
alias VkDescriptorSetLayout = ulong;
alias VkDescriptorPool = ulong;
alias VkDescriptorSet = ulong;
alias VkPipelineCache = ulong;

enum ulong VK_NULL_HANDLE = 0;
enum uint VK_TRUE = 1;
enum uint VK_FALSE = 0;
enum uint VK_API_VERSION_1_0 = 0x00400000;
enum ulong VK_WHOLE_SIZE = ulong.max;

enum VkResult VK_SUCCESS = 0;
enum VkResult VK_NOT_READY = 1;
enum VkResult VK_TIMEOUT = 2;
enum VkResult VK_INCOMPLETE = 5;
enum VkResult VK_ERROR_OUT_OF_HOST_MEMORY = -1;
enum VkResult VK_ERROR_OUT_OF_DEVICE_MEMORY = -2;
enum VkResult VK_ERROR_INITIALIZATION_FAILED = -3;
enum VkResult VK_ERROR_DEVICE_LOST = -4;
enum VkResult VK_ERROR_EXTENSION_NOT_PRESENT = -7;
enum VkResult VK_ERROR_OUT_OF_DATE_KHR = -1000001004;
enum VkResult VK_SUBOPTIMAL_KHR = 1000001003;

enum int VK_STRUCTURE_TYPE_APPLICATION_INFO = 0;
enum int VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO = 1;
enum int VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO = 2;
enum int VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO = 3;
enum int VK_STRUCTURE_TYPE_SUBMIT_INFO = 4;
enum int VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO = 5;
enum int VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE = 6;
enum int VK_STRUCTURE_TYPE_FENCE_CREATE_INFO = 8;
enum int VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO = 9;
enum int VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO = 12;
enum int VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO = 14;
enum int VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO = 15;
enum int VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO = 16;
enum int VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO = 18;
enum int VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO = 19;
enum int VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO = 20;
enum int VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO = 22;
enum int VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO = 23;
enum int VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO = 24;
enum int VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO = 26;
enum int VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO = 27;
enum int VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO = 28;
enum int VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO = 30;
enum int VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO = 31;
enum int VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO = 32;
enum int VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO = 33;
enum int VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO = 34;
enum int VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET = 35;
enum int VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO = 37;
enum int VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO = 38;
enum int VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO = 39;
enum int VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO = 40;
enum int VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO = 42;
enum int VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO = 43;
enum int VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER = 45;
enum int VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR = 1000001000;
enum int VK_STRUCTURE_TYPE_PRESENT_INFO_KHR = 1000001001;
enum int VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR = 1000004000;
enum int VK_STRUCTURE_TYPE_XCB_SURFACE_CREATE_INFO_KHR = 1000005000;
enum int VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR = 1000009000;
enum int VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT = 1000217000;

enum uint VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR = 0x00000001;
enum uint VK_QUEUE_GRAPHICS_BIT = 0x00000001;
enum uint VK_IMAGE_USAGE_TRANSFER_DST_BIT = 0x00000002;
enum uint VK_IMAGE_USAGE_SAMPLED_BIT = 0x00000004;
enum uint VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT = 0x00000010;
enum uint VK_BUFFER_USAGE_TRANSFER_SRC_BIT = 0x00000001;
enum uint VK_BUFFER_USAGE_TRANSFER_DST_BIT = 0x00000002;
enum uint VK_BUFFER_USAGE_INDEX_BUFFER_BIT = 0x00000040;
enum uint VK_BUFFER_USAGE_VERTEX_BUFFER_BIT = 0x00000080;
enum uint VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT = 0x00000001;
enum uint VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT = 0x00000002;
enum uint VK_MEMORY_PROPERTY_HOST_COHERENT_BIT = 0x00000004;
enum uint VK_IMAGE_ASPECT_COLOR_BIT = 0x00000001;
enum uint VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT = 0x00000001;
enum uint VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT = 0x00000080;
enum uint VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT = 0x00000400;
enum uint VK_PIPELINE_STAGE_TRANSFER_BIT = 0x00001000;
enum uint VK_ACCESS_SHADER_READ_BIT = 0x00000020;
enum uint VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT = 0x00000100;
enum uint VK_ACCESS_TRANSFER_WRITE_BIT = 0x00001000;
enum uint VK_COLOR_COMPONENT_R_BIT = 0x1;
enum uint VK_COLOR_COMPONENT_G_BIT = 0x2;
enum uint VK_COLOR_COMPONENT_B_BIT = 0x4;
enum uint VK_COLOR_COMPONENT_A_BIT = 0x8;
enum uint VK_SHADER_STAGE_VERTEX_BIT = 0x00000001;
enum uint VK_SHADER_STAGE_FRAGMENT_BIT = 0x00000010;
enum uint VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT = 0x00000002;
enum uint VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT = 0x00000001;
enum uint VK_FENCE_CREATE_SIGNALED_BIT = 0x00000001;
enum uint VK_DEPENDENCY_BY_REGION_BIT = 0x00000001;

enum int VK_FORMAT_UNDEFINED = 0;
enum int VK_FORMAT_R8_UNORM = 9;
enum int VK_FORMAT_R32G32_SFLOAT = 103;
enum int VK_FORMAT_R32G32B32A32_SFLOAT = 109;
enum int VK_FORMAT_R8G8B8A8_UNORM = 37;
enum int VK_FORMAT_B8G8R8A8_UNORM = 44;
enum int VK_COLOR_SPACE_SRGB_NONLINEAR_KHR = 0;
enum int VK_PRESENT_MODE_IMMEDIATE_KHR = 0;
enum int VK_PRESENT_MODE_MAILBOX_KHR = 1;
enum int VK_PRESENT_MODE_FIFO_KHR = 2;
enum int VK_PRESENT_MODE_FIFO_RELAXED_KHR = 3;
enum int VK_SHARING_MODE_EXCLUSIVE = 0;
enum int VK_SHARING_MODE_CONCURRENT = 1;
enum uint VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR = 0x1;
enum uint VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR = 0x1;
enum int VK_IMAGE_TYPE_2D = 1;
enum int VK_IMAGE_VIEW_TYPE_2D = 1;
enum int VK_IMAGE_TILING_OPTIMAL = 0;
enum int VK_IMAGE_LAYOUT_UNDEFINED = 0;
enum int VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL = 2;
enum int VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL = 5;
enum int VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL = 7;
enum int VK_IMAGE_LAYOUT_PRESENT_SRC_KHR = 1000001002;
enum int VK_COMPONENT_SWIZZLE_IDENTITY = 0;
enum int VK_ATTACHMENT_LOAD_OP_LOAD = 0;
enum int VK_ATTACHMENT_LOAD_OP_CLEAR = 1;
enum int VK_ATTACHMENT_LOAD_OP_DONT_CARE = 2;
enum int VK_ATTACHMENT_STORE_OP_STORE = 0;
enum int VK_ATTACHMENT_STORE_OP_DONT_CARE = 1;
enum uint VK_SAMPLE_COUNT_1_BIT = 1;
enum int VK_PIPELINE_BIND_POINT_GRAPHICS = 0;
enum uint VK_SUBPASS_EXTERNAL = 0xffffffff;
enum int VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST = 3;
enum int VK_POLYGON_MODE_FILL = 0;
enum int VK_FRONT_FACE_COUNTER_CLOCKWISE = 0;
enum int VK_COMPARE_OP_ALWAYS = 7;
enum int VK_LOGIC_OP_COPY = 3;
enum int VK_BLEND_FACTOR_ZERO = 0;
enum int VK_BLEND_FACTOR_ONE = 1;
enum int VK_BLEND_FACTOR_SRC_ALPHA = 6;
enum int VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA = 7;
enum int VK_BLEND_OP_ADD = 0;
enum int VK_DYNAMIC_STATE_VIEWPORT = 0;
enum int VK_DYNAMIC_STATE_SCISSOR = 1;
enum int VK_VERTEX_INPUT_RATE_VERTEX = 0;
enum int VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER = 1;
enum int VK_FILTER_NEAREST = 0;
enum int VK_FILTER_LINEAR = 1;
enum int VK_SAMPLER_MIPMAP_MODE_NEAREST = 0;
enum int VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE = 2;
enum int VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK = 0;
enum int VK_COMMAND_BUFFER_LEVEL_PRIMARY = 0;
enum int VK_INDEX_TYPE_UINT32 = 1;

struct VkExtent2D { uint width; uint height; }
struct VkOffset2D { int x; int y; }
struct VkRect2D { VkOffset2D offset; VkExtent2D extent; }
struct VkExtent3D { uint width; uint height; uint depth; }
struct VkOffset3D { int x; int y; int z; }
struct VkViewport { float x; float y; float width; float height; float minDepth; float maxDepth; }

struct VkApplicationInfo
{
    int sType;
    const(void)* pNext;
    const(char)* pApplicationName;
    uint applicationVersion;
    const(char)* pEngineName;
    uint engineVersion;
    uint apiVersion;
}

struct VkInstanceCreateInfo
{
    int sType;
    const(void)* pNext;
    VkFlags flags;
    const(VkApplicationInfo)* pApplicationInfo;
    uint enabledLayerCount;
    const(char*)* ppEnabledLayerNames;
    uint enabledExtensionCount;
    const(char*)* ppEnabledExtensionNames;
}

struct VkExtensionProperties { char[256] extensionName; uint specVersion; }
struct VkLayerProperties { char[256] layerName; uint specVersion; uint implementationVersion; char[256] description; }

struct VkXlibSurfaceCreateInfoKHR
{
    int sType; const(void)* pNext; VkFlags flags; void* dpy; c_ulong window;
}
struct VkXcbSurfaceCreateInfoKHR
{
    int sType; const(void)* pNext; VkFlags flags; void* connection; uint window;
}
struct VkWin32SurfaceCreateInfoKHR
{
    int sType; const(void)* pNext; VkFlags flags; void* hinstance; void* hwnd;
}
struct VkMetalSurfaceCreateInfoEXT
{
    int sType; const(void)* pNext; VkFlags flags; const(void)* pLayer;
}

struct VkQueueFamilyProperties
{
    VkFlags queueFlags;
    uint queueCount;
    uint timestampValidBits;
    VkExtent3D minImageTransferGranularity;
}

struct VkDeviceQueueCreateInfo
{
    int sType; const(void)* pNext; VkFlags flags; uint queueFamilyIndex;
    uint queueCount; const(float)* pQueuePriorities;
}

struct VkDeviceCreateInfo
{
    int sType; const(void)* pNext; VkFlags flags;
    uint queueCreateInfoCount; const(VkDeviceQueueCreateInfo)* pQueueCreateInfos;
    uint enabledLayerCount; const(char*)* ppEnabledLayerNames;
    uint enabledExtensionCount; const(char*)* ppEnabledExtensionNames;
    const(void)* pEnabledFeatures;
}

struct VkMemoryType { VkFlags propertyFlags; uint heapIndex; }
struct VkMemoryHeap { VkDeviceSize size; VkFlags flags; }
struct VkPhysicalDeviceMemoryProperties
{
    uint memoryTypeCount;
    VkMemoryType[32] memoryTypes;
    uint memoryHeapCount;
    VkMemoryHeap[16] memoryHeaps;
}

struct VkSurfaceCapabilitiesKHR
{
    uint minImageCount;
    uint maxImageCount;
    VkExtent2D currentExtent;
    VkExtent2D minImageExtent;
    VkExtent2D maxImageExtent;
    uint maxImageArrayLayers;
    VkFlags supportedTransforms;
    VkFlags currentTransform;
    VkFlags supportedCompositeAlpha;
    VkFlags supportedUsageFlags;
}

struct VkSurfaceFormatKHR { int format; int colorSpace; }

struct VkSwapchainCreateInfoKHR
{
    int sType; const(void)* pNext; VkFlags flags; VkSurfaceKHR surface;
    uint minImageCount; int imageFormat; int imageColorSpace; VkExtent2D imageExtent;
    uint imageArrayLayers; VkFlags imageUsage; int imageSharingMode;
    uint queueFamilyIndexCount; const(uint)* pQueueFamilyIndices;
    VkFlags preTransform; VkFlags compositeAlpha; int presentMode; VkBool32 clipped;
    VkSwapchainKHR oldSwapchain;
}

struct VkComponentMapping { int r; int g; int b; int a; }
struct VkImageSubresourceRange
{
    VkFlags aspectMask; uint baseMipLevel; uint levelCount; uint baseArrayLayer; uint layerCount;
}
struct VkImageViewCreateInfo
{
    int sType; const(void)* pNext; VkFlags flags; VkImage image; int viewType; int format;
    VkComponentMapping components; VkImageSubresourceRange subresourceRange;
}

struct VkAttachmentDescription
{
    VkFlags flags; int format; VkFlags samples; int loadOp; int storeOp;
    int stencilLoadOp; int stencilStoreOp; int initialLayout; int finalLayout;
}
struct VkAttachmentReference { uint attachment; int layout; }
struct VkSubpassDescription
{
    VkFlags flags; int pipelineBindPoint; uint inputAttachmentCount;
    const(VkAttachmentReference)* pInputAttachments; uint colorAttachmentCount;
    const(VkAttachmentReference)* pColorAttachments;
    const(VkAttachmentReference)* pResolveAttachments;
    const(VkAttachmentReference)* pDepthStencilAttachment;
    uint preserveAttachmentCount; const(uint)* pPreserveAttachments;
}
struct VkSubpassDependency
{
    uint srcSubpass; uint dstSubpass; VkFlags srcStageMask; VkFlags dstStageMask;
    VkFlags srcAccessMask; VkFlags dstAccessMask; VkFlags dependencyFlags;
}
struct VkRenderPassCreateInfo
{
    int sType; const(void)* pNext; VkFlags flags; uint attachmentCount;
    const(VkAttachmentDescription)* pAttachments; uint subpassCount;
    const(VkSubpassDescription)* pSubpasses; uint dependencyCount;
    const(VkSubpassDependency)* pDependencies;
}

struct VkShaderModuleCreateInfo
{
    int sType; const(void)* pNext; VkFlags flags; size_t codeSize; const(uint)* pCode;
}
struct VkPipelineShaderStageCreateInfo
{
    int sType; const(void)* pNext; VkFlags flags; VkFlags stage; VkShaderModule module_;
    const(char)* pName; const(void)* pSpecializationInfo;
}
struct VkVertexInputBindingDescription { uint binding; uint stride; int inputRate; }
struct VkVertexInputAttributeDescription { uint location; uint binding; int format; uint offset; }
struct VkPipelineVertexInputStateCreateInfo
{
    int sType; const(void)* pNext; VkFlags flags; uint vertexBindingDescriptionCount;
    const(VkVertexInputBindingDescription)* pVertexBindingDescriptions;
    uint vertexAttributeDescriptionCount;
    const(VkVertexInputAttributeDescription)* pVertexAttributeDescriptions;
}
struct VkPipelineInputAssemblyStateCreateInfo
{
    int sType; const(void)* pNext; VkFlags flags; int topology; VkBool32 primitiveRestartEnable;
}
struct VkPipelineViewportStateCreateInfo
{
    int sType; const(void)* pNext; VkFlags flags; uint viewportCount;
    const(VkViewport)* pViewports; uint scissorCount; const(VkRect2D)* pScissors;
}
struct VkPipelineRasterizationStateCreateInfo
{
    int sType; const(void)* pNext; VkFlags flags; VkBool32 depthClampEnable;
    VkBool32 rasterizerDiscardEnable; int polygonMode; VkFlags cullMode; int frontFace;
    VkBool32 depthBiasEnable; float depthBiasConstantFactor; float depthBiasClamp;
    float depthBiasSlopeFactor; float lineWidth;
}
struct VkPipelineMultisampleStateCreateInfo
{
    int sType; const(void)* pNext; VkFlags flags; VkFlags rasterizationSamples;
    VkBool32 sampleShadingEnable; float minSampleShading; const(uint)* pSampleMask;
    VkBool32 alphaToCoverageEnable; VkBool32 alphaToOneEnable;
}
struct VkPipelineColorBlendAttachmentState
{
    VkBool32 blendEnable; int srcColorBlendFactor; int dstColorBlendFactor;
    int colorBlendOp; int srcAlphaBlendFactor; int dstAlphaBlendFactor;
    int alphaBlendOp; VkFlags colorWriteMask;
}
struct VkPipelineColorBlendStateCreateInfo
{
    int sType; const(void)* pNext; VkFlags flags; VkBool32 logicOpEnable;
    int logicOp; uint attachmentCount; const(VkPipelineColorBlendAttachmentState)* pAttachments;
    float[4] blendConstants;
}
struct VkPipelineDynamicStateCreateInfo
{
    int sType; const(void)* pNext; VkFlags flags; uint dynamicStateCount; const(int)* pDynamicStates;
}
struct VkDescriptorSetLayoutBinding
{
    uint binding; int descriptorType; uint descriptorCount; VkFlags stageFlags;
    const(VkSampler)* pImmutableSamplers;
}
struct VkDescriptorSetLayoutCreateInfo
{
    int sType; const(void)* pNext; VkFlags flags; uint bindingCount;
    const(VkDescriptorSetLayoutBinding)* pBindings;
}
struct VkPipelineLayoutCreateInfo
{
    int sType; const(void)* pNext; VkFlags flags; uint setLayoutCount;
    const(VkDescriptorSetLayout)* pSetLayouts; uint pushConstantRangeCount;
    const(void)* pPushConstantRanges;
}
struct VkGraphicsPipelineCreateInfo
{
    int sType; const(void)* pNext; VkFlags flags; uint stageCount;
    const(VkPipelineShaderStageCreateInfo)* pStages;
    const(VkPipelineVertexInputStateCreateInfo)* pVertexInputState;
    const(VkPipelineInputAssemblyStateCreateInfo)* pInputAssemblyState;
    const(void)* pTessellationState; const(VkPipelineViewportStateCreateInfo)* pViewportState;
    const(VkPipelineRasterizationStateCreateInfo)* pRasterizationState;
    const(VkPipelineMultisampleStateCreateInfo)* pMultisampleState;
    const(void)* pDepthStencilState; const(VkPipelineColorBlendStateCreateInfo)* pColorBlendState;
    const(VkPipelineDynamicStateCreateInfo)* pDynamicState; VkPipelineLayout layout;
    VkRenderPass renderPass; uint subpass; VkPipeline basePipelineHandle; int basePipelineIndex;
}

struct VkFramebufferCreateInfo
{
    int sType; const(void)* pNext; VkFlags flags; VkRenderPass renderPass;
    uint attachmentCount; const(VkImageView)* pAttachments; uint width; uint height; uint layers;
}
struct VkCommandPoolCreateInfo
{
    int sType; const(void)* pNext; VkFlags flags; uint queueFamilyIndex;
}
struct VkCommandBufferAllocateInfo
{
    int sType; const(void)* pNext; VkCommandPool commandPool; int level; uint commandBufferCount;
}
struct VkCommandBufferBeginInfo
{
    int sType; const(void)* pNext; VkFlags flags; const(void)* pInheritanceInfo;
}

union VkClearColorValue
{
    float[4] float32;
    int[4] int32;
    uint[4] uint32;
}
struct VkClearDepthStencilValue { float depth; uint stencil; }
union VkClearValue
{
    VkClearColorValue color;
    VkClearDepthStencilValue depthStencil;
}
struct VkRenderPassBeginInfo
{
    int sType; const(void)* pNext; VkRenderPass renderPass; VkFramebuffer framebuffer;
    VkRect2D renderArea; uint clearValueCount; const(VkClearValue)* pClearValues;
}

struct VkBufferCreateInfo
{
    int sType; const(void)* pNext; VkFlags flags; VkDeviceSize size; VkFlags usage;
    int sharingMode; uint queueFamilyIndexCount; const(uint)* pQueueFamilyIndices;
}
struct VkMemoryRequirements
{
    VkDeviceSize size; VkDeviceSize alignment; uint memoryTypeBits;
}
struct VkMemoryAllocateInfo
{
    int sType; const(void)* pNext; VkDeviceSize allocationSize; uint memoryTypeIndex;
}
struct VkMappedMemoryRange
{
    int sType; const(void)* pNext; VkDeviceMemory memory; VkDeviceSize offset; VkDeviceSize size;
}

struct VkImageCreateInfo
{
    int sType; const(void)* pNext; VkFlags flags; int imageType; int format;
    VkExtent3D extent; uint mipLevels; uint arrayLayers; VkFlags samples; int tiling;
    VkFlags usage; int sharingMode; uint queueFamilyIndexCount;
    const(uint)* pQueueFamilyIndices; int initialLayout;
}
struct VkImageSubresourceLayers
{
    VkFlags aspectMask; uint mipLevel; uint baseArrayLayer; uint layerCount;
}
struct VkBufferImageCopy
{
    VkDeviceSize bufferOffset; uint bufferRowLength; uint bufferImageHeight;
    VkImageSubresourceLayers imageSubresource; VkOffset3D imageOffset; VkExtent3D imageExtent;
}
struct VkImageMemoryBarrier
{
    int sType; const(void)* pNext; VkFlags srcAccessMask; VkFlags dstAccessMask;
    int oldLayout; int newLayout; uint srcQueueFamilyIndex; uint dstQueueFamilyIndex;
    VkImage image; VkImageSubresourceRange subresourceRange;
}

struct VkSamplerCreateInfo
{
    int sType; const(void)* pNext; VkFlags flags; int magFilter; int minFilter;
    int mipmapMode; int addressModeU; int addressModeV; int addressModeW;
    float mipLodBias; VkBool32 anisotropyEnable; float maxAnisotropy;
    VkBool32 compareEnable; int compareOp; float minLod; float maxLod;
    int borderColor; VkBool32 unnormalizedCoordinates;
}
struct VkDescriptorPoolSize { int type; uint descriptorCount; }
struct VkDescriptorPoolCreateInfo
{
    int sType; const(void)* pNext; VkFlags flags; uint maxSets;
    uint poolSizeCount; const(VkDescriptorPoolSize)* pPoolSizes;
}
struct VkDescriptorSetAllocateInfo
{
    int sType; const(void)* pNext; VkDescriptorPool descriptorPool;
    uint descriptorSetCount; const(VkDescriptorSetLayout)* pSetLayouts;
}
struct VkDescriptorImageInfo { VkSampler sampler; VkImageView imageView; int imageLayout; }
struct VkWriteDescriptorSet
{
    int sType; const(void)* pNext; VkDescriptorSet dstSet; uint dstBinding;
    uint dstArrayElement; uint descriptorCount; int descriptorType;
    const(VkDescriptorImageInfo)* pImageInfo; const(void)* pBufferInfo;
    const(void)* pTexelBufferView;
}

struct VkSemaphoreCreateInfo { int sType; const(void)* pNext; VkFlags flags; }
struct VkFenceCreateInfo { int sType; const(void)* pNext; VkFlags flags; }
struct VkSubmitInfo
{
    int sType; const(void)* pNext; uint waitSemaphoreCount;
    const(VkSemaphore)* pWaitSemaphores; const(VkFlags)* pWaitDstStageMask;
    uint commandBufferCount; const(VkCommandBuffer)* pCommandBuffers;
    uint signalSemaphoreCount; const(VkSemaphore)* pSignalSemaphores;
}
struct VkPresentInfoKHR
{
    int sType; const(void)* pNext; uint waitSemaphoreCount;
    const(VkSemaphore)* pWaitSemaphores; uint swapchainCount;
    const(VkSwapchainKHR)* pSwapchains; const(uint)* pImageIndices; VkResult* pResults;
}

alias PFN_vkVoidFunction = extern(System) void function();
alias PFN_vkGetInstanceProcAddr = extern(System) PFN_vkVoidFunction function(VkInstance, const(char)*);
alias PFN_vkGetDeviceProcAddr = extern(System) PFN_vkVoidFunction function(VkDevice, const(char)*);
alias PFN_vkCreateInstance = extern(System) VkResult function(const(VkInstanceCreateInfo)*, const(void)*, VkInstance*);
alias PFN_vkEnumerateInstanceExtensionProperties = extern(System) VkResult function(const(char)*, uint*, VkExtensionProperties*);
alias PFN_vkEnumerateInstanceLayerProperties = extern(System) VkResult function(uint*, VkLayerProperties*);
alias PFN_vkDestroyInstance = extern(System) void function(VkInstance, const(void)*);
alias PFN_vkCreateXlibSurfaceKHR = extern(System) VkResult function(VkInstance, const(VkXlibSurfaceCreateInfoKHR)*, const(void)*, VkSurfaceKHR*);
alias PFN_vkCreateXcbSurfaceKHR = extern(System) VkResult function(VkInstance, const(VkXcbSurfaceCreateInfoKHR)*, const(void)*, VkSurfaceKHR*);
alias PFN_vkCreateWin32SurfaceKHR = extern(System) VkResult function(VkInstance, const(VkWin32SurfaceCreateInfoKHR)*, const(void)*, VkSurfaceKHR*);
alias PFN_vkCreateMetalSurfaceEXT = extern(System) VkResult function(VkInstance, const(VkMetalSurfaceCreateInfoEXT)*, const(void)*, VkSurfaceKHR*);
alias PFN_vkDestroySurfaceKHR = extern(System) void function(VkInstance, VkSurfaceKHR, const(void)*);
alias PFN_vkEnumeratePhysicalDevices = extern(System) VkResult function(VkInstance, uint*, VkPhysicalDevice*);
alias PFN_vkGetPhysicalDeviceQueueFamilyProperties = extern(System) void function(VkPhysicalDevice, uint*, VkQueueFamilyProperties*);
alias PFN_vkGetPhysicalDeviceSurfaceSupportKHR = extern(System) VkResult function(VkPhysicalDevice, uint, VkSurfaceKHR, VkBool32*);
alias PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR = extern(System) VkResult function(VkPhysicalDevice, VkSurfaceKHR, VkSurfaceCapabilitiesKHR*);
alias PFN_vkGetPhysicalDeviceSurfaceFormatsKHR = extern(System) VkResult function(VkPhysicalDevice, VkSurfaceKHR, uint*, VkSurfaceFormatKHR*);
alias PFN_vkGetPhysicalDeviceSurfacePresentModesKHR = extern(System) VkResult function(VkPhysicalDevice, VkSurfaceKHR, uint*, int*);
alias PFN_vkEnumerateDeviceExtensionProperties = extern(System) VkResult function(VkPhysicalDevice, const(char)*, uint*, VkExtensionProperties*);
alias PFN_vkGetPhysicalDeviceMemoryProperties = extern(System) void function(VkPhysicalDevice, VkPhysicalDeviceMemoryProperties*);
alias PFN_vkCreateDevice = extern(System) VkResult function(VkPhysicalDevice, const(VkDeviceCreateInfo)*, const(void)*, VkDevice*);
alias PFN_vkDestroyDevice = extern(System) void function(VkDevice, const(void)*);
alias PFN_vkGetDeviceQueue = extern(System) void function(VkDevice, uint, uint, VkQueue*);
alias PFN_vkDeviceWaitIdle = extern(System) VkResult function(VkDevice);
alias PFN_vkQueueWaitIdle = extern(System) VkResult function(VkQueue);
alias PFN_vkCreateSwapchainKHR = extern(System) VkResult function(VkDevice, const(VkSwapchainCreateInfoKHR)*, const(void)*, VkSwapchainKHR*);
alias PFN_vkDestroySwapchainKHR = extern(System) void function(VkDevice, VkSwapchainKHR, const(void)*);
alias PFN_vkGetSwapchainImagesKHR = extern(System) VkResult function(VkDevice, VkSwapchainKHR, uint*, VkImage*);
alias PFN_vkAcquireNextImageKHR = extern(System) VkResult function(VkDevice, VkSwapchainKHR, ulong, VkSemaphore, VkFence, uint*);
alias PFN_vkQueuePresentKHR = extern(System) VkResult function(VkQueue, const(VkPresentInfoKHR)*);
alias PFN_vkCreateImageView = extern(System) VkResult function(VkDevice, const(VkImageViewCreateInfo)*, const(void)*, VkImageView*);
alias PFN_vkDestroyImageView = extern(System) void function(VkDevice, VkImageView, const(void)*);
alias PFN_vkCreateRenderPass = extern(System) VkResult function(VkDevice, const(VkRenderPassCreateInfo)*, const(void)*, VkRenderPass*);
alias PFN_vkDestroyRenderPass = extern(System) void function(VkDevice, VkRenderPass, const(void)*);
alias PFN_vkCreateShaderModule = extern(System) VkResult function(VkDevice, const(VkShaderModuleCreateInfo)*, const(void)*, VkShaderModule*);
alias PFN_vkDestroyShaderModule = extern(System) void function(VkDevice, VkShaderModule, const(void)*);
alias PFN_vkCreateDescriptorSetLayout = extern(System) VkResult function(VkDevice, const(VkDescriptorSetLayoutCreateInfo)*, const(void)*, VkDescriptorSetLayout*);
alias PFN_vkDestroyDescriptorSetLayout = extern(System) void function(VkDevice, VkDescriptorSetLayout, const(void)*);
alias PFN_vkCreatePipelineLayout = extern(System) VkResult function(VkDevice, const(VkPipelineLayoutCreateInfo)*, const(void)*, VkPipelineLayout*);
alias PFN_vkDestroyPipelineLayout = extern(System) void function(VkDevice, VkPipelineLayout, const(void)*);
alias PFN_vkCreateGraphicsPipelines = extern(System) VkResult function(VkDevice, VkPipelineCache, uint, const(VkGraphicsPipelineCreateInfo)*, const(void)*, VkPipeline*);
alias PFN_vkDestroyPipeline = extern(System) void function(VkDevice, VkPipeline, const(void)*);
alias PFN_vkCreateFramebuffer = extern(System) VkResult function(VkDevice, const(VkFramebufferCreateInfo)*, const(void)*, VkFramebuffer*);
alias PFN_vkDestroyFramebuffer = extern(System) void function(VkDevice, VkFramebuffer, const(void)*);
alias PFN_vkCreateCommandPool = extern(System) VkResult function(VkDevice, const(VkCommandPoolCreateInfo)*, const(void)*, VkCommandPool*);
alias PFN_vkDestroyCommandPool = extern(System) void function(VkDevice, VkCommandPool, const(void)*);
alias PFN_vkAllocateCommandBuffers = extern(System) VkResult function(VkDevice, const(VkCommandBufferAllocateInfo)*, VkCommandBuffer*);
alias PFN_vkResetCommandBuffer = extern(System) VkResult function(VkCommandBuffer, VkFlags);
alias PFN_vkBeginCommandBuffer = extern(System) VkResult function(VkCommandBuffer, const(VkCommandBufferBeginInfo)*);
alias PFN_vkEndCommandBuffer = extern(System) VkResult function(VkCommandBuffer);
alias PFN_vkCmdBeginRenderPass = extern(System) void function(VkCommandBuffer, const(VkRenderPassBeginInfo)*, int);
alias PFN_vkCmdEndRenderPass = extern(System) void function(VkCommandBuffer);
alias PFN_vkCmdBindPipeline = extern(System) void function(VkCommandBuffer, int, VkPipeline);
alias PFN_vkCmdSetViewport = extern(System) void function(VkCommandBuffer, uint, uint, const(VkViewport)*);
alias PFN_vkCmdSetScissor = extern(System) void function(VkCommandBuffer, uint, uint, const(VkRect2D)*);
alias PFN_vkCmdBindVertexBuffers = extern(System) void function(VkCommandBuffer, uint, uint, const(VkBuffer)*, const(VkDeviceSize)*);
alias PFN_vkCmdBindIndexBuffer = extern(System) void function(VkCommandBuffer, VkBuffer, VkDeviceSize, int);
alias PFN_vkCmdBindDescriptorSets = extern(System) void function(VkCommandBuffer, int, VkPipelineLayout, uint, uint, const(VkDescriptorSet)*, uint, const(uint)*);
alias PFN_vkCmdDrawIndexed = extern(System) void function(VkCommandBuffer, uint, uint, uint, int, uint);
alias PFN_vkCreateSemaphore = extern(System) VkResult function(VkDevice, const(VkSemaphoreCreateInfo)*, const(void)*, VkSemaphore*);
alias PFN_vkDestroySemaphore = extern(System) void function(VkDevice, VkSemaphore, const(void)*);
alias PFN_vkCreateFence = extern(System) VkResult function(VkDevice, const(VkFenceCreateInfo)*, const(void)*, VkFence*);
alias PFN_vkDestroyFence = extern(System) void function(VkDevice, VkFence, const(void)*);
alias PFN_vkWaitForFences = extern(System) VkResult function(VkDevice, uint, const(VkFence)*, VkBool32, ulong);
alias PFN_vkGetFenceStatus = extern(System) VkResult function(VkDevice, VkFence);
alias PFN_vkResetFences = extern(System) VkResult function(VkDevice, uint, const(VkFence)*);
alias PFN_vkQueueSubmit = extern(System) VkResult function(VkQueue, uint, const(VkSubmitInfo)*, VkFence);
alias PFN_vkCreateBuffer = extern(System) VkResult function(VkDevice, const(VkBufferCreateInfo)*, const(void)*, VkBuffer*);
alias PFN_vkDestroyBuffer = extern(System) void function(VkDevice, VkBuffer, const(void)*);
alias PFN_vkGetBufferMemoryRequirements = extern(System) void function(VkDevice, VkBuffer, VkMemoryRequirements*);
alias PFN_vkAllocateMemory = extern(System) VkResult function(VkDevice, const(VkMemoryAllocateInfo)*, const(void)*, VkDeviceMemory*);
alias PFN_vkFreeMemory = extern(System) void function(VkDevice, VkDeviceMemory, const(void)*);
alias PFN_vkBindBufferMemory = extern(System) VkResult function(VkDevice, VkBuffer, VkDeviceMemory, VkDeviceSize);
alias PFN_vkMapMemory = extern(System) VkResult function(VkDevice, VkDeviceMemory, VkDeviceSize, VkDeviceSize, VkFlags, void**);
alias PFN_vkUnmapMemory = extern(System) void function(VkDevice, VkDeviceMemory);
alias PFN_vkFlushMappedMemoryRanges = extern(System) VkResult function(VkDevice, uint, const(VkMappedMemoryRange)*);
alias PFN_vkCreateImage = extern(System) VkResult function(VkDevice, const(VkImageCreateInfo)*, const(void)*, VkImage*);
alias PFN_vkDestroyImage = extern(System) void function(VkDevice, VkImage, const(void)*);
alias PFN_vkGetImageMemoryRequirements = extern(System) void function(VkDevice, VkImage, VkMemoryRequirements*);
alias PFN_vkBindImageMemory = extern(System) VkResult function(VkDevice, VkImage, VkDeviceMemory, VkDeviceSize);
alias PFN_vkCmdPipelineBarrier = extern(System) void function(VkCommandBuffer, VkFlags, VkFlags, VkFlags, uint, const(void)*, uint, const(void)*, uint, const(VkImageMemoryBarrier)*);
alias PFN_vkCmdCopyBufferToImage = extern(System) void function(VkCommandBuffer, VkBuffer, VkImage, int, uint, const(VkBufferImageCopy)*);
alias PFN_vkCreateSampler = extern(System) VkResult function(VkDevice, const(VkSamplerCreateInfo)*, const(void)*, VkSampler*);
alias PFN_vkDestroySampler = extern(System) void function(VkDevice, VkSampler, const(void)*);
alias PFN_vkCreateDescriptorPool = extern(System) VkResult function(VkDevice, const(VkDescriptorPoolCreateInfo)*, const(void)*, VkDescriptorPool*);
alias PFN_vkDestroyDescriptorPool = extern(System) void function(VkDevice, VkDescriptorPool, const(void)*);
alias PFN_vkAllocateDescriptorSets = extern(System) VkResult function(VkDevice, const(VkDescriptorSetAllocateInfo)*, VkDescriptorSet*);
alias PFN_vkUpdateDescriptorSets = extern(System) void function(VkDevice, uint, const(VkWriteDescriptorSet)*, uint, const(void)*);

/** Runtime-loaded Vulkan entry points. */
final class VulkanApi
{
    private void* _library;
    PFN_vkGetInstanceProcAddr vkGetInstanceProcAddr;
    PFN_vkGetDeviceProcAddr vkGetDeviceProcAddr;
    PFN_vkCreateInstance vkCreateInstance;
    PFN_vkEnumerateInstanceExtensionProperties vkEnumerateInstanceExtensionProperties;
    PFN_vkEnumerateInstanceLayerProperties vkEnumerateInstanceLayerProperties;
    PFN_vkDestroyInstance vkDestroyInstance;
    PFN_vkCreateXlibSurfaceKHR vkCreateXlibSurfaceKHR;
    PFN_vkCreateXcbSurfaceKHR vkCreateXcbSurfaceKHR;
    PFN_vkCreateWin32SurfaceKHR vkCreateWin32SurfaceKHR;
    PFN_vkCreateMetalSurfaceEXT vkCreateMetalSurfaceEXT;
    PFN_vkDestroySurfaceKHR vkDestroySurfaceKHR;
    PFN_vkEnumeratePhysicalDevices vkEnumeratePhysicalDevices;
    PFN_vkGetPhysicalDeviceQueueFamilyProperties vkGetPhysicalDeviceQueueFamilyProperties;
    PFN_vkGetPhysicalDeviceSurfaceSupportKHR vkGetPhysicalDeviceSurfaceSupportKHR;
    PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR vkGetPhysicalDeviceSurfaceCapabilitiesKHR;
    PFN_vkGetPhysicalDeviceSurfaceFormatsKHR vkGetPhysicalDeviceSurfaceFormatsKHR;
    PFN_vkGetPhysicalDeviceSurfacePresentModesKHR vkGetPhysicalDeviceSurfacePresentModesKHR;
    PFN_vkEnumerateDeviceExtensionProperties vkEnumerateDeviceExtensionProperties;
    PFN_vkGetPhysicalDeviceMemoryProperties vkGetPhysicalDeviceMemoryProperties;
    PFN_vkCreateDevice vkCreateDevice;
    PFN_vkDestroyDevice vkDestroyDevice;
    PFN_vkGetDeviceQueue vkGetDeviceQueue;
    PFN_vkDeviceWaitIdle vkDeviceWaitIdle;
    PFN_vkQueueWaitIdle vkQueueWaitIdle;
    PFN_vkCreateSwapchainKHR vkCreateSwapchainKHR;
    PFN_vkDestroySwapchainKHR vkDestroySwapchainKHR;
    PFN_vkGetSwapchainImagesKHR vkGetSwapchainImagesKHR;
    PFN_vkAcquireNextImageKHR vkAcquireNextImageKHR;
    PFN_vkQueuePresentKHR vkQueuePresentKHR;
    PFN_vkCreateImageView vkCreateImageView;
    PFN_vkDestroyImageView vkDestroyImageView;
    PFN_vkCreateRenderPass vkCreateRenderPass;
    PFN_vkDestroyRenderPass vkDestroyRenderPass;
    PFN_vkCreateShaderModule vkCreateShaderModule;
    PFN_vkDestroyShaderModule vkDestroyShaderModule;
    PFN_vkCreateDescriptorSetLayout vkCreateDescriptorSetLayout;
    PFN_vkDestroyDescriptorSetLayout vkDestroyDescriptorSetLayout;
    PFN_vkCreatePipelineLayout vkCreatePipelineLayout;
    PFN_vkDestroyPipelineLayout vkDestroyPipelineLayout;
    PFN_vkCreateGraphicsPipelines vkCreateGraphicsPipelines;
    PFN_vkDestroyPipeline vkDestroyPipeline;
    PFN_vkCreateFramebuffer vkCreateFramebuffer;
    PFN_vkDestroyFramebuffer vkDestroyFramebuffer;
    PFN_vkCreateCommandPool vkCreateCommandPool;
    PFN_vkDestroyCommandPool vkDestroyCommandPool;
    PFN_vkAllocateCommandBuffers vkAllocateCommandBuffers;
    PFN_vkResetCommandBuffer vkResetCommandBuffer;
    PFN_vkBeginCommandBuffer vkBeginCommandBuffer;
    PFN_vkEndCommandBuffer vkEndCommandBuffer;
    PFN_vkCmdBeginRenderPass vkCmdBeginRenderPass;
    PFN_vkCmdEndRenderPass vkCmdEndRenderPass;
    PFN_vkCmdBindPipeline vkCmdBindPipeline;
    PFN_vkCmdSetViewport vkCmdSetViewport;
    PFN_vkCmdSetScissor vkCmdSetScissor;
    PFN_vkCmdBindVertexBuffers vkCmdBindVertexBuffers;
    PFN_vkCmdBindIndexBuffer vkCmdBindIndexBuffer;
    PFN_vkCmdBindDescriptorSets vkCmdBindDescriptorSets;
    PFN_vkCmdDrawIndexed vkCmdDrawIndexed;
    PFN_vkCreateSemaphore vkCreateSemaphore;
    PFN_vkDestroySemaphore vkDestroySemaphore;
    PFN_vkCreateFence vkCreateFence;
    PFN_vkDestroyFence vkDestroyFence;
    PFN_vkWaitForFences vkWaitForFences;
    PFN_vkGetFenceStatus vkGetFenceStatus;
    PFN_vkResetFences vkResetFences;
    PFN_vkQueueSubmit vkQueueSubmit;
    PFN_vkCreateBuffer vkCreateBuffer;
    PFN_vkDestroyBuffer vkDestroyBuffer;
    PFN_vkGetBufferMemoryRequirements vkGetBufferMemoryRequirements;
    PFN_vkAllocateMemory vkAllocateMemory;
    PFN_vkFreeMemory vkFreeMemory;
    PFN_vkBindBufferMemory vkBindBufferMemory;
    PFN_vkMapMemory vkMapMemory;
    PFN_vkUnmapMemory vkUnmapMemory;
    PFN_vkFlushMappedMemoryRanges vkFlushMappedMemoryRanges;
    PFN_vkCreateImage vkCreateImage;
    PFN_vkDestroyImage vkDestroyImage;
    PFN_vkGetImageMemoryRequirements vkGetImageMemoryRequirements;
    PFN_vkBindImageMemory vkBindImageMemory;
    PFN_vkCmdPipelineBarrier vkCmdPipelineBarrier;
    PFN_vkCmdCopyBufferToImage vkCmdCopyBufferToImage;
    PFN_vkCreateSampler vkCreateSampler;
    PFN_vkDestroySampler vkDestroySampler;
    PFN_vkCreateDescriptorPool vkCreateDescriptorPool;
    PFN_vkDestroyDescriptorPool vkDestroyDescriptorPool;
    PFN_vkAllocateDescriptorSets vkAllocateDescriptorSets;
    PFN_vkUpdateDescriptorSets vkUpdateDescriptorSets;

    this()
    {
        loadLibrary();
        vkGetInstanceProcAddr = cast(PFN_vkGetInstanceProcAddr) symbol("vkGetInstanceProcAddr");
        if (vkGetInstanceProcAddr is null)
            throw new Exception("Vulkan loader does not export vkGetInstanceProcAddr");
        vkCreateInstance = loadGlobal!PFN_vkCreateInstance("vkCreateInstance");
        vkEnumerateInstanceExtensionProperties =
            loadGlobal!PFN_vkEnumerateInstanceExtensionProperties("vkEnumerateInstanceExtensionProperties");
        vkEnumerateInstanceLayerProperties =
            loadGlobal!PFN_vkEnumerateInstanceLayerProperties("vkEnumerateInstanceLayerProperties");
    }

    void loadInstance(VkInstance instance)
    {
        vkDestroyInstance = loadInstanceFn!PFN_vkDestroyInstance(instance, "vkDestroyInstance");
        vkCreateXlibSurfaceKHR = optionalInstance!PFN_vkCreateXlibSurfaceKHR(instance, "vkCreateXlibSurfaceKHR");
        vkCreateXcbSurfaceKHR = optionalInstance!PFN_vkCreateXcbSurfaceKHR(instance, "vkCreateXcbSurfaceKHR");
        vkCreateWin32SurfaceKHR = optionalInstance!PFN_vkCreateWin32SurfaceKHR(instance, "vkCreateWin32SurfaceKHR");
        vkCreateMetalSurfaceEXT = optionalInstance!PFN_vkCreateMetalSurfaceEXT(instance, "vkCreateMetalSurfaceEXT");
        vkDestroySurfaceKHR = loadInstanceFn!PFN_vkDestroySurfaceKHR(instance, "vkDestroySurfaceKHR");
        vkEnumeratePhysicalDevices = loadInstanceFn!PFN_vkEnumeratePhysicalDevices(instance, "vkEnumeratePhysicalDevices");
        vkGetPhysicalDeviceQueueFamilyProperties = loadInstanceFn!PFN_vkGetPhysicalDeviceQueueFamilyProperties(instance, "vkGetPhysicalDeviceQueueFamilyProperties");
        vkGetPhysicalDeviceSurfaceSupportKHR = loadInstanceFn!PFN_vkGetPhysicalDeviceSurfaceSupportKHR(instance, "vkGetPhysicalDeviceSurfaceSupportKHR");
        vkGetPhysicalDeviceSurfaceCapabilitiesKHR = loadInstanceFn!PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR(instance, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR");
        vkGetPhysicalDeviceSurfaceFormatsKHR = loadInstanceFn!PFN_vkGetPhysicalDeviceSurfaceFormatsKHR(instance, "vkGetPhysicalDeviceSurfaceFormatsKHR");
        vkGetPhysicalDeviceSurfacePresentModesKHR = loadInstanceFn!PFN_vkGetPhysicalDeviceSurfacePresentModesKHR(instance, "vkGetPhysicalDeviceSurfacePresentModesKHR");
        vkEnumerateDeviceExtensionProperties = loadInstanceFn!PFN_vkEnumerateDeviceExtensionProperties(instance, "vkEnumerateDeviceExtensionProperties");
        vkGetPhysicalDeviceMemoryProperties = loadInstanceFn!PFN_vkGetPhysicalDeviceMemoryProperties(instance, "vkGetPhysicalDeviceMemoryProperties");
        vkCreateDevice = loadInstanceFn!PFN_vkCreateDevice(instance, "vkCreateDevice");
        vkGetDeviceProcAddr = loadInstanceFn!PFN_vkGetDeviceProcAddr(instance, "vkGetDeviceProcAddr");
    }

    void loadDevice(VkDevice device)
    {
        vkDestroyDevice = loadDeviceFn!PFN_vkDestroyDevice(device, "vkDestroyDevice");
        vkGetDeviceQueue = loadDeviceFn!PFN_vkGetDeviceQueue(device, "vkGetDeviceQueue");
        vkDeviceWaitIdle = loadDeviceFn!PFN_vkDeviceWaitIdle(device, "vkDeviceWaitIdle");
        vkQueueWaitIdle = loadDeviceFn!PFN_vkQueueWaitIdle(device, "vkQueueWaitIdle");
        vkCreateSwapchainKHR = loadDeviceFn!PFN_vkCreateSwapchainKHR(device, "vkCreateSwapchainKHR");
        vkDestroySwapchainKHR = loadDeviceFn!PFN_vkDestroySwapchainKHR(device, "vkDestroySwapchainKHR");
        vkGetSwapchainImagesKHR = loadDeviceFn!PFN_vkGetSwapchainImagesKHR(device, "vkGetSwapchainImagesKHR");
        vkAcquireNextImageKHR = loadDeviceFn!PFN_vkAcquireNextImageKHR(device, "vkAcquireNextImageKHR");
        vkQueuePresentKHR = loadDeviceFn!PFN_vkQueuePresentKHR(device, "vkQueuePresentKHR");
        vkCreateImageView = loadDeviceFn!PFN_vkCreateImageView(device, "vkCreateImageView");
        vkDestroyImageView = loadDeviceFn!PFN_vkDestroyImageView(device, "vkDestroyImageView");
        vkCreateRenderPass = loadDeviceFn!PFN_vkCreateRenderPass(device, "vkCreateRenderPass");
        vkDestroyRenderPass = loadDeviceFn!PFN_vkDestroyRenderPass(device, "vkDestroyRenderPass");
        vkCreateShaderModule = loadDeviceFn!PFN_vkCreateShaderModule(device, "vkCreateShaderModule");
        vkDestroyShaderModule = loadDeviceFn!PFN_vkDestroyShaderModule(device, "vkDestroyShaderModule");
        vkCreateDescriptorSetLayout = loadDeviceFn!PFN_vkCreateDescriptorSetLayout(device, "vkCreateDescriptorSetLayout");
        vkDestroyDescriptorSetLayout = loadDeviceFn!PFN_vkDestroyDescriptorSetLayout(device, "vkDestroyDescriptorSetLayout");
        vkCreatePipelineLayout = loadDeviceFn!PFN_vkCreatePipelineLayout(device, "vkCreatePipelineLayout");
        vkDestroyPipelineLayout = loadDeviceFn!PFN_vkDestroyPipelineLayout(device, "vkDestroyPipelineLayout");
        vkCreateGraphicsPipelines = loadDeviceFn!PFN_vkCreateGraphicsPipelines(device, "vkCreateGraphicsPipelines");
        vkDestroyPipeline = loadDeviceFn!PFN_vkDestroyPipeline(device, "vkDestroyPipeline");
        vkCreateFramebuffer = loadDeviceFn!PFN_vkCreateFramebuffer(device, "vkCreateFramebuffer");
        vkDestroyFramebuffer = loadDeviceFn!PFN_vkDestroyFramebuffer(device, "vkDestroyFramebuffer");
        vkCreateCommandPool = loadDeviceFn!PFN_vkCreateCommandPool(device, "vkCreateCommandPool");
        vkDestroyCommandPool = loadDeviceFn!PFN_vkDestroyCommandPool(device, "vkDestroyCommandPool");
        vkAllocateCommandBuffers = loadDeviceFn!PFN_vkAllocateCommandBuffers(device, "vkAllocateCommandBuffers");
        vkResetCommandBuffer = loadDeviceFn!PFN_vkResetCommandBuffer(device, "vkResetCommandBuffer");
        vkBeginCommandBuffer = loadDeviceFn!PFN_vkBeginCommandBuffer(device, "vkBeginCommandBuffer");
        vkEndCommandBuffer = loadDeviceFn!PFN_vkEndCommandBuffer(device, "vkEndCommandBuffer");
        vkCmdBeginRenderPass = loadDeviceFn!PFN_vkCmdBeginRenderPass(device, "vkCmdBeginRenderPass");
        vkCmdEndRenderPass = loadDeviceFn!PFN_vkCmdEndRenderPass(device, "vkCmdEndRenderPass");
        vkCmdBindPipeline = loadDeviceFn!PFN_vkCmdBindPipeline(device, "vkCmdBindPipeline");
        vkCmdSetViewport = loadDeviceFn!PFN_vkCmdSetViewport(device, "vkCmdSetViewport");
        vkCmdSetScissor = loadDeviceFn!PFN_vkCmdSetScissor(device, "vkCmdSetScissor");
        vkCmdBindVertexBuffers = loadDeviceFn!PFN_vkCmdBindVertexBuffers(device, "vkCmdBindVertexBuffers");
        vkCmdBindIndexBuffer = loadDeviceFn!PFN_vkCmdBindIndexBuffer(device, "vkCmdBindIndexBuffer");
        vkCmdBindDescriptorSets = loadDeviceFn!PFN_vkCmdBindDescriptorSets(device, "vkCmdBindDescriptorSets");
        vkCmdDrawIndexed = loadDeviceFn!PFN_vkCmdDrawIndexed(device, "vkCmdDrawIndexed");
        vkCreateSemaphore = loadDeviceFn!PFN_vkCreateSemaphore(device, "vkCreateSemaphore");
        vkDestroySemaphore = loadDeviceFn!PFN_vkDestroySemaphore(device, "vkDestroySemaphore");
        vkCreateFence = loadDeviceFn!PFN_vkCreateFence(device, "vkCreateFence");
        vkDestroyFence = loadDeviceFn!PFN_vkDestroyFence(device, "vkDestroyFence");
        vkWaitForFences = loadDeviceFn!PFN_vkWaitForFences(device, "vkWaitForFences");
        vkGetFenceStatus = loadDeviceFn!PFN_vkGetFenceStatus(device, "vkGetFenceStatus");
        vkResetFences = loadDeviceFn!PFN_vkResetFences(device, "vkResetFences");
        vkQueueSubmit = loadDeviceFn!PFN_vkQueueSubmit(device, "vkQueueSubmit");
        vkCreateBuffer = loadDeviceFn!PFN_vkCreateBuffer(device, "vkCreateBuffer");
        vkDestroyBuffer = loadDeviceFn!PFN_vkDestroyBuffer(device, "vkDestroyBuffer");
        vkGetBufferMemoryRequirements = loadDeviceFn!PFN_vkGetBufferMemoryRequirements(device, "vkGetBufferMemoryRequirements");
        vkAllocateMemory = loadDeviceFn!PFN_vkAllocateMemory(device, "vkAllocateMemory");
        vkFreeMemory = loadDeviceFn!PFN_vkFreeMemory(device, "vkFreeMemory");
        vkBindBufferMemory = loadDeviceFn!PFN_vkBindBufferMemory(device, "vkBindBufferMemory");
        vkMapMemory = loadDeviceFn!PFN_vkMapMemory(device, "vkMapMemory");
        vkUnmapMemory = loadDeviceFn!PFN_vkUnmapMemory(device, "vkUnmapMemory");
        vkFlushMappedMemoryRanges = loadDeviceFn!PFN_vkFlushMappedMemoryRanges(device, "vkFlushMappedMemoryRanges");
        vkCreateImage = loadDeviceFn!PFN_vkCreateImage(device, "vkCreateImage");
        vkDestroyImage = loadDeviceFn!PFN_vkDestroyImage(device, "vkDestroyImage");
        vkGetImageMemoryRequirements = loadDeviceFn!PFN_vkGetImageMemoryRequirements(device, "vkGetImageMemoryRequirements");
        vkBindImageMemory = loadDeviceFn!PFN_vkBindImageMemory(device, "vkBindImageMemory");
        vkCmdPipelineBarrier = loadDeviceFn!PFN_vkCmdPipelineBarrier(device, "vkCmdPipelineBarrier");
        vkCmdCopyBufferToImage = loadDeviceFn!PFN_vkCmdCopyBufferToImage(device, "vkCmdCopyBufferToImage");
        vkCreateSampler = loadDeviceFn!PFN_vkCreateSampler(device, "vkCreateSampler");
        vkDestroySampler = loadDeviceFn!PFN_vkDestroySampler(device, "vkDestroySampler");
        vkCreateDescriptorPool = loadDeviceFn!PFN_vkCreateDescriptorPool(device, "vkCreateDescriptorPool");
        vkDestroyDescriptorPool = loadDeviceFn!PFN_vkDestroyDescriptorPool(device, "vkDestroyDescriptorPool");
        vkAllocateDescriptorSets = loadDeviceFn!PFN_vkAllocateDescriptorSets(device, "vkAllocateDescriptorSets");
        vkUpdateDescriptorSets = loadDeviceFn!PFN_vkUpdateDescriptorSets(device, "vkUpdateDescriptorSets");
    }

    void close()
    {
        if (_library is null) return;
        version (Windows)
        {
            import core.sys.windows.windows : FreeLibrary, HMODULE;
            FreeLibrary(cast(HMODULE) _library);
        }
        else
        {
            import core.sys.posix.dlfcn : dlclose;
            dlclose(_library);
        }
        _library = null;
    }

    private void loadLibrary()
    {
        version (Windows)
        {
            import core.sys.windows.windows : LoadLibraryA;
            _library = cast(void*) LoadLibraryA("vulkan-1.dll");
        }
        else
        {
            import core.sys.posix.dlfcn : RTLD_LOCAL, RTLD_NOW, dlopen;
            version (OSX)
            {
                immutable candidates = [
                    "libvulkan.1.dylib", "libvulkan.dylib", "libMoltenVK.dylib",
                    "/usr/local/lib/libvulkan.1.dylib",
                    "/opt/homebrew/lib/libvulkan.1.dylib",
                    "/Library/Frameworks/MoltenVK.framework/MoltenVK"
                ];
            }
            else
                immutable candidates = ["libvulkan.so.1", "libvulkan.so"];
            foreach (candidate; candidates)
            {
                _library = dlopen(toStringz(candidate), RTLD_NOW | RTLD_LOCAL);
                if (_library !is null) break;
            }
        }
        if (_library is null)
            throw new Exception("No Vulkan loader was found on this system");
    }

    private void* symbol(string name)
    {
        version (Windows)
        {
            import core.sys.windows.windows : GetProcAddress, HMODULE;
            return cast(void*) GetProcAddress(cast(HMODULE) _library, toStringz(name));
        }
        else
        {
            import core.sys.posix.dlfcn : dlsym;
            return dlsym(_library, toStringz(name));
        }
    }

    private T loadGlobal(T)(string name)
    {
        auto result = cast(T) vkGetInstanceProcAddr(null, toStringz(name));
        if (result is null) throw new Exception("Vulkan loader entry point is unavailable: " ~ name);
        return result;
    }

    private T loadInstanceFn(T)(VkInstance instance, string name)
    {
        auto result = cast(T) vkGetInstanceProcAddr(instance, toStringz(name));
        if (result is null) throw new Exception("Vulkan instance entry point is unavailable: " ~ name);
        return result;
    }

    private T optionalInstance(T)(VkInstance instance, string name)
    {
        return cast(T) vkGetInstanceProcAddr(instance, toStringz(name));
    }

    private T loadDeviceFn(T)(VkDevice device, string name)
    {
        auto result = cast(T) vkGetDeviceProcAddr(device, toStringz(name));
        if (result is null) throw new Exception("Vulkan device entry point is unavailable: " ~ name);
        return result;
    }
}

string vkResultName(VkResult result)
{
    switch (result)
    {
        case VK_SUCCESS: return "VK_SUCCESS";
        case VK_NOT_READY: return "VK_NOT_READY";
        case VK_TIMEOUT: return "VK_TIMEOUT";
        case VK_ERROR_OUT_OF_HOST_MEMORY: return "VK_ERROR_OUT_OF_HOST_MEMORY";
        case VK_ERROR_OUT_OF_DEVICE_MEMORY: return "VK_ERROR_OUT_OF_DEVICE_MEMORY";
        case VK_ERROR_INITIALIZATION_FAILED: return "VK_ERROR_INITIALIZATION_FAILED";
        case VK_ERROR_DEVICE_LOST: return "VK_ERROR_DEVICE_LOST";
        case VK_ERROR_EXTENSION_NOT_PRESENT: return "VK_ERROR_EXTENSION_NOT_PRESENT";
        case VK_ERROR_OUT_OF_DATE_KHR: return "VK_ERROR_OUT_OF_DATE_KHR";
        case VK_SUBOPTIMAL_KHR: return "VK_SUBOPTIMAL_KHR";
        default: return "VkResult(" ~ result.to!string ~ ")";
    }
}

private import std.conv : to;
