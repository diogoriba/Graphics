using System;
using UnityEngine.Scripting.APIUpdating;

namespace UnityEngine.Rendering.Universal
{
    [MovedFrom("UnityEngine.Rendering.LWRP")] public class LightweightRenderPipelineEditorResources : ScriptableObject
    {
        [Serializable, ReloadGroup]
        public sealed class ShaderResources
        {
            [Reload("Shaders/Autodesk Interactive/Autodesk Interactive.shadergraph")]
            public Shader autodeskInteractivePS;

            [Reload("Shaders/Autodesk Interactive/Autodesk Interactive Transparent.shadergraph")]
            public Shader autodeskInteractiveTransparentPS;

            [Reload("Shaders/Autodesk Interactive/Autodesk Interactive Masked.shadergraph")]
            public Shader autodeskInteractiveMaskedPS;

            [Reload("Shaders/Terrain/TerrainDetailLit.shader")]
            public Shader terrainDetailLitPS;

            [Reload("Shaders/Terrain/WavingGrass.shader")]
            public Shader terrainDetailGrassPS;

            [Reload("Shaders/Terrain/WavingGrassBillboard.shader")]
            public Shader terrainDetailGrassBillboardPS;

            [Reload("Shaders/Nature/SpeedTree7.shader")]
            public Shader defaultSpeedTree7PS;

            [Reload("Shaders/Nature/SpeedTree8.shader")]
            public Shader defaultSpeedTree8PS;
        }

        [Serializable, ReloadGroup]
        public sealed class MaterialResources
        {
            [Reload("Runtime/Materials/Lit.mat")]
            public Material lit;

            [Reload("Runtime/Materials/ParticlesLit.mat")]
            public Material particleLit;

            [Reload("Runtime/Materials/TerrainLit.mat")]
            public Material terrainLit;
        }

        public ShaderResources shaders;
        public MaterialResources materials;
    }

#if UNITY_EDITOR
    [UnityEditor.CustomEditor(typeof(LightweightRenderPipelineEditorResources), true)]
    class LightweightRenderPipelineEditorResourcesEditor : UnityEditor.Editor
    {
        public override void OnInspectorGUI()
        {
            DrawDefaultInspector();

            // Add a "Reload All" button in inspector when we are in developer's mode
            if (UnityEditor.EditorPrefs.GetBool("DeveloperMode") && GUILayout.Button("Reload All"))
            {
                var resources = target as LightweightRenderPipelineEditorResources;
                resources.materials = null;
                resources.shaders = null;
                ResourceReloader.ReloadAllNullIn(target, LightweightRenderPipelineAsset.packagePath);
            }
        }
    }
#endif
}
