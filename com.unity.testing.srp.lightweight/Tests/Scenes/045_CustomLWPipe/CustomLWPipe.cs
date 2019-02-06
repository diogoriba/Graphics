using System;
#if UNITY_EDITOR
using UnityEditor;
using UnityEditor.ProjectWindowCallback;
#endif
using UnityEngine;
using UnityEngine.Rendering.LWRP;
using UnityEngine.Rendering;

public class CustomLWPipe : RendererSetup
{  
    private CreateLightweightRenderTexturesPass m_CreateLightweightRenderTexturesPass;
    private RenderOpaqueForwardPass m_RenderOpaqueForwardPass;

    ForwardLights m_ForwardLights;

    public CustomLWPipe(CustomRenderGraphData data) : base(data)
    {
        m_CreateLightweightRenderTexturesPass = new CreateLightweightRenderTexturesPass();
        m_RenderOpaqueForwardPass = new RenderOpaqueForwardPass(RenderQueueRange.opaque);
        m_ForwardLights = new ForwardLights();
    }

    public override void Setup(ref RenderingData renderingData)
    {
        RenderTextureDescriptor baseDescriptor = ScriptableRenderPass.CreateRenderTextureDescriptor(ref renderingData.cameraData);
        RenderTextureDescriptor shadowDescriptor = baseDescriptor;
        shadowDescriptor.dimension = TextureDimension.Tex2D;

        RenderTargetHandle colorHandle = RenderTargetHandle.CameraTarget;
        RenderTargetHandle depthHandle = RenderTargetHandle.CameraTarget;
        
        var sampleCount = (SampleCount)renderingData.cameraData.msaaSamples;
        m_CreateLightweightRenderTexturesPass.Setup(baseDescriptor, colorHandle, depthHandle, sampleCount);
        EnqueuePass(m_CreateLightweightRenderTexturesPass);

        Camera camera = renderingData.cameraData.camera;

        RenderPassFeature.InjectionPoint injectionPoints = 0;
        foreach (var pass in m_RenderPassFeatures)
        {
            injectionPoints |= pass.injectionPoints;
        }

        m_RenderOpaqueForwardPass.Setup(baseDescriptor, colorHandle, depthHandle, GetCameraClearFlag(camera), camera.backgroundColor);
        EnqueuePass(m_RenderOpaqueForwardPass);
        
        EnqueuePasses(RenderPassFeature.InjectionPoint.AfterOpaqueRenderPasses, injectionPoints,
            baseDescriptor, colorHandle, depthHandle);
    }

    public override void SetupLights(ScriptableRenderContext context, ref RenderingData renderingData)
    {
        m_ForwardLights.Setup(context, ref renderingData);
    }
}
