using System.Collections.Generic;
using UnityEngine.Profiling;
using UnityEngine.Rendering;

namespace UnityEngine.Experimental.Rendering.Universal
{
    internal struct LayerBatch
    {
        public int firstLayerID;
        public int firstLayerOrder;
        public SortingLayerRange layerRange;
        public LightStats lightStats;

        public int GetLightTextureKey(int blendStyleIndex)
        {
            return firstLayerOrder * 4 + blendStyleIndex;
        }
    }

    internal static class LayerUtility
    {
        private static List<LayerBatch> s_LayerBatches;

        private static bool CompareLightsInLayer(int layerIndex1, int layerIndex2, SortingLayer[] sortingLayers, ILight2DCullResult lightCullResult)
        {
            var layerId1 = sortingLayers[layerIndex1].id;
            var layerId2 = sortingLayers[layerIndex2].id;
            foreach (var light in lightCullResult.visibleLights)
            {
                if (light.IsLitLayer(layerId1) != light.IsLitLayer(layerId2))
                    return false;
            }
            return true;
        }

        private static int FindUpperBoundInBatch(int startLayerIndex, SortingLayer[] sortingLayers, ILight2DCullResult lightCullResult)
        {
            // start checking at the next layer
            for (var i = startLayerIndex+1; i < sortingLayers.Length; i++)
            {
                if(!CompareLightsInLayer(startLayerIndex, i, sortingLayers, lightCullResult))
                    return i-1;
            }
            return sortingLayers.Length-1;
        }

        public static List<LayerBatch> CalculateBatches(ILight2DCullResult lightCullResult)
        {
            var cachedSortingLayers = Light2DManager.GetCachedSortingLayer();
            var count = cachedSortingLayers.Length;
            s_LayerBatches ??= new List<LayerBatch>(count);

#if UNITY_EDITOR
            // we should fix. Make a non allocating version of this
            if (!Application.isPlaying && s_LayerBatches.Capacity != count)
                s_LayerBatches = new List<LayerBatch>(count);
#endif

            s_LayerBatches.Clear();

            for (var i = 0; i < cachedSortingLayers.Length;)
            {
                var layerToRender = cachedSortingLayers[i].id;
                var lightStats = lightCullResult.GetLightStatsByLayer(layerToRender);
                var layerBatch = new LayerBatch();

                // find the highest layer that share the same set of lights as this layer
                var upperLayerInBatch = FindUpperBoundInBatch(i, cachedSortingLayers, lightCullResult);
                // Some renderers override their sorting layer value with short.MinValue or short.MaxValue.
                // When drawing the first sorting layer, we should include the range from short.MinValue to layerValue.
                // Similarly, when drawing the last sorting layer, include the range from layerValue to short.MaxValue.
                var startLayerValue = (short) cachedSortingLayers[i].value;
                var lowerBound = (i == 0) ? short.MinValue : startLayerValue;
                var endLayerValue = (short) cachedSortingLayers[upperLayerInBatch].value;
                var upperBound = (upperLayerInBatch == cachedSortingLayers.Length - 1) ? short.MaxValue : endLayerValue;
                // renderer within this range share the same set of lights so they should be rendered together
                var sortingLayerRange = new SortingLayerRange(lowerBound, upperBound);

                layerBatch.firstLayerID = layerToRender;
                layerBatch.firstLayerOrder = i;
                layerBatch.layerRange = sortingLayerRange;
                layerBatch.lightStats = lightStats;

                s_LayerBatches.Add(layerBatch);

                i = upperLayerInBatch + 1;
            }

            return s_LayerBatches;
        }
    }

    internal static class LightTextureManager
    {
        private struct TextureInfo
        {
            public int nameID;
            public int key;
            public bool allocated;
        }

        private static TextureInfo[] s_AllTextureInfo;
        private static RenderTextureDescriptor s_Desc;
        private static long s_MemoryBudget;
        private static int s_TextureCount;

        public static void Init(ref RenderTextureDescriptor desc, long memoryBudget)
        {
            if (s_AllTextureInfo != null && s_MemoryBudget == memoryBudget && s_Desc.width == desc.width && s_Desc.height == desc.height)
                return;

            s_Desc = desc;
            s_MemoryBudget = memoryBudget;

            var dummyTexture = RenderTexture.GetTemporary(desc);
            dummyTexture.Create();
            var maxTextureCount = Mathf.Max((int)(memoryBudget / Profiler.GetRuntimeMemorySizeLong(dummyTexture)), 4);
            RenderTexture.ReleaseTemporary(dummyTexture);

            s_AllTextureInfo = new TextureInfo[maxTextureCount];
            for (var i = 0; i < s_AllTextureInfo.Length; ++i)
            {
                ref var textureInfo = ref s_AllTextureInfo[i];

                textureInfo.nameID = Shader.PropertyToID("_LightTexture" + i);
                textureInfo.key = -1;
                textureInfo.allocated = false;
            }
        }

        public static bool HasBudgetFor(uint textureCount)
        {
            return s_AllTextureInfo.Length - s_TextureCount >= textureCount;
        }

        public static void ResetKeys()
        {
            for (var i = 0; i < s_AllTextureInfo.Length; ++i)
            {
                ref var textureInfo = ref s_AllTextureInfo[i];
                textureInfo.key = -1;
            }

            s_TextureCount = 0;
        }

        public static RenderTargetIdentifier GetLightTexture(CommandBuffer cmd, int key)
        {
            for (var i = 0; i < s_AllTextureInfo.Length; ++i)
            {
                ref var textureInfo = ref s_AllTextureInfo[i];

                if (textureInfo.key == -1 || textureInfo.key == key)
                {
                    if (textureInfo.key == -1)
                    {
                        textureInfo.key = key;
                        s_TextureCount++;
                    }

                    if (!textureInfo.allocated)
                    {
                        cmd.GetTemporaryRT(textureInfo.nameID, s_Desc, FilterMode.Bilinear);
                        textureInfo.allocated = true;
                    }

                    return textureInfo.nameID;
                }
            }

            return BuiltinRenderTextureType.None;
        }

        public static void ReleaseLightTextures(CommandBuffer cmd)
        {
            for (var i = 0; i < s_AllTextureInfo.Length; ++i)
            {
                ref var textureInfo = ref s_AllTextureInfo[i];

                if (!textureInfo.allocated)
                    continue;

                cmd.ReleaseTemporaryRT(textureInfo.nameID);
                textureInfo.allocated = false;
            }
        }
    }
}
