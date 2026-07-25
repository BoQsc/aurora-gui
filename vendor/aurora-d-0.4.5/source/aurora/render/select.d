module aurora.render.select;

import aurora.platform.base : NativeWindow, WindowOptions;
import aurora.render.base : RenderBackend, RendererPreference;
import aurora.render.software : SoftwareRenderer;
import aurora.types : Size;

RenderBackend createRenderBackend(WindowOptions options, NativeWindow window,
    Size size, ref string fallbackReason)
{
    version (AuroraHeadless)
    {
        fallbackReason = options.renderer == RendererPreference.vulkan ?
            "Vulkan presentation is unavailable in AuroraHeadless" : "";
        if (options.renderer == RendererPreference.vulkan)
            throw new Exception(fallbackReason);
        return new SoftwareRenderer(size);
    }
    else
    {
        if (options.renderer == RendererPreference.software)
            return new SoftwareRenderer(size);
        try
        {
            import aurora.render.vulkan : VulkanRenderer;
            return new VulkanRenderer(options, window.nativeSurfaceInfo(), size);
        }
        catch (Exception error)
        {
            if (options.renderer == RendererPreference.vulkan)
                throw error;
            fallbackReason = error.msg;
            return new SoftwareRenderer(size);
        }
    }
}
