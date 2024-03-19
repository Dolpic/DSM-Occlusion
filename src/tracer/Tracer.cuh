#pragma once

#include "../bvh/BVH.cuh"
#include <curand_kernel.h>

class Tracer{
public:
    Tracer(Array2D<float>& data, const float pixelSize, const float exaggeration=1.0);
    ~Tracer();

    void init(const bool prinInfos);
    void trace(const bool useGPU, const uint raysPerPoint);

private:
    const float pixelSize;
    const float exaggeration;
    
    BVH bvh; 
    Array2D<float>& data;
    Array2D<Point3<float>> points;
    curandState* randomState = nullptr;
};