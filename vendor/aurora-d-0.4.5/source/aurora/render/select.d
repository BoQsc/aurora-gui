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
        version (Windows)
        {
            // Remote and virtual displays can expose a Vulkan surface that
            // initializes but never shows a frame, which looks like a black
            // window with working input. Prefer the reliable software path
            // there; an explicit vulkan preference still overrides this.
            import core.sys.windows.winuser : GetSystemMetrics, SM_REMOTESESSION;
            if (GetSystemMetrics(SM_REMOTESESSION) != 0)
                return new SoftwareRenderer(size);
        }
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
