Shader "Custom/RayTracingShader"
{
	SubShader
	{
		Cull Off ZWrite Off ZTest Always

		Pass
		{
			CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			#include "UnityCG.cginc"

			struct appdata
			{
				float4 vertex : POSITION;
				float2 uv : TEXCOORD0;
			};

			struct v2f
			{
				float2 uv : TEXCOORD0;
				float4 vertex : SV_POSITION;
			};

			struct Ray
			{
				float3 origin;
				float3 dir;
			};

			struct RayTracingMaterial
			{
				float4 colour;
				float4 emissionColour;
				float4 specularColour;
				float emissionStrength;
				float smoothness;
				float specularProbability;
			};

			struct HitInfo
			{
				bool didHit;
				float dst;
				float3 hitPoint;
				float3 normal;
				RayTracingMaterial material;
			};

			struct Sphere
			{
				float3 position;
				float radius;
				RayTracingMaterial material;
			};

			struct Triangle
			{
				float3 posA, posB, posC;
				float3 normalA, normalB, normalC;
			};

			struct MeshInfo
			{
				uint firstTriangleIndex;
				uint numTriangles;
				RayTracingMaterial material;
				float3 boundsMin;
				float3 boundsMax;
			};

			v2f vert(appdata v)
			{
				v2f o;
				o.vertex = UnityObjectToClipPos(v.vertex);
				o.uv = v.uv;
				return o;
			}

			float3 ViewParams;
			float4x4 CamLocalToWorldMatrix;

			StructuredBuffer<Sphere> Spheres;
			int NumSpheres;

			StructuredBuffer<Triangle> Triangles;
			StructuredBuffer<MeshInfo> AllMeshInfo;
			int NumMeshes;

			int MaxBounceCount;
			int NumRaysPerPixel;
			int Frame;

			// Environment Settings
			int EnvironmentEnabled;
			float4 GroundColour;
			float4 SkyColourHorizon;
			float4 SkyColourZenith;
			float SunFocus;
			float SunIntensity;

			HitInfo RaySphere(Ray ray, float3 sphereCentre, float sphereRadius)
			{
				HitInfo hitInfo = (HitInfo)0;
				float3 offsetRayOrigin = ray.origin - sphereCentre;

				float a = dot(ray.dir, ray.dir);
				float b = 2 * dot(offsetRayOrigin, ray.dir);
				float c = dot(offsetRayOrigin, offsetRayOrigin) - sphereRadius * sphereRadius;

				float discriminant = b * b - 4 * a * c;

				if (discriminant >= 0)
				{
					float dst = (-b - sqrt(discriminant)) / (2 * a);

					if (dst >= 0)
					{
						hitInfo.didHit = true;
						hitInfo.dst = dst;
						hitInfo.hitPoint = ray.origin + ray.dir * dst;
						hitInfo.normal = normalize(hitInfo.hitPoint - sphereCentre);
					}
				}
				return hitInfo;
			}

			HitInfo RayTriangle(Ray ray, Triangle tri)
			{
				float3 edgeAB = tri.posB - tri.posA;
				float3 edgeAC = tri.posC - tri.posA;
				float3 normalVector = cross(edgeAB, edgeAC);
				float3 ao = ray.origin - tri.posA;
				float3 dao = cross(ao, ray.dir);

				float determinant = -dot(ray.dir, normalVector);
				float invDet = 1 / determinant;

				// Calculate dst to triangle & barycentric coordinates of intersection point
				float dst = dot(ao, normalVector) * invDet;
				float u = dot(edgeAC, dao) * invDet;
				float v = -dot(edgeAB, dao) * invDet;
				float w = 1 - u - v;

				// Initialize hit info
				HitInfo hitInfo;
				hitInfo.didHit = determinant >= 1E-6 && dst >= 0 && u >= 0 && v >= 0 && w >= 0;
				hitInfo.hitPoint = ray.origin + ray.dir * dst;
				hitInfo.normal = normalize(tri.normalA * w + tri.normalB * u + tri.normalC * v);
				hitInfo.dst = dst;
				return hitInfo;
			}

			bool RayBoundingBox(Ray ray, float3 boxMin, float3 boxMax)
			{
				float3 invDir = 1 / ray.dir;
				float3 tMin = (boxMin - ray.origin) * invDir;
				float3 tMax = (boxMax - ray.origin) * invDir;
				float3 t1 = min(tMin, tMax);
				float3 t2 = max(tMin, tMax);
				float tNear = max(max(t1.x, t1.y), t1.z);
				float tFar = min(min(t2.x, t2.y), t2.z);
				return tNear <= tFar;
			};

			HitInfo CalculateRayCollision(Ray ray)
			{
				HitInfo closestHit = (HitInfo)0;
				// We haven't hit anything yet, so 'closest' hit is infinitely far away
				closestHit.dst = 1.#INF;

				// Raycast against all spheres and keep info about the closest hit
				for (int i = 0; i < NumSpheres; i++)
				{
					Sphere sphere = Spheres[i];
					HitInfo hitInfo = RaySphere(ray, sphere.position, sphere.radius);

					if (hitInfo.didHit && hitInfo.dst < closestHit.dst)
					{
						closestHit = hitInfo;
						closestHit.material = sphere.material;
					}
				}

				for (int meshIndex = 0; meshIndex < NumMeshes; meshIndex++)
				{
					MeshInfo meshInfo = AllMeshInfo[meshIndex];
					if (!RayBoundingBox(ray, meshInfo.boundsMin, meshInfo.boundsMax)) {
						continue;
					}

					for (uint i = 0; i < meshInfo.numTriangles; i++) {
						int triIndex = meshInfo.firstTriangleIndex + i;
						Triangle tri = Triangles[triIndex];
						HitInfo hitInfo = RayTriangle(ray, tri);

						if (hitInfo.didHit && hitInfo.dst < closestHit.dst)
						{
							closestHit = hitInfo;
							closestHit.material = meshInfo.material;
						}
					}
				}
				return closestHit;
			}

			float RandomValue(inout uint state)
			{
				state = state * 747796405 + 2891336354;
				uint result = ((state >> ((state >> 28) + 4)) ^ state) * 277803737;
				result = (result >> 22) ^ result;
				return result / 4294967295.0;
			}

			float RandomValueNormalDistribution(inout uint state)
			{
				float theta = 2 * 3.1415926 * RandomValue(state);
				float rho = sqrt(-2 * log(RandomValue(state)));
				return rho * cos(theta);
			}

			float3 RandomDirection(inout uint state)
			{
				float x = RandomValueNormalDistribution(state);
				float y = RandomValueNormalDistribution(state);
				float z = RandomValueNormalDistribution(state);
				return normalize(float3(x, y, z));
			}

			float3 RandomHemisphereDirection(float3 normal, inout uint rngState)
			{
				float3 dir = RandomDirection(rngState);
				return dir * sign(dot(normal, dir));
			}

			float3 GetEnvironmentLight(Ray ray)
			{
				if (!EnvironmentEnabled)
				{
					return 0;
				}

				float skyGradientT = pow(smoothstep(0, 0.4, ray.dir.y), 0.35);
				float groundToSkyT = smoothstep(-0.01, 0, ray.dir.y);
				float3 skyGradient = lerp(SkyColourHorizon, SkyColourZenith, skyGradientT);
				float sun = pow(max(0, dot(ray.dir, _WorldSpaceLightPos0.xyz)), SunFocus) * SunIntensity;
				// Combine ground, sky, and sun
				float3 composite = lerp(GroundColour, skyGradient, groundToSkyT) + sun * (groundToSkyT >= 1);
				return composite;
			}

			float3 Trace(Ray ray, inout uint rngState)
			{
				float3 incomingLight = 0;
				float3 rayColour = 1;

				for (int i = 0; i <= MaxBounceCount; i++)
				{
					HitInfo hitInfo = CalculateRayCollision(ray);
					RayTracingMaterial material = hitInfo.material;
					if (hitInfo.didHit)
					{
						bool isSpecularBounce = material.specularProbability >= RandomValue(rngState);

						ray.origin = hitInfo.hitPoint;
						float3 diffuseDir = normalize(hitInfo.normal + RandomDirection(rngState));
						float3 specularDir = reflect(ray.dir, hitInfo.normal);
						ray.dir = lerp(diffuseDir, specularDir, material.smoothness * isSpecularBounce);

						float3 emittedLight = material.emissionColour * material.emissionStrength;
						incomingLight += emittedLight * rayColour;
						rayColour *= lerp(material.colour, material.specularColour, isSpecularBounce);
					}
					else
					{
						incomingLight += GetEnvironmentLight(ray) * rayColour;
						break;
					}
				}

				return incomingLight;
			}

			// Run for every pixel in the display
			float4 frag(v2f i) : SV_Target
			{
				uint2 numPixels = _ScreenParams.xy;
				uint2 pixelCoord = i.uv * numPixels;
				uint pixelIndex = pixelCoord.y * numPixels.x + pixelCoord.x;
				uint rngState = pixelIndex + Frame * 719465;

				float3 viewPointLocal = float3(i.uv - 0.5, 1) * ViewParams;
				float3 viewPoint = mul(CamLocalToWorldMatrix, float4(viewPointLocal, 1));

				Ray ray;
				ray.origin = _WorldSpaceCameraPos;
				ray.dir = normalize(viewPoint - ray.origin);
				
				float3 totalIncomingLight = 0;

				for (int rayIndex = 0; rayIndex < NumRaysPerPixel; rayIndex++)
				{
					totalIncomingLight += Trace(ray, rngState);
				}

				float3 pixelCol = totalIncomingLight / NumRaysPerPixel;
				return float4(pixelCol, 1);
			}

			ENDCG
		}
	}
}
