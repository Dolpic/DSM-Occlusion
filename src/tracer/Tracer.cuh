#pragma once

#include "../bvh/BVH.cuh"
#include <curand_kernel.h>

class Tracer{
public:
    Tracer(Array2D<float>& data, const float pixelSize, const float exaggeration=1.0, const uint maxBounce=0);
    ~Tracer();

    void init(const bool prinInfos);
    void trace(const bool useGPU, const uint raysPerPoint, const float bias);

private:
    const float pixelSize;
    const float exaggeration;
    const uint maxBounces;
    
    BVH bvh; 
    Array2D<float>& data;
    Array2D<Point3<float>> points;
    curandState* randomState = nullptr;
};