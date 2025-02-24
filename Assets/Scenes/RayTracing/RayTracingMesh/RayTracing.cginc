﻿
float4 _DirectionalLight;
float2 _PixelOffset;


static const float PI = 3.14159265f;
static const float EPSILON = 1e-8;
samplerCUBE _Cubemap;


float3 _AmbientColor;
float3 _DiffuseColor;
float3 _SpecularColor;
float3 _RefractedColor;
float3 _ReflectedColor;
// 反射率
float _ReflectiveIndex;
// 折射率
float _RefractiveIndex;
//-------------------------------------
//- Object Struct
struct Sphere
{
    float3 position;
    float radius;
    float3 albedo;
    float3 specular;
    float smoothness;
    float3 emission;
};

//-------------------------------------
//- UTILITY

float sdot(float3 x, float3 y, float f = 1.0f)
{
    return saturate(dot(x, y) * f);
}

float energy(float3 color)
{
    return dot(color, 1.0f / 3.0f);
}

//-------------------------------------
//- RANDOMNESS
float _Seed;
float2 _Pixel;

float rand()
{
    float result = frac(sin(_Seed / 100.0f * dot(_Pixel, float2(12.9898f, 78.233f))) * 43758.5453f);
    _Seed += 1.0f;
    return result;
}


//-------------------------------------
//- MESHES

struct MeshObject
{
    float4x4 localToWorldMatrix;
    int indicesOffset;
    int indicesCount;
};

StructuredBuffer<MeshObject> _MeshObjects;
StructuredBuffer<float3> _Vertices;
StructuredBuffer<int> _Indices;

int _MeshIndex;
//-------------------------------------
//- RAY

struct Ray
{
    float3 origin;
    float3 direction;
    float3 energy;
};

Ray CreateRay(float3 origin, float3 direction)
{
    Ray ray;
    ray.origin = origin;
    ray.direction = direction;
    ray.energy = float3(1.0f, 1.0f, 1.0f);
    return ray;
}

Ray CreateCameraRay(float2 uv)
{
    // Transform the camera origin to world space
    float3 origin = mul(UNITY_MATRIX_I_V, float4(0.0f, 0.0f, 0.0f, 1.0f)).xyz;
    
    // Invert the perspective projection of the view-space position
    float3 direction = mul(unity_CameraInvProjection, float4(uv, 0.0f, 1.0f)).xyz;
    // Transform the direction from camera to world space and normalize
    direction = mul(UNITY_MATRIX_I_V, float4(direction, 0.0f)).xyz;
    direction = normalize(direction);

    return CreateRay(origin, direction);
}


//-------------------------------------
//- RAYHIT

struct RayHit
{
    float3 position;
    float distance;
    float3 normal;
    float3 albedo;
    float3 specular;
    float smoothness;
    float3 emission;
};

RayHit CreateRayHit()
{
    RayHit hit;
    hit.position = float3(0.0f, 0.0f, 0.0f);
    hit.distance = 1.#INF;
    hit.normal = float3(0.0f, 0.0f, 0.0f);
    hit.albedo = float3(0.0f, 0.0f, 0.0f);
    hit.specular = float3(0.0f, 0.0f, 0.0f);
    hit.smoothness = 0.0f;
    hit.emission = float3(0.0f, 0.0f, 0.0f);
    return hit;
}


//-------------------------------------
//- INTERSECTION

void IntersectGroundPlane(Ray ray, inout RayHit bestHit)
{
    // Calculate distance along the ray where the ground plane is intersected
    float t = -ray.origin.y / ray.direction.y;
    if (t > 0 && t < bestHit.distance)
    {
        bestHit.distance = t;
        bestHit.position = ray.origin + t * ray.direction;
        bestHit.normal = float3(0.0f, 1.0f, 0.0f);
        bestHit.albedo = 0.5f;
        bestHit.specular = 0.03f;
        bestHit.smoothness = 0.2f;
        bestHit.emission = float3(0.0f, 0.0f, 0.0f);
    }
}

void IntersectSphere(Ray ray, inout RayHit bestHit, Sphere sphere)
{
    // Calculate distance along the ray where the sphere is intersected
    float3 d = ray.origin - sphere.position;
    float p1 = -dot(ray.direction, d);
    float p2sqr = p1 * p1 - dot(d, d) + sphere.radius * sphere.radius;
    if (p2sqr < 0)
    return;
    float p2 = sqrt(p2sqr);
    float t = p1 - p2 > 0 ? p1 - p2 : p1 + p2;
    if (t > 0 && t < bestHit.distance)
    {
        bestHit.distance = t;
        bestHit.position = ray.origin + t * ray.direction;
        bestHit.normal = normalize(bestHit.position - sphere.position);
        bestHit.albedo = sphere.albedo;
        bestHit.specular = sphere.specular;
        bestHit.smoothness = sphere.smoothness;
        bestHit.emission = sphere.emission;
    }
}

bool IntersectTriangle_MT97(Ray ray, float3 vert0, float3 vert1, float3 vert2,
inout float t, inout float u, inout float v)
{
    // find vectors for two edges sharing vert0
    float3 edge1 = vert1 - vert0;
    float3 edge2 = vert2 - vert0;

    // begin calculating determinant - also used to calculate U parameter
    float3 pvec = cross(ray.direction, edge2);

    // if determinant is near zero, ray lies in plane of triangle
    float det = dot(edge1, pvec);

    // use backface culling
    if (det < EPSILON)
    return false;
    float inv_det = 1.0f / det;

    // calculate distance from vert0 to ray origin
    float3 tvec = ray.origin - vert0;

    // calculate U parameter and test bounds
    u = dot(tvec, pvec) * inv_det;
    if (u < 0.0 || u > 1.0f)
    return false;

    // prepare to test V parameter
    float3 qvec = cross(tvec, edge1);

    // calculate V parameter and test bounds
    v = dot(ray.direction, qvec) * inv_det;
    if (v < 0.0 || u + v > 1.0f)
    return false;

    // calculate t, ray intersects triangle
    t = dot(edge2, qvec) * inv_det;

    return true;
}

void IntersectMeshObject(Ray ray, inout RayHit bestHit, MeshObject meshObject)
{
    uint offset = meshObject.indicesOffset;
    uint count = offset +meshObject.indicesCount;
    
    for (uint i = offset; i < count; i += 3)
    {
        float3 v0 = (mul(meshObject.localToWorldMatrix, float4(_Vertices[_Indices[i]], 1))).xyz;
        float3 v1 = (mul(meshObject.localToWorldMatrix, float4(_Vertices[_Indices[i + 1]], 1))).xyz;
        float3 v2 = (mul(meshObject.localToWorldMatrix, float4(_Vertices[_Indices[i + 2]], 1))).xyz;

        float t, u, v;
        if (IntersectTriangle_MT97(ray, v0, v1, v2, t, u, v))
        {
            if (t > 0 && t < bestHit.distance)
            {
                bestHit.distance = t;
                bestHit.position = ray.origin + t * ray.direction;
                bestHit.normal = normalize(cross(v1 - v0, v2 - v0));
                bestHit.albedo = 0.0f;
                bestHit.specular = 0.65f;
                bestHit.smoothness = 0.99f;
                bestHit.emission = 0.0f;
            }
        }
    }
}

//-------------------------------------
//- TRACE

RayHit Trace(Ray ray)
{
    RayHit bestHit = CreateRayHit();
    
    // // Trace mesh objects
    // IntersectMeshObject(ray, bestHit, _MeshObjects[_MeshIndex]);
    

    uint count, stride, i;

    // Trace mesh objects
    _MeshObjects.GetDimensions(count, stride);
    for (i = 0; i < count; i++)
    {
        IntersectMeshObject(ray, bestHit, _MeshObjects[i]);
    }

    return bestHit;
}


//-------------------------------------
//- SAMPLING
float3x3 GetTangentSpace(float3 normal)
{
    // Choose a helper vector for the cross product
    float3 helper = float3(1, 0, 0);
    if (abs(normal.x) > 0.99f)
    helper = float3(0, 0, 1);

    // Generate vectors
    float3 tangent = normalize(cross(normal, helper));
    float3 binormal = normalize(cross(normal, tangent));
    return float3x3(tangent, binormal, normal);
}

float3 SampleHemisphere(float3 normal, float alpha)
{
    // Sample the hemisphere, where alpha determines the kind of the sampling
    float cosTheta = pow(rand(), 1.0f / (alpha + 1.0f));
    float sinTheta = sqrt(1.0f - cosTheta * cosTheta);
    float phi = 2 * PI * rand();
    float3 tangentSpaceDir = float3(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);

    // Transform direction to world space
    return mul(tangentSpaceDir, GetTangentSpace(normal));
}

//-------------------------------------
//- SHADE
float3 SampleCubemap(float3 direction)
{
    return texCUBElod(_Cubemap, float4(direction, 0)).xyz;
}

float SmoothnessToPhongAlpha(float s)
{
    return pow(1000.0f, s * s);
}

// 折射
float Refract(float3 i, float3 n, float eta, inout float3 o)
{
    float cosi = dot(-i, n);
    float cost2 = 1.0f - eta * eta * (1 - cosi * cosi);
    
    o = eta * i + ((eta * cosi - sqrt(cost2)) * n);
    return 1 - step(cost2, 0);
}

// 菲涅尔
float3 FresnelSchlick(float3 H,float3 V,float3 F0) {
    float cosTheta = saturate(dot(H, V));
    return F0 + (1.0 - F0)*pow(1.0 - cosTheta, 5.0);
}

float3 Shade(inout Ray ray, RayHit hit)
{
    if (hit.distance < 1.#INF)
    {
        float3 specular = float3(0, 0, 0);

        float refractiveIndex;
        float3 normal;
        // out
        if (dot(ray.direction, hit.normal) > 0)
        {
            normal = -hit.normal;
            refractiveIndex = _RefractiveIndex;
        }
        // in
        else
        {
            normal = hit.normal;
            refractiveIndex = 1.0 / _RefractiveIndex;
        }
        ray.origin = hit.position + hit.normal * 0.001f;
        ray.direction = reflect(ray.direction, hit.normal);

        // 菲涅尔反射
        float3 fresnel = FresnelSchlick(normal, ray.direction, _ReflectiveIndex);
        // 折射
        // float3 refraction = refract(rayTemp.direction, normal, refractiveIndex);
        float3 refraction;
        float refracted = Refract(ray.direction, normal, refractiveIndex, refraction);

        float3 diffuse = saturate(dot(hit.normal, _DirectionalLight.xyz) * -1) * _DirectionalLight.w * _ReflectiveIndex;
        // lerp(diffuse, reflection, saturate(fresnel))
        // 折射
        // if (refracted == 1.0)
        // {
            //     ray.direction = refraction;
            //     ray.energy *= 1 - fresnel;
            //     specular = diffuse;
        // }
        // // 全反射
        // else
        // {
            //     ray.direction = reflect(ray.direction, normal);
            //     // ray.energy *= fresnel;
        // }
        ray.energy *= _SpecularColor;

        // float3 cubeColor = SampleCubemap(ray.direction);

        // return 0;
        return diffuse;


        // Calculate chances of diffuse and specular reflection
        // hit.albedo = min(1.0f - _Specular, _Albedo);
        // float specChance = energy(_Specular);
        // float diffChance = energy(hit.albedo);

        // Specular reflection
        // ray.origin = hit.position + hit.normal * 0.001f;
        // float alpha = SmoothnessToPhongAlpha(hit.smoothness);
        // ray.direction = SampleHemisphere(reflect(ray.direction, hit.normal), alpha);
        // float f = (alpha + 2) / (alpha + 1);
        // ray.energy *= (1.0f / specChance) * _Specular * sdot(hit.normal, ray.direction, f);
        // return 0.0f;

        // Diffuse reflection
        // ray.origin = hit.position + hit.normal * 0.001f;
        // ray.direction = SampleHemisphere(hit.normal, 1.0f);
        // ray.energy *= (1.0f / diffChance) * hit.albedo;
        // return 0.0f;



        // // Roulette-select the ray's path
        // float roulette = rand();
        // if (roulette < specChance)
        // {
            //     // Specular reflection
            //     ray.origin = hit.position + hit.normal * 0.001f;
            //     float alpha = SmoothnessToPhongAlpha(hit.smoothness);
            //     ray.direction = SampleHemisphere(reflect(ray.direction, hit.normal), alpha);
            //     float f = (alpha + 2) / (alpha + 1);
            //     ray.energy *= (1.0f / specChance) * _Specular * sdot(hit.normal, ray.direction, f);
        // }
        // else if (diffChance > 0 && roulette < specChance + diffChance)
        // {
            //     // Diffuse reflection
            //     ray.origin = hit.position + hit.normal * 0.001f;
            //     ray.direction = SampleHemisphere(hit.normal, 1.0f);
            //     ray.energy *= (1.0f / diffChance) * hit.albedo;
        // }
        // else
        // {
            //     // Terminate ray
            //     ray.energy = 0.0f;
        // }

        // return 0.0f;
    }
    else
    {
        ray.energy = 0.0f;
        float3 cubeColor = SampleCubemap(ray.direction);
        return cubeColor;
    }
}
