package main

import "core:fmt"
import "core:os"
import "core:mem"
import glm "core:math/linalg/glsl"
import vk "vendor:vulkan"
import sdl "vendor:sdl3"
import vma "shared:vma"
import tinyobj "shared:tinyobj"
import ktx "shared:ktx_odin"
import slang "shared:slang"

chk :: proc(code: vk.Result) {
    if code != vk.Result.SUCCESS {
        fmt.eprintln("Vulkan returned", code);
        os.exit(1);
    }
}

Vertex :: struct {
    pos: glm.vec3,
    normal: glm.vec3,
    uv: glm.vec2,
};

ShaderDataBuffer :: struct {
    allocation: vma.Allocation,
	allocationInfo: vma.AllocationInfo,
	buffer: vk.Buffer,
	deviceAddress: vk.DeviceAddress,
};

ShaderData :: struct {
    projection: glm.mat4,
    view: glm.mat4,
    model: [3]glm.mat4,
    lightPos: glm.vec4,
    selected: u32,
};

Texture :: struct {
	allocation: vma.Allocation,
	image:      vk.Image,
	view:       vk.ImageView,
	sampler:    vk.Sampler,
}

main :: proc() {
    if !sdl.Init({.VIDEO}) {
        fmt.eprintln("SDL_Init failed:", sdl.GetError())
        return
    }
    defer sdl.Quit()

    if !sdl.Vulkan_LoadLibrary(nil) {
        fmt.eprintln("Vulkan_LoadLibrary failed:", sdl.GetError())
        return
    }
    defer sdl.Vulkan_UnloadLibrary()

    // Load Vulkan's *global* function pointers (vkCreateInstance, etc.)
    // via SDL's loader — without this, every vk.* call is a nil-pointer call.
    getInstanceProcAddr := sdl.Vulkan_GetVkGetInstanceProcAddr()
    vk.load_proc_addresses_global(rawptr(getInstanceProcAddr))

    //=== Instance setup ======================================================

    appInfo := vk.ApplicationInfo {
        sType = .APPLICATION_INFO,
        pApplicationName = "How to Vulkan",
        apiVersion = vk.API_VERSION_1_3,
    };

    instanceExtensionsCount: u32;
    instanceExtensions: [^]cstring = sdl.Vulkan_GetInstanceExtensions(&instanceExtensionsCount);

    instanceCI := vk.InstanceCreateInfo {
        sType = .INSTANCE_CREATE_INFO,
        pApplicationInfo = &appInfo,
        enabledExtensionCount = instanceExtensionsCount,
        ppEnabledExtensionNames = instanceExtensions,
    };

    instance: vk.Instance;

    chk(vk.CreateInstance(&instanceCI, nil, &instance));
    defer vk.DestroyInstance(instance, nil)

    // Now that we have an instance, load the instance-level function pointers
    // (vkCreateDevice, vkDestroySurfaceKHR, etc.) — same nil-pointer issue applies to these.
    vk.load_proc_addresses_instance(instance)

    //=========================================================================

    //=== Device selection ====================================================

    deviceCount: u32;
    chk(vk.EnumeratePhysicalDevices(instance, &deviceCount, nil));
    devices := make([]vk.PhysicalDevice, deviceCount);
    chk(vk.EnumeratePhysicalDevices(instance, &deviceCount, raw_data(devices)));

    device_index: u32 = 0;

    deviceProperties := vk.PhysicalDeviceProperties2 {
        sType = .PHYSICAL_DEVICE_PROPERTIES_2,
    };
    vk.GetPhysicalDeviceProperties2(devices[device_index], &deviceProperties);
    fmt.printfln("Selected device: %s", deviceProperties.properties.deviceName);

    //=========================================================================

    //=== Queues ==============================================================

    queueFamilyCount: u32;
    vk.GetPhysicalDeviceQueueFamilyProperties(devices[device_index], &queueFamilyCount, nil);
    queueFamilies := make([]vk.QueueFamilyProperties, queueFamilyCount);
    vk.GetPhysicalDeviceQueueFamilyProperties(devices[device_index], &queueFamilyCount, raw_data(queueFamilies));
    queueFamily: u32 = 0;
    for i := 0; i < len(queueFamilies); i += 1 {
        if vk.QueueFlag.GRAPHICS in queueFamilies[i].queueFlags {
            queueFamily = cast(u32)i;
            break;
        }
    }

    if !sdl.Vulkan_GetPresentationSupport(instance, devices[device_index], queueFamily) {
        fmt.eprintln("Selected queue family does not support presentation");
        os.exit(1);
    }

    qfpriorities := make([]f32, 1);
    qfpriorities[0] = 1.0;
    queueCI := vk.DeviceQueueCreateInfo {
        sType = .DEVICE_QUEUE_CREATE_INFO,
        queueFamilyIndex = queueFamily,
        queueCount = 1,
        pQueuePriorities = raw_data(qfpriorities),
    };

    //=========================================================================

    //=== Device setup ========================================================

    device_extensions := make([]cstring, 1);
    device_extensions[0] = vk.KHR_SWAPCHAIN_EXTENSION_NAME;

    enabledVk12Features := vk.PhysicalDeviceVulkan12Features {
        sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
        descriptorIndexing = true,
        shaderSampledImageArrayNonUniformIndexing = true,
        descriptorBindingVariableDescriptorCount = true,
        runtimeDescriptorArray = true,
        bufferDeviceAddress = true,
    };

    enabledVk13Features := vk.PhysicalDeviceVulkan13Features {
        sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        pNext = &enabledVk12Features,
        synchronization2 = true,
        dynamicRendering = true,
    };

    enabledVk10Features := vk.PhysicalDeviceFeatures {
        samplerAnisotropy = true,
    };

    deviceCI := vk.DeviceCreateInfo {
        sType = .DEVICE_CREATE_INFO,
        pNext = &enabledVk13Features,
        queueCreateInfoCount = 1,
        pQueueCreateInfos = &queueCI,
        enabledExtensionCount = cast(u32)len(device_extensions),
        ppEnabledExtensionNames = raw_data(device_extensions),
        pEnabledFeatures = &enabledVk10Features,
    };

    device: vk.Device;
    chk(vk.CreateDevice(devices[device_index], &deviceCI, nil, &device));
    defer vk.DestroyDevice(device, nil)

    vk.load_proc_addresses_device(device);

    //=========================================================================

    //=== Setting up VMA ======================================================

    vkFunctions := vma.create_vulkan_functions();

    allocatorCI := vma.AllocatorCreateInfo {
        flags = { .BUFFER_DEVICE_ADDRESS },
        physicalDevice = devices[device_index],
        device = device,
        pVulkanFunctions = &vkFunctions,
        instance = instance,
    };

    allocator: vma.Allocator;
    chk(vma.CreateAllocator(allocatorCI, &allocator));
    defer vma.DestroyAllocator(allocator)

    //=========================================================================

    //=== Window and surface ==================================================

    windowSizeX := 1280;
    windowSizeY := 720;
    window := sdl.CreateWindow("How to Vulkan", cast(i32)windowSizeX, cast(i32)windowSizeY, sdl.WINDOW_VULKAN + sdl.WINDOW_RESIZABLE);
    if window == nil {
        fmt.eprintln("CreateWindow failed:", sdl.GetError())
        os.exit(1);
    }
    defer sdl.DestroyWindow(window)

    surface: vk.SurfaceKHR;
    if !sdl.Vulkan_CreateSurface(window, instance, nil, &surface) {
        fmt.eprintln("Vulkan_CreateSurface failed:", sdl.GetError())
        os.exit(1);
    }
    defer vk.DestroySurfaceKHR(instance, surface, nil)

    surfaceCaps: vk.SurfaceCapabilitiesKHR;
    chk(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(devices[device_index], surface, &surfaceCaps));

    //=========================================================================

    //=== Swapchain ===========================================================

    swapchainExtent: vk.Extent2D = surfaceCaps.currentExtent;

    // Wayland handling
    if surfaceCaps.currentExtent.width == 0xFFFFFFFF {
        swapchainExtent = { width = cast(u32)windowSizeX, height = cast(u32)windowSizeY };
    }

    imageFormat : vk.Format : .B8G8R8A8_SRGB;
    swapchainCI := vk.SwapchainCreateInfoKHR {
        sType = .SWAPCHAIN_CREATE_INFO_KHR,
        surface = surface,
        minImageCount = surfaceCaps.minImageCount,
        imageFormat = imageFormat,
        imageColorSpace = .SRGB_NONLINEAR,
        imageExtent = { width = swapchainExtent.width, height = swapchainExtent.height },
        imageArrayLayers = 1,
        imageUsage = { .COLOR_ATTACHMENT },
        preTransform = { .IDENTITY },
        compositeAlpha = { .OPAQUE },
        presentMode = .FIFO
    };

    swapchain: vk.SwapchainKHR;
    chk(vk.CreateSwapchainKHR(device, &swapchainCI, nil, &swapchain));
    defer vk.DestroySwapchainKHR(device, swapchain, nil)

    imageCount: u32;
    chk(vk.GetSwapchainImagesKHR(device, swapchain, &imageCount, nil));
    swapchainImages := make([]vk.Image, imageCount);
    chk(vk.GetSwapchainImagesKHR(device, swapchain, &imageCount, raw_data(swapchainImages)));
    swapchainImageViews := make([]vk.ImageView, imageCount);
    defer {
        for view in swapchainImageViews {
            vk.DestroyImageView(device, view, nil)
        }
    }
    for i in 0 ..< imageCount {
        viewCI := vk.ImageViewCreateInfo {
            sType    = .IMAGE_VIEW_CREATE_INFO,
            image    = swapchainImages[i],
            viewType = .D2,
            format   = imageFormat,
            subresourceRange = { aspectMask = { .COLOR }, levelCount = 1, layerCount = 1 },
        };
        chk(vk.CreateImageView(device, &viewCI, nil, &swapchainImageViews[i]));
    }

    //=========================================================================

    //=== Depth attachment ====================================================

    depthFormatList : [2]vk.Format = { .D32_SFLOAT_S8_UINT, .D24_UNORM_S8_UINT };
    depthFormat: vk.Format = .UNDEFINED;
    for &format in depthFormatList {
        formatProperties := vk.FormatProperties2{ sType = .FORMAT_PROPERTIES_2 };
        vk.GetPhysicalDeviceFormatProperties2(devices[device_index], format, &formatProperties);
        if .DEPTH_STENCIL_ATTACHMENT in formatProperties.formatProperties.optimalTilingFeatures {
            depthFormat = format;
            break;
        }
    }
    if depthFormat == .UNDEFINED {
        fmt.eprintln("No supported depth-stencil format found");
        os.exit(1);
    }

    depthImageCI := vk.ImageCreateInfo {
        sType = .IMAGE_CREATE_INFO,
        imageType = .D2,
        format = depthFormat,
        extent = { width = cast(u32)windowSizeX, height = cast(u32)windowSizeY, depth = 1 },
        mipLevels = 1,
        arrayLayers = 1,
        samples = { ._1 },
        tiling = .OPTIMAL,
        usage = { .DEPTH_STENCIL_ATTACHMENT },
        initialLayout = .UNDEFINED,
    };

    allocCI := vma.AllocationCreateInfo {
        flags = { .DEDICATED_MEMORY },
        usage = .AUTO
    };

    depthImageAllocation: vma.Allocation;

    depthImage : vk.Image;
    chk(vma.CreateImage(allocator, depthImageCI, allocCI, &depthImage, &depthImageAllocation, nil));
    defer vma.DestroyImage(allocator, depthImage, depthImageAllocation)

    depthViewCI := vk.ImageViewCreateInfo {
        sType = .IMAGE_VIEW_CREATE_INFO,
        image = depthImage,
        viewType = .D2,
        format = depthFormat,
        subresourceRange = { aspectMask = { .DEPTH }, levelCount = 1, layerCount = 1 }
    };

    depthImageView: vk.ImageView;
    chk(vk.CreateImageView(device, &depthViewCI, nil, &depthImageView));
    defer vk.DestroyImageView(device, depthImageView, nil)

    //=========================================================================

    //=== Loading meshes ======================================================

    suzanneBuf, err := os.read_entire_file_from_path("assets/suzanne.obj", context.allocator);
    if err != nil {
        fmt.eprintln("Failed to read assets/suzanne.obj:", err)
        os.exit(1);
    }

    result := tinyobj.parse_obj(string(suzanneBuf), "", tinyobj.FLAG_TRIANGULATE);
    if !result.success {
        fmt.println("Failed to parse OBJ")
        return
    }

    defer tinyobj.destroy(&result)

    if len(result.shapes) == 0 {
        fmt.eprintln("OBJ file has no shapes")
        os.exit(1);
    }

    shape := result.shapes[0]
    faceStart := shape.face_offset * 3
    faceEnd   := faceStart + shape.length * 3
    shapeIndices := result.attrib.faces[faceStart:faceEnd]

    if len(shapeIndices) > int(max(u16)) + 1 {
        fmt.eprintln("Mesh has too many indices for u16:", len(shapeIndices))
        os.exit(1);
    }

    vertices: [dynamic]Vertex
    indices:  [dynamic]u16

    for &index in shapeIndices {
        v := Vertex {
            pos = {
                result.attrib.vertices[index.v_idx * 3],
                -result.attrib.vertices[index.v_idx * 3 + 1],
                result.attrib.vertices[index.v_idx * 3 + 2],
            },
            normal = {
                result.attrib.normals[index.vn_idx * 3],
                -result.attrib.normals[index.vn_idx * 3 + 1],
                result.attrib.normals[index.vn_idx * 3 + 2],
            },
            uv = {
                result.attrib.texcoords[index.vt_idx * 2],
                1.0 - result.attrib.texcoords[index.vt_idx * 2 + 1],
            },
        }
        append(&vertices, v)
        append(&indices, u16(len(indices)))
    }

    indexCount : vk.DeviceSize = vk.DeviceSize(len(shapeIndices))

    vBufSize := vk.DeviceSize(size_of(Vertex) * len(vertices));
    iBufSize := vk.DeviceSize(size_of(u16) * len(indices));
    bufferCI := vk.BufferCreateInfo {
        sType = .BUFFER_CREATE_INFO,
        size = vBufSize + iBufSize,
        usage = { .VERTEX_BUFFER, .INDEX_BUFFER }
    };

    vBufferAllocCI := vma.AllocationCreateInfo {
        flags = { .HOST_ACCESS_SEQUENTIAL_WRITE, .HOST_ACCESS_ALLOW_TRANSFER_INSTEAD, .MAPPED },
        usage = .AUTO
    };
    vBufferAllocInfo : vma.AllocationInfo;

    vBuffer: vk.Buffer;
    vBufferAllocation: vma.Allocation;
    chk(vma.CreateBuffer(allocator, bufferCI, vBufferAllocCI, &vBuffer, &vBufferAllocation, &vBufferAllocInfo));
    defer vma.DestroyBuffer(allocator, vBuffer, vBufferAllocation)

    mem.copy(vBufferAllocInfo.pMappedData, raw_data(vertices), cast(int)vBufSize);
    mem.copy(rawptr(uintptr(vBufferAllocInfo.pMappedData) + uintptr(vBufSize)), raw_data(indices), int(iBufSize));

    //=========================================================================

    //=== CPU and GPU parallelism =============================================

    maxFramesInFlight : u32 : 2;

    shaderDataBuffers: [maxFramesInFlight]ShaderDataBuffer;
    defer {
        for buf in shaderDataBuffers {
            vma.DestroyBuffer(allocator, buf.buffer, buf.allocation)
        }
    }
    commandBuffers: [maxFramesInFlight]vk.CommandBuffer;

    shaderData := ShaderData {
        selected = 1,
        lightPos = { 0.0, -10.0, 10.0, 0.0 },
    };

    //=========================================================================

    //=== Shader data buffers =================================================

    for i: u32 = 0; i < maxFramesInFlight; i += 1 {
        uBufferCI := vk.BufferCreateInfo {
            sType = .BUFFER_CREATE_INFO,
            size = size_of(ShaderData),
            usage = { .SHADER_DEVICE_ADDRESS },
        };
        uBufferAllocCI := vma.AllocationCreateInfo {
            flags = { .HOST_ACCESS_SEQUENTIAL_WRITE, .HOST_ACCESS_ALLOW_TRANSFER_INSTEAD, .MAPPED },
            usage = .AUTO,
        };
        chk(vma.CreateBuffer(allocator, uBufferCI, uBufferAllocCI, &shaderDataBuffers[i].buffer, &shaderDataBuffers[i].allocation, &shaderDataBuffers[i].allocationInfo));
        uBufferBdaInfo := vk.BufferDeviceAddressInfo {
            sType = .BUFFER_DEVICE_ADDRESS_INFO,
            buffer = shaderDataBuffers[i].buffer,
        };
        shaderDataBuffers[i].deviceAddress = vk.GetBufferDeviceAddress(device, &uBufferBdaInfo);
    }

    //=========================================================================

    //=== Synchronization objects =============================================

    semaphoreCI := vk.SemaphoreCreateInfo {
        sType = .SEMAPHORE_CREATE_INFO
    };

    fenceCI := vk.FenceCreateInfo {
        sType = .FENCE_CREATE_INFO,
        flags = { .SIGNALED }
    };

    fences: [maxFramesInFlight]vk.Fence;
    imageAcquiredSemaphores: [maxFramesInFlight]vk.Semaphore;
    defer {
        for i in 0 ..< maxFramesInFlight {
            vk.DestroyFence(device, fences[i], nil)
            vk.DestroySemaphore(device, imageAcquiredSemaphores[i], nil)
        }
    }
    for i: u32 = 0; i < maxFramesInFlight; i += 1 {
        chk(vk.CreateFence(device, &fenceCI, nil, &fences[i]));
        chk(vk.CreateSemaphore(device, &semaphoreCI, nil, &imageAcquiredSemaphores[i]));
    }

    renderCompleteSemaphores: [dynamic]vk.Semaphore;
    defer {
        for semaphore in renderCompleteSemaphores {
            vk.DestroySemaphore(device, semaphore, nil)
        }
        delete(renderCompleteSemaphores)
    }
    resize(&renderCompleteSemaphores, len(swapchainImages));
    for &semaphore in renderCompleteSemaphores {
        chk(vk.CreateSemaphore(device, &semaphoreCI, nil, &semaphore));
    }

    //=========================================================================

    //=== Command buffers =====================================================

    commandPoolCI := vk.CommandPoolCreateInfo {
        sType = .COMMAND_POOL_CREATE_INFO,
        flags = { .RESET_COMMAND_BUFFER },
        queueFamilyIndex = queueFamily,
    };
    commandPool: vk.CommandPool;
    chk(vk.CreateCommandPool(device, &commandPoolCI, nil, &commandPool));
    defer vk.DestroyCommandPool(device, commandPool, nil)

    cbAllocCI := vk.CommandBufferAllocateInfo {
        sType = .COMMAND_BUFFER_ALLOCATE_INFO,
        commandPool = commandPool,
        commandBufferCount = maxFramesInFlight
    };
    chk(vk.AllocateCommandBuffers(device, &cbAllocCI, raw_data(commandBuffers[:])));

    //=========================================================================

    //=== Loading textures ====================================================

    textures: [3]Texture
    defer {
        for t in textures {
            vk.DestroySampler(device, t.sampler, nil)
            vk.DestroyImageView(device, t.view, nil)
            vma.DestroyImage(allocator, t.image, t.allocation)
        }
    }
    queue: vk.Queue;
    vk.GetDeviceQueue(device, queueFamily, 0, &queue)

    descriptorPool:         vk.DescriptorPool
    descriptorSetLayoutTex: vk.DescriptorSetLayout
    descriptorSetTex:       vk.DescriptorSet

	textureDescriptors: [dynamic]vk.DescriptorImageInfo
	defer delete(textureDescriptors)

	for i in 0 ..< len(textures) {
		ktxTexture: ^ktx.Texture
		filename := fmt.ctprintf("assets/suzanne%d.ktx", i)
		ktxResult := ktx.Texture_CreateFromNamedFile(filename, {.LOAD_IMAGE_DATA}, &ktxTexture)
		if ktxResult != .SUCCESS {
			fmt.eprintln("Failed to load", filename, ":", ktxResult)
			os.exit(1);
		}

		texImgCI := vk.ImageCreateInfo {
			sType         = .IMAGE_CREATE_INFO,
			imageType     = .D2,
			format        = ktx.Texture_GetVkFormat(ktxTexture),
			extent        = {width = ktxTexture.baseWidth, height = ktxTexture.baseHeight, depth = 1},
			mipLevels     = ktxTexture.numLevels,
			arrayLayers   = 1,
			samples       = {._1},
			tiling        = .OPTIMAL,
			usage         = {.TRANSFER_DST, .SAMPLED},
			initialLayout = .UNDEFINED,
		}
		texImageAllocCI := vma.AllocationCreateInfo{usage = .AUTO}
		chk(vma.CreateImage(allocator, texImgCI, texImageAllocCI, &textures[i].image, &textures[i].allocation, nil))

		texViewCI := vk.ImageViewCreateInfo {
			sType    = .IMAGE_VIEW_CREATE_INFO,
			image    = textures[i].image,
			viewType = .D2,
			format   = texImgCI.format,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = ktxTexture.numLevels, layerCount = 1},
		}
		chk(vk.CreateImageView(device, &texViewCI, nil, &textures[i].view))

		// --- Upload ---
		imgSrcBuffer: vk.Buffer
		imgSrcAllocation: vma.Allocation
		imgSrcBufferCI := vk.BufferCreateInfo {
			sType = .BUFFER_CREATE_INFO,
			size  = vk.DeviceSize(ktxTexture.dataSize),
			usage = {.TRANSFER_SRC},
		}
		imgSrcAllocCI := vma.AllocationCreateInfo {
			flags = {.HOST_ACCESS_SEQUENTIAL_WRITE, .MAPPED},
			usage = .AUTO,
		}
		imgSrcAllocInfo: vma.AllocationInfo
		chk(vma.CreateBuffer(allocator, imgSrcBufferCI, imgSrcAllocCI, &imgSrcBuffer, &imgSrcAllocation, &imgSrcAllocInfo))

		mem.copy(imgSrcAllocInfo.pMappedData, rawptr(ktxTexture.pData), int(ktxTexture.dataSize))

		fenceOneTimeCI := vk.FenceCreateInfo{sType = .FENCE_CREATE_INFO}
		fenceOneTime: vk.Fence
		chk(vk.CreateFence(device, &fenceOneTimeCI, nil, &fenceOneTime))

		cbOneTime: vk.CommandBuffer
		cbOneTimeAI := vk.CommandBufferAllocateInfo {
			sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
			commandPool        = commandPool,
			commandBufferCount = 1,
		}
		chk(vk.AllocateCommandBuffers(device, &cbOneTimeAI, &cbOneTime))

		cbOneTimeBI := vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}}
		chk(vk.BeginCommandBuffer(cbOneTime, &cbOneTimeBI))

		barrierTexImage := vk.ImageMemoryBarrier2 {
			sType         = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask  = {},
			srcAccessMask = {},
			dstStageMask  = {.TRANSFER},
			dstAccessMask = {.TRANSFER_WRITE},
			oldLayout     = .UNDEFINED,
			newLayout     = .TRANSFER_DST_OPTIMAL,
			image         = textures[i].image,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = ktxTexture.numLevels, layerCount = 1},
		}
		barrierTexInfo := vk.DependencyInfo {
			sType                   = .DEPENDENCY_INFO,
			imageMemoryBarrierCount = 1,
			pImageMemoryBarriers    = &barrierTexImage,
		}
		vk.CmdPipelineBarrier2(cbOneTime, &barrierTexInfo)

		copyRegions: [dynamic]vk.BufferImageCopy
		defer delete(copyRegions)
		for j in 0 ..< ktxTexture.numLevels {
			mipOffset: uint
			ktxTexture.GetImageOffset(ktxTexture, j, 0, 0, &mipOffset)
			append(&copyRegions, vk.BufferImageCopy {
				bufferOffset = vk.DeviceSize(mipOffset),
				imageSubresource = {aspectMask = {.COLOR}, mipLevel = j, layerCount = 1},
				imageExtent = {
					width  = ktxTexture.baseWidth >> j,
					height = ktxTexture.baseHeight >> j,
					depth  = 1,
				},
			})
		}
		vk.CmdCopyBufferToImage(
			cbOneTime,
			imgSrcBuffer,
			textures[i].image,
			.TRANSFER_DST_OPTIMAL,
			u32(len(copyRegions)),
			raw_data(copyRegions),
		)

		barrierTexRead := vk.ImageMemoryBarrier2 {
			sType         = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask  = {.TRANSFER},
			srcAccessMask = {.TRANSFER_WRITE},
			dstStageMask  = {.FRAGMENT_SHADER},
			dstAccessMask = {.SHADER_READ},
			oldLayout     = .TRANSFER_DST_OPTIMAL,
			newLayout     = .READ_ONLY_OPTIMAL,
			image         = textures[i].image,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = ktxTexture.numLevels, layerCount = 1},
		}
		barrierTexInfo.pImageMemoryBarriers = &barrierTexRead
		vk.CmdPipelineBarrier2(cbOneTime, &barrierTexInfo)

		chk(vk.EndCommandBuffer(cbOneTime))

		cbOneTimeSubmitInfo := vk.CommandBufferSubmitInfo{sType = .COMMAND_BUFFER_SUBMIT_INFO, commandBuffer = cbOneTime}
		oneTimeSI := vk.SubmitInfo2 {
			sType                   = .SUBMIT_INFO_2,
			commandBufferInfoCount = 1,
			pCommandBufferInfos    = &cbOneTimeSubmitInfo,
		}
		chk(vk.QueueSubmit2(queue, 1, &oneTimeSI, fenceOneTime))
		chk(vk.WaitForFences(device, 1, &fenceOneTime, true, max(u64)))

		vk.DestroyFence(device, fenceOneTime, nil)
		vma.DestroyBuffer(allocator, imgSrcBuffer, imgSrcAllocation)
		vk.FreeCommandBuffers(device, commandPool, 1, &cbOneTime)

		// --- Sampler ---
		samplerCI := vk.SamplerCreateInfo {
			sType            = .SAMPLER_CREATE_INFO,
			magFilter        = .LINEAR,
			minFilter        = .LINEAR,
			mipmapMode       = .LINEAR,
			anisotropyEnable = true,
			maxAnisotropy    = 8.0,
			maxLod           = f32(ktxTexture.numLevels),
		}
		chk(vk.CreateSampler(device, &samplerCI, nil, &textures[i].sampler))

		ktxTexture.Destroy(ktxTexture)

		append(&textureDescriptors, vk.DescriptorImageInfo {
			sampler     = textures[i].sampler,
			imageView   = textures[i].view,
			imageLayout = .READ_ONLY_OPTIMAL,
		})
	}

	// --- Descriptor (indexing) ---

	descVariableFlag := vk.DescriptorBindingFlags{.VARIABLE_DESCRIPTOR_COUNT}
	descBindingFlags := vk.DescriptorSetLayoutBindingFlagsCreateInfo {
		sType         = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
		bindingCount  = 1,
		pBindingFlags = &descVariableFlag,
	}
	descLayoutBindingTex := vk.DescriptorSetLayoutBinding {
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		descriptorCount = u32(len(textures)),
		stageFlags      = {.FRAGMENT},
	}
	descLayoutTexCI := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		pNext        = &descBindingFlags,
		bindingCount = 1,
		pBindings    = &descLayoutBindingTex,
	}
	chk(vk.CreateDescriptorSetLayout(device, &descLayoutTexCI, nil, &descriptorSetLayoutTex))
	defer vk.DestroyDescriptorSetLayout(device, descriptorSetLayoutTex, nil)

	poolSize := vk.DescriptorPoolSize{type = .COMBINED_IMAGE_SAMPLER, descriptorCount = u32(len(textures))}
	descPoolCI := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets       = 1,
		poolSizeCount = 1,
		pPoolSizes    = &poolSize,
	}
	chk(vk.CreateDescriptorPool(device, &descPoolCI, nil, &descriptorPool))
	defer vk.DestroyDescriptorPool(device, descriptorPool, nil)

	variableDescCount := u32(len(textures))
	variableDescCountAI := vk.DescriptorSetVariableDescriptorCountAllocateInfo {
		sType              = .DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO,
		descriptorSetCount = 1,
		pDescriptorCounts  = &variableDescCount,
	}
	texDescSetAlloc := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		pNext              = &variableDescCountAI,
		descriptorPool     = descriptorPool,
		descriptorSetCount = 1,
		pSetLayouts        = &descriptorSetLayoutTex,
	}
	chk(vk.AllocateDescriptorSets(device, &texDescSetAlloc, &descriptorSetTex))

	writeDescSet := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = descriptorSetTex,
		dstBinding      = 0,
		descriptorCount = u32(len(textureDescriptors)),
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		pImageInfo      = raw_data(textureDescriptors),
	}
	vk.UpdateDescriptorSets(device, 1, &writeDescSet, 0, nil)

    //=========================================================================

    //=== Loading shaders =====================================================

    slangGlobalSession: ^slang.IGlobalSession;

    if slang.FAILED(slang.createGlobalSession(slang.API_VERSION, &slangGlobalSession)) {
        fmt.eprintln("Failed to create Slang global session");
        os.exit(1);
    }

    slangTargetDesc := slang.TargetDesc {
        structureSize = size_of(slang.TargetDesc),
        format = .SPIRV,
        flags = { .GENERATE_SPIRV_DIRECTLY },
        profile = slangGlobalSession->findProfile("spirv_1_4"),
    };

    slangOptionEntry := slang.CompilerOptionEntry {
        name = .EmitSpirvDirectly,
        value = { kind = .Int, intValue0 = 1 },
    };

    slangSessionDesc := slang.SessionDesc {
        structureSize = size_of(slang.SessionDesc),
        targets = &slangTargetDesc,
        targetCount = 1,
        defaultMatrixLayoutMode = .COLUMN_MAJOR,
        compilerOptionEntries = &slangOptionEntry,
        compilerOptionEntryCount = 1,
    };

    slangSession: ^slang.ISession;
    if slang.FAILED(slangGlobalSession->createSession(slangSessionDesc, &slangSession)) {
        fmt.eprintln("Failed to create Slang session");
        os.exit(1);
    }

    slangDiagnostics: ^slang.IBlob;
    slangModule := slangSession->loadModule("assets/shader.slang", &slangDiagnostics);
    if slangDiagnostics != nil {
        fmt.eprintln(string(([^]u8)(slangDiagnostics->getBufferPointer())[:slangDiagnostics->getBufferSize()]));
    }
    if slangModule == nil {
        fmt.eprintln("Failed to load assets/shader.slang");
        os.exit(1);
    }

    components: [dynamic]^slang.IComponentType;
    defer delete(components);
    append(&components, cast(^slang.IComponentType)slangModule);
    for i: i32 = 0; i < slangModule->getDefinedEntryPointCount(); i += 1 {
        entryPoint: ^slang.IEntryPoint;
        slangModule->getDefinedEntryPoint(i, &entryPoint);
        append(&components, cast(^slang.IComponentType)entryPoint);
    }

    linkedProgram: ^slang.IComponentType;
    if slang.FAILED(slangSession->createCompositeComponentType(raw_data(components), len(components), &linkedProgram, &slangDiagnostics)) {
        if slangDiagnostics != nil {
            fmt.eprintln(string(([^]u8)(slangDiagnostics->getBufferPointer())[:slangDiagnostics->getBufferSize()]));
        }
        fmt.eprintln("Failed to link assets/shader.slang");
        os.exit(1);
    }

    spirv: ^slang.IBlob;
    getTargetCodeResult := linkedProgram->getTargetCode(0, &spirv, &slangDiagnostics);
    if slangDiagnostics != nil {
        fmt.eprintln(string(([^]u8)(slangDiagnostics->getBufferPointer())[:slangDiagnostics->getBufferSize()]));
    }
    if spirv == nil {
        fmt.eprintln("Failed to get target code for assets/shader.slang, Result:", getTargetCodeResult);
        os.exit(1);
    }

    shaderModuleCI := vk.ShaderModuleCreateInfo {
        sType = .SHADER_MODULE_CREATE_INFO,
        codeSize = int(spirv->getBufferSize()),
        pCode = cast(^u32)spirv->getBufferPointer(),
    };
    shaderModule: vk.ShaderModule;
    chk(vk.CreateShaderModule(device, &shaderModuleCI, nil, &shaderModule));

    //=========================================================================

    //=== Graphics pipeline ===================================================

    pushConstantRange := vk.PushConstantRange {
        stageFlags = { .VERTEX },
        size = size_of(vk.DeviceAddress),
    };
    pipelineLayoutCI := vk.PipelineLayoutCreateInfo {
        sType = .PIPELINE_LAYOUT_CREATE_INFO,
        setLayoutCount = 1,
        pSetLayouts = &descriptorSetLayoutTex,
        pushConstantRangeCount = 1,
        pPushConstantRanges = &pushConstantRange,
    };
    pipelineLayout: vk.PipelineLayout;
    chk(vk.CreatePipelineLayout(device, &pipelineLayoutCI, nil, &pipelineLayout));
    defer vk.DestroyPipelineLayout(device, pipelineLayout, nil)

    shaderStages := [2]vk.PipelineShaderStageCreateInfo {
        { sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = { .VERTEX }, module = shaderModule, pName = "main" },
        { sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = { .FRAGMENT }, module = shaderModule, pName = "main" },
    };

    vertexBinding := vk.VertexInputBindingDescription {
        binding = 0,
        stride = size_of(Vertex),
        inputRate = .VERTEX,
    };
    vertexAttributes := [3]vk.VertexInputAttributeDescription {
        { location = 0, binding = 0, format = .R32G32B32_SFLOAT },
        { location = 1, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(Vertex, normal)) },
        { location = 2, binding = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(Vertex, uv)) },
    };
    vertexInputState := vk.PipelineVertexInputStateCreateInfo {
        sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        vertexBindingDescriptionCount = 1,
        pVertexBindingDescriptions = &vertexBinding,
        vertexAttributeDescriptionCount = u32(len(vertexAttributes)),
        pVertexAttributeDescriptions = raw_data(vertexAttributes[:]),
    };
    inputAssemblyState := vk.PipelineInputAssemblyStateCreateInfo {
        sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        topology = .TRIANGLE_LIST,
    };
    dynamicStates := [2]vk.DynamicState{ .VIEWPORT, .SCISSOR };
    dynamicState := vk.PipelineDynamicStateCreateInfo {
        sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        dynamicStateCount = 2,
        pDynamicStates = raw_data(dynamicStates[:]),
    };
    viewportState := vk.PipelineViewportStateCreateInfo {
        sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        viewportCount = 1,
        scissorCount = 1,
    };
    rasterizationState := vk.PipelineRasterizationStateCreateInfo {
        sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        lineWidth = 1.0,
    };
    multisampleState := vk.PipelineMultisampleStateCreateInfo {
        sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        rasterizationSamples = { ._1 },
    };
    depthStencilState := vk.PipelineDepthStencilStateCreateInfo {
        sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        depthTestEnable = true,
        depthWriteEnable = true,
        depthCompareOp = .LESS_OR_EQUAL,
    };
    blendAttachment := vk.PipelineColorBlendAttachmentState {
        colorWriteMask = { .R, .G, .B, .A },
    };
    colorBlendState := vk.PipelineColorBlendStateCreateInfo {
        sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        attachmentCount = 1,
        pAttachments = &blendAttachment,
    };
    colorAttachmentFormat := imageFormat;
    renderingCI := vk.PipelineRenderingCreateInfo {
        sType = .PIPELINE_RENDERING_CREATE_INFO,
        colorAttachmentCount = 1,
        pColorAttachmentFormats = &colorAttachmentFormat,
        depthAttachmentFormat = depthFormat,
    };
    pipelineCI := vk.GraphicsPipelineCreateInfo {
        sType = .GRAPHICS_PIPELINE_CREATE_INFO,
        pNext = &renderingCI,
        stageCount = 2,
        pStages = raw_data(shaderStages[:]),
        pVertexInputState = &vertexInputState,
        pInputAssemblyState = &inputAssemblyState,
        pViewportState = &viewportState,
        pRasterizationState = &rasterizationState,
        pMultisampleState = &multisampleState,
        pDepthStencilState = &depthStencilState,
        pColorBlendState = &colorBlendState,
        pDynamicState = &dynamicState,
        layout = pipelineLayout,
    };
    pipeline: vk.Pipeline;
    chk(vk.CreateGraphicsPipelines(device, 0, 1, &pipelineCI, nil, &pipeline));
    defer vk.DestroyPipeline(device, pipeline, nil)
    //= END: Pipeline

    frameIndex: u32 = 0;
    imageIndex: u32 = 0;
    updateSwapchain := false;
    camPos := glm.vec3{ 0.0, 0.0, -6.0 };
    objectRotations: [3]glm.vec3;

    //=========================================================================

    //=== Render loop =========================================================

    lastTime : u64 = sdl.GetTicks();
    quit := false;
    for !quit {
        //=== Wait on fence ===================================================

        chk(vk.WaitForFences(device, 1, &fences[frameIndex], true, max(u64)));
        chk(vk.ResetFences(device, 1, &fences[frameIndex]));

        //=====================================================================

        //=== Acquire next image ==============================================

        acquireResult := vk.AcquireNextImageKHR(device, swapchain, max(u64), imageAcquiredSemaphores[frameIndex], 0, &imageIndex);
        if acquireResult == .ERROR_OUT_OF_DATE_KHR {
            updateSwapchain = true;
        } else {
            chk(acquireResult);
        }

        //=====================================================================

        //=== Update shader data ==============================================

        shaderData.projection = glm.mat4Perspective(glm.radians_f32(45.0), f32(windowSizeX) / f32(windowSizeY), 0.1, 32.0);
        shaderData.view = glm.mat4Translate(camPos);
        for i := 0; i < 3; i += 1 {
            instancePos := glm.vec3{ f32(i - 1) * 3.0, 0.0, 0.0 };
            rot := glm.quatAxisAngle(glm.vec3{1, 0, 0}, objectRotations[i].x) * glm.quatAxisAngle(glm.vec3{0, 1, 0}, objectRotations[i].y) * glm.quatAxisAngle(glm.vec3{0, 0, 1}, objectRotations[i].z);
            shaderData.model[i] = glm.mat4Translate(instancePos) * glm.mat4FromQuat(rot);
        }
        mem.copy(shaderDataBuffers[frameIndex].allocationInfo.pMappedData, &shaderData, size_of(ShaderData));

        //=====================================================================

        //=== Record command buffer ===========================================

        // Build command buffer
        cb := commandBuffers[frameIndex];
        chk(vk.ResetCommandBuffer(cb, {}));
        cbBI := vk.CommandBufferBeginInfo{ sType = .COMMAND_BUFFER_BEGIN_INFO, flags = { .ONE_TIME_SUBMIT } };
        chk(vk.BeginCommandBuffer(cb, &cbBI));
        outputBarriers := [2]vk.ImageMemoryBarrier2 {
            {
                sType = .IMAGE_MEMORY_BARRIER_2,
                srcStageMask = { .COLOR_ATTACHMENT_OUTPUT },
                dstStageMask = { .COLOR_ATTACHMENT_OUTPUT },
                dstAccessMask = { .COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE },
                oldLayout = .UNDEFINED,
                newLayout = .ATTACHMENT_OPTIMAL,
                image = swapchainImages[imageIndex],
                subresourceRange = { aspectMask = { .COLOR }, levelCount = 1, layerCount = 1 },
            },
            {
                sType = .IMAGE_MEMORY_BARRIER_2,
                srcStageMask = { .LATE_FRAGMENT_TESTS },
                srcAccessMask = { .DEPTH_STENCIL_ATTACHMENT_WRITE },
                dstStageMask = { .EARLY_FRAGMENT_TESTS },
                dstAccessMask = { .DEPTH_STENCIL_ATTACHMENT_WRITE },
                oldLayout = .UNDEFINED,
                newLayout = .ATTACHMENT_OPTIMAL,
                image = depthImage,
                subresourceRange = { aspectMask = { .DEPTH, .STENCIL }, levelCount = 1, layerCount = 1 },
            },
        };
        barrierDependencyInfo := vk.DependencyInfo{ sType = .DEPENDENCY_INFO, imageMemoryBarrierCount = 2, pImageMemoryBarriers = raw_data(outputBarriers[:]) };
        vk.CmdPipelineBarrier2(cb, &barrierDependencyInfo);
        colorAttachmentInfo := vk.RenderingAttachmentInfo {
            sType = .RENDERING_ATTACHMENT_INFO,
            imageView = swapchainImageViews[imageIndex],
            imageLayout = .ATTACHMENT_OPTIMAL,
            loadOp = .CLEAR,
            storeOp = .STORE,
            clearValue = { color = { float32 = { 0.0, 0.0, 0.0, 1.0 } } },
        };
        depthAttachmentInfo := vk.RenderingAttachmentInfo {
            sType = .RENDERING_ATTACHMENT_INFO,
            imageView = depthImageView,
            imageLayout = .ATTACHMENT_OPTIMAL,
            loadOp = .CLEAR,
            storeOp = .DONT_CARE,
            clearValue = { depthStencil = { depth = 1.0, stencil = 0 } },
        };
        renderingInfo := vk.RenderingInfo {
            sType = .RENDERING_INFO,
            renderArea = { extent = { width = u32(windowSizeX), height = u32(windowSizeY) } },
            layerCount = 1,
            colorAttachmentCount = 1,
            pColorAttachments = &colorAttachmentInfo,
            pDepthAttachment = &depthAttachmentInfo,
        };
        vk.CmdBeginRendering(cb, &renderingInfo);
        vp := vk.Viewport{ width = f32(windowSizeX), height = f32(windowSizeY), minDepth = 0.0, maxDepth = 1.0 };
        vk.CmdSetViewport(cb, 0, 1, &vp);
        scissor := vk.Rect2D{ extent = { width = u32(windowSizeX), height = u32(windowSizeY) } };
        vk.CmdBindPipeline(cb, .GRAPHICS, pipeline);
        vk.CmdSetScissor(cb, 0, 1, &scissor);
        vk.CmdBindDescriptorSets(cb, .GRAPHICS, pipelineLayout, 0, 1, &descriptorSetTex, 0, nil);
        vOffset : vk.DeviceSize = 0;
        vk.CmdBindVertexBuffers(cb, 0, 1, &vBuffer, &vOffset);
        vk.CmdBindIndexBuffer(cb, vBuffer, vBufSize, .UINT16);
        vk.CmdPushConstants(cb, pipelineLayout, { .VERTEX }, 0, u32(size_of(vk.DeviceAddress)), &shaderDataBuffers[frameIndex].deviceAddress);
        vk.CmdDrawIndexed(cb, u32(indexCount), 3, 0, 0, 0);
        vk.CmdEndRendering(cb);
        barrierPresent := vk.ImageMemoryBarrier2 {
            sType = .IMAGE_MEMORY_BARRIER_2,
            srcStageMask = { .COLOR_ATTACHMENT_OUTPUT },
            srcAccessMask = { .COLOR_ATTACHMENT_WRITE },
            dstStageMask = { .COLOR_ATTACHMENT_OUTPUT },
            oldLayout = .ATTACHMENT_OPTIMAL,
            newLayout = .PRESENT_SRC_KHR,
            image = swapchainImages[imageIndex],
            subresourceRange = { aspectMask = { .COLOR }, levelCount = 1, layerCount = 1 },
        };
        barrierPresentDependencyInfo := vk.DependencyInfo{ sType = .DEPENDENCY_INFO, imageMemoryBarrierCount = 1, pImageMemoryBarriers = &barrierPresent };
        vk.CmdPipelineBarrier2(cb, &barrierPresentDependencyInfo);
        chk(vk.EndCommandBuffer(cb));

        //=====================================================================

        //=== Submit command buffer ===========================================

        waitSemaphoreInfo := vk.SemaphoreSubmitInfo{ sType = .SEMAPHORE_SUBMIT_INFO, semaphore = imageAcquiredSemaphores[frameIndex], stageMask = { .COLOR_ATTACHMENT_OUTPUT } };
        commandBufferSubmitInfo := vk.CommandBufferSubmitInfo{ sType = .COMMAND_BUFFER_SUBMIT_INFO, commandBuffer = cb };
        signalSemaphoreInfo := vk.SemaphoreSubmitInfo{ sType = .SEMAPHORE_SUBMIT_INFO, semaphore = renderCompleteSemaphores[imageIndex], stageMask = { .COLOR_ATTACHMENT_OUTPUT } };
        submitInfo := vk.SubmitInfo2 {
            sType = .SUBMIT_INFO_2,
            waitSemaphoreInfoCount = 1,
            pWaitSemaphoreInfos = &waitSemaphoreInfo,
            commandBufferInfoCount = 1,
            pCommandBufferInfos = &commandBufferSubmitInfo,
            signalSemaphoreInfoCount = 1,
            pSignalSemaphoreInfos = &signalSemaphoreInfo,
        };
        chk(vk.QueueSubmit2(queue, 1, &submitInfo, fences[frameIndex]));
        frameIndex = (frameIndex + 1) % maxFramesInFlight;

        //=====================================================================

        //=== Present image ===================================================

        presentInfo := vk.PresentInfoKHR {
            sType = .PRESENT_INFO_KHR,
            waitSemaphoreCount = 1,
            pWaitSemaphores = &renderCompleteSemaphores[imageIndex],
            swapchainCount = 1,
            pSwapchains = &swapchain,
            pImageIndices = &imageIndex,
        };
        presentResult := vk.QueuePresentKHR(queue, &presentInfo);
        if presentResult == .ERROR_OUT_OF_DATE_KHR {
            updateSwapchain = true;
        } else {
            chk(presentResult);
        }

        //=====================================================================

        //=== Poll events =====================================================

        elapsedTime := f32(sdl.GetTicks() - lastTime) / 1000.0;
        lastTime = sdl.GetTicks();
        for event: sdl.Event; sdl.PollEvent(&event); {
            // Exit loop if the application is about to close
            if event.type == sdl.EventType.QUIT {
                quit = true;
                break;
            }
            if event.type == sdl.EventType.MOUSE_MOTION {
                if .LEFT in event.motion.state {
                    objectRotations[shaderData.selected].x -= event.motion.yrel * elapsedTime;
                    objectRotations[shaderData.selected].y += event.motion.xrel * elapsedTime;
                }
            }
            if event.type == sdl.EventType.MOUSE_WHEEL {
                camPos.z += event.wheel.y * elapsedTime * 10.0;
            }
            if event.type == sdl.EventType.KEY_DOWN {
                if event.key.key == sdl.K_PLUS || event.key.key == sdl.K_KP_PLUS {
                    shaderData.selected = shaderData.selected + 1 if shaderData.selected < 2 else 0;
                }
                if event.key.key == sdl.K_MINUS || event.key.key == sdl.K_KP_MINUS {
                    shaderData.selected = shaderData.selected - 1 if shaderData.selected > 0 else 2;
                }
            }
            // Window resize
            if event.type == sdl.EventType.WINDOW_RESIZED {
                updateSwapchain = true;
            }
        }

        //=====================================================================

        //=== Recreate swapchain ==============================================

        if updateSwapchain {
            w_size, h_size: i32;
            sdl.GetWindowSize(window, &w_size, &h_size);
            windowSizeX = int(w_size);
            windowSizeY = int(h_size);
            updateSwapchain = false;
            chk(vk.DeviceWaitIdle(device));
            chk(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(devices[device_index], surface, &surfaceCaps));
            swapchainCI.oldSwapchain = swapchain;
            swapchainCI.imageExtent = { width = u32(windowSizeX), height = u32(windowSizeY) };
            chk(vk.CreateSwapchainKHR(device, &swapchainCI, nil, &swapchain));
            for i in 0 ..< imageCount {
                vk.DestroyImageView(device, swapchainImageViews[i], nil)
            }
            chk(vk.GetSwapchainImagesKHR(device, swapchain, &imageCount, nil));
            delete(swapchainImages);
            swapchainImages = make([]vk.Image, imageCount);
            chk(vk.GetSwapchainImagesKHR(device, swapchain, &imageCount, raw_data(swapchainImages)));
            delete(swapchainImageViews);
            swapchainImageViews = make([]vk.ImageView, imageCount);
            for i in 0 ..< imageCount {
                viewCI := vk.ImageViewCreateInfo {
                    sType = .IMAGE_VIEW_CREATE_INFO,
                    image = swapchainImages[i],
                    viewType = .D2,
                    format = imageFormat,
                    subresourceRange = { aspectMask = { .COLOR }, levelCount = 1, layerCount = 1 },
                };
                chk(vk.CreateImageView(device, &viewCI, nil, &swapchainImageViews[i]));
            }
            for semaphore in renderCompleteSemaphores {
                vk.DestroySemaphore(device, semaphore, nil)
            }
            resize(&renderCompleteSemaphores, int(imageCount));
            for &semaphore in renderCompleteSemaphores {
                chk(vk.CreateSemaphore(device, &semaphoreCI, nil, &semaphore));
            }
            vk.DestroySwapchainKHR(device, swapchainCI.oldSwapchain, nil);
            vma.DestroyImage(allocator, depthImage, depthImageAllocation);
            vk.DestroyImageView(device, depthImageView, nil);
            depthImageCI.extent = { width = u32(windowSizeX), height = u32(windowSizeY), depth = 1 };
            allocCI := vma.AllocationCreateInfo{ flags = { .DEDICATED_MEMORY }, usage = .AUTO };
            chk(vma.CreateImage(allocator, depthImageCI, allocCI, &depthImage, &depthImageAllocation, nil));
            viewCI := vk.ImageViewCreateInfo {
                sType = .IMAGE_VIEW_CREATE_INFO,
                image = depthImage,
                viewType = .D2,
                format = depthFormat,
                subresourceRange = { aspectMask = { .DEPTH }, levelCount = 1, layerCount = 1 },
            };
            chk(vk.CreateImageView(device, &viewCI, nil, &depthImageView));
        }

        //=====================================================================
    }

    //=== (END) Render loop ===================================================
}
