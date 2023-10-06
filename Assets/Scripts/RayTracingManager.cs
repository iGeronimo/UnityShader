using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.XR;

[ExecuteAlways, ImageEffectAllowedInSceneView]
public class RayTracingManager : MonoBehaviour
{
    public const int TriangleLimit = 1500;

    [Header("Ray Trace Settings")]
    [SerializeField, Range(0, 32)] int maxBounceCount = 4;
    [SerializeField, Range(0, 64)] int numRaysPerPixel = 2;
    [SerializeField] EnvironmentSettings environmentSettings;

    [Header("View Settings")]
    [SerializeField] bool useShaderInSceneView;

    [Header("References")]
    [SerializeField] Shader rayTracingShader;
    [SerializeField] Shader accumulateShader;

    [Header("Info")]
    [SerializeField] int numRenderedFrames;
    [SerializeField] int numMeshChunks;
    [SerializeField] int numTriangles;

    //Materials
    Material rayTracingMaterial;
    Material accumulateMaterial;
    RenderTexture resultTexture;

    ComputeBuffer sphereBuffer;
    ComputeBuffer triangleBuffer;
    ComputeBuffer meshInfoBuffer;

    List<Triangle> allTriangles;
    List<MeshInfo> allMeshInfo;

    private void OnRenderImage(RenderTexture source, RenderTexture destination)
    {
        if (Camera.current.name != "SceneCamera")
        {
            if (useShaderInSceneView)
            {

                InitFrame();
                ShaderHelper.InitMaterial(rayTracingShader, ref rayTracingMaterial);
                UpdateCameraParams(Camera.current);

                Graphics.Blit(null, destination, rayTracingMaterial);
            }
            else
            {
                Graphics.Blit(source, destination);
            }
        }
        else
        {
            InitFrame();

            RenderTexture prevFrameCopy = RenderTexture.GetTemporary(source.width, source.height, 0, ShaderHelper.RGBA_SFloat);
            Graphics.Blit(resultTexture, prevFrameCopy);

            rayTracingMaterial.SetInt("Frame", numRenderedFrames);
            RenderTexture currentFrame = RenderTexture.GetTemporary(source.width, source.height, 0, ShaderHelper.RGBA_SFloat);
            Graphics.Blit(null, currentFrame, rayTracingMaterial);

            accumulateMaterial.SetInt("_Frame", numRenderedFrames);
            accumulateMaterial.SetTexture("_PrevFrame", prevFrameCopy);
            Graphics.Blit(currentFrame, resultTexture, accumulateMaterial);

            Graphics.Blit(resultTexture, destination);

            RenderTexture.ReleaseTemporary(currentFrame);
            RenderTexture.ReleaseTemporary(prevFrameCopy);
            RenderTexture.ReleaseTemporary(currentFrame);

            numRenderedFrames += Application.isPlaying ? 1 : 0;
        }
    }

    void InitFrame()
    {
        ShaderHelper.InitMaterial(rayTracingShader, ref rayTracingMaterial);
        ShaderHelper.InitMaterial(accumulateShader, ref accumulateMaterial);

        ShaderHelper.CreateRenderTexture(ref resultTexture, Screen.width, Screen.height, FilterMode.Bilinear, ShaderHelper.RGBA_SFloat, "Result");

        UpdateCameraParams(Camera.current);
        CreateSpheres();
        CreateMeshes();
        SetShaderParams();
    }

    private void UpdateCameraParams(Camera cam)
    {
        float planeHeight = cam.nearClipPlane * Mathf.Tan(cam.fieldOfView * 0.5f * Mathf.Deg2Rad) * 2;
        float planeWidth = planeHeight * cam.aspect;

        //Send data to shader
        rayTracingMaterial.SetVector("ViewParams", new Vector3(planeWidth, planeHeight, cam.nearClipPlane));
        rayTracingMaterial.SetMatrix("CamLocalToWorldMatrix", cam.transform.localToWorldMatrix);
    }

    void CreateSpheres()
    {
        // Create sphere data from the sphere objects in the scene
        RayTracedSphere[] sphereObjects = FindObjectsOfType<RayTracedSphere>();
        Sphere[] spheres = new Sphere[sphereObjects.Length];

        for (int i = 0; i < sphereObjects.Length; i++)
        {
            spheres[i] = new Sphere()
            {
                position = sphereObjects[i].transform.position,
                radius = sphereObjects[i].transform.localScale.x * 0.5f,
                material = sphereObjects[i].material
            };
        }

        // Create buffer containing all sphere data, and send it to the shader
        ShaderHelper.CreateStructuredBuffer(ref sphereBuffer, spheres);
        rayTracingMaterial.SetBuffer("Spheres", sphereBuffer);
        rayTracingMaterial.SetInt("NumSpheres", sphereObjects.Length);
    }

    void CreateMeshes()
    {
        RayTracedMesh[] meshObjects = FindObjectsOfType<RayTracedMesh>();

        allTriangles ??= new List<Triangle>();
        allMeshInfo ??= new List<MeshInfo>();
        allTriangles.Clear();
        allMeshInfo.Clear();

        for (int i = 0; i < meshObjects.Length; i++)
        {
            MeshChunk[] chunks = meshObjects[i].GetSubMeshes();
            foreach (MeshChunk chunk in chunks)
            {
                RayTracingMaterial material = meshObjects[i].GetMaterial(chunk.subMeshIndex);
                allMeshInfo.Add(new MeshInfo(allTriangles.Count, chunk.triangles.Length, material, chunk.bounds));
                allTriangles.AddRange(chunk.triangles);

            }
        }

        numMeshChunks = allMeshInfo.Count;
        numTriangles = allTriangles.Count;

        ShaderHelper.CreateStructuredBuffer(ref triangleBuffer, allTriangles);
        ShaderHelper.CreateStructuredBuffer(ref meshInfoBuffer, allMeshInfo);
        rayTracingMaterial.SetBuffer("Triangles", triangleBuffer);
        rayTracingMaterial.SetBuffer("AllMeshInfo", meshInfoBuffer);
        rayTracingMaterial.SetInt("NumMeshes", allMeshInfo.Count);
    }
    void SetShaderParams()
    {
        rayTracingMaterial.SetInt("MaxBounceCount", maxBounceCount);
        rayTracingMaterial.SetInt("NumRaysPerPixel", numRaysPerPixel);
        //rayTracingMaterial.SetFloat("DefocusStrength", defocusStrength);
        //rayTracingMaterial.SetFloat("DivergeStrength", divergeStrength);

        rayTracingMaterial.SetInteger("EnvironmentEnabled", environmentSettings.enabled ? 1 : 0);
        rayTracingMaterial.SetColor("GroundColour", environmentSettings.groundColour);
        rayTracingMaterial.SetColor("SkyColourHorizon", environmentSettings.skyColourHorizon);
        rayTracingMaterial.SetColor("SkyColourZenith", environmentSettings.skyColourZenith);
        rayTracingMaterial.SetFloat("SunFocus", environmentSettings.sunFocus);
        rayTracingMaterial.SetFloat("SunIntensity", environmentSettings.sunIntensity);
    }

    void OnDisable()
    {
        ShaderHelper.Release(sphereBuffer, triangleBuffer, meshInfoBuffer);
        ShaderHelper.Release(resultTexture);
    }

    void OnValidate()
    {
        maxBounceCount = Mathf.Max(0, maxBounceCount);
        numRaysPerPixel = Mathf.Max(1, numRaysPerPixel);
        environmentSettings.sunFocus = Mathf.Max(1, environmentSettings.sunFocus);
        environmentSettings.sunIntensity = Mathf.Max(0, environmentSettings.sunIntensity);
    }

}

