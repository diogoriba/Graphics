using System;
using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.VFX;
using UnityEngine.Rendering;
using NUnit.Framework;
using UnityEngine.TestTools;
using static PerformanceTestUtils;
using Unity.PerformanceTesting;
using UnityEngine.VFX.Test;
using UnityEngine.TestTools.Graphics;
using Object = UnityEngine.Object;

namespace UnityEditor.VFX.PerformanceTest
{
    public class VFXRuntimePerformanceTests : PerformanceTests
    {
        const int WarmupCount = 20;
        const int GlobalTimeout = 120 * 1000;

        static IEnumerable<CounterTestDescription> GetCounterTests()
        {
            yield break;
        }


        static IEnumerable<MemoryTestDescription> GetMemoryTests()
        {
            yield break;
        }

        static IEnumerable<string> allMarkerName
        {
            get
            {
                yield return "VFX.MeshSystem.Render";
                yield return "VFX.ParticleSystem.CopySpawnEventAttribute";
                yield return "VFX.ParticleSystem.CopyEventListCountCommand";
                yield return "VFX.ParticleSystem.CopyCount";
                yield return "VFX.ParticleSystem.ResetCount";
                yield return "VFX.ParticleSystem.CopyIndirectCount";
                yield return "VFX.ParticleSystem.UpdateMaterial";
                yield return "VFX.ParticleSystem.Init";
                yield return "VFX.ParticleSystem.Update";
                yield return "VFX.ParticleSystem.PerStripUpdate";
                yield return "VFX.ParticleSystem.RenderPoint";
                yield return "VFX.ParticleSystem.RenderPointIndirect";
                yield return "VFX.ParticleSystem.RenderLine";
                yield return "VFX.ParticleSystem.RenderLineIndirect";
                yield return "VFX.ParticleSystem.RenderTriangle";
                yield return "VFX.ParticleSystem.RenderTriangleIndirect";
                yield return "VFX.ParticleSystem.RenderQuad";
                yield return "VFX.ParticleSystem.RenderQuadIndirect";
                yield return "VFX.ParticleSystem.RenderOctagon";
                yield return "VFX.ParticleSystem.RenderOctagonIndirect";
                yield return "VFX.ParticleSystem.RenderHexahedron";
                yield return "VFX.ParticleSystem.RenderHexahedronIndirect";
                yield return "VFX.ParticleSystem.RenderMesh";
                yield return "VFX.ParticleSystem.RenderMeshIndirect";
                yield return "VFX.Update";
                yield return "VFX.PrepareCamera";
                yield return "VFX.ProcessCamera";
                yield return "VFX.FillIndirectRenderArgs";
                yield return "VFX.CopyBuffer";
                yield return "VFX.InitializeDeadListBuffer";
                yield return "VFX.ZeroInitializeBuffer";
                yield return "VFX.SortBuffer";
                yield return "VFX.NotifyModifiedAsset";
                yield return "VFX.NotifyDeletedAsset";
                yield return "VFX.DefaultCommandBuffer";
                yield return "VFX.RegisterGizmos";
            }
        }

        static IEnumerable<ProfilingSampler> allMarker
        {
            get
            {
                foreach (var marker in allMarkerName)
                {
                    yield return new ProfilingSampler(marker);
                }
            }
        }

        [Timeout(GlobalTimeout), Version("1"), UnityTest, UseGraphicsTestCases, PrebuildSetup("SetupGraphicsTestCases"), Performance]
        public IEnumerator Counters(GraphicsTestCase testCase)
        {
            UnityEngine.SceneManagement.SceneManager.LoadScene(testCase.ScenePath);
            yield return null;

            float simulateTime = VFXGraphicsTestSettings.defaultSimulateTime;
            int captureFrameRate = VFXGraphicsTestSettings.defaultCaptureFrameRate;

            var testSettingsInScene = Object.FindObjectOfType<GraphicsTestSettings>();
            var vfxTestSettingsInScene = Object.FindObjectOfType<VFXGraphicsTestSettings>();

            if (vfxTestSettingsInScene != null)
            {
                simulateTime = vfxTestSettingsInScene.simulateTime;
                captureFrameRate = vfxTestSettingsInScene.captureFrameRate;
            }
            float period = 1.0f / captureFrameRate;
            int waitFrameCount = (int)(simulateTime / period);

            //Manual warmup for VFX (equivalent state of graphicTest, ensure there is enough particle alive)
            var previousCaptureFrameRate = Time.captureFramerate;
            var previousFixedTimeStep = UnityEngine.VFX.VFXManager.fixedTimeStep;
            var previousMaxDeltaTime = UnityEngine.VFX.VFXManager.maxDeltaTime;
            while (waitFrameCount-- > 0)
                yield return null;
            Time.captureFramerate = previousCaptureFrameRate;
            UnityEngine.VFX.VFXManager.fixedTimeStep = previousFixedTimeStep;
            UnityEngine.VFX.VFXManager.maxDeltaTime = previousMaxDeltaTime;

            yield return MeasureProfilingSamplers(allMarker, WarmupCount, 300);
        }

        [Timeout(GlobalTimeout), Version("1"), UnityTest, UseGraphicsTestCases, PrebuildSetup("SetupGraphicsTestCases"), Performance]
        public IEnumerator Memory([ValueSource(nameof(GetMemoryTests))] MemoryTestDescription testDescription)
        {
            yield return ReportMemoryUsage(testDescription);
        }
    }
}
