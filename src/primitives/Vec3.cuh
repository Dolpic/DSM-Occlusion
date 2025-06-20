#pragma once

#include "../utils/definitions.cuh"
#include "Point3.cuh"

#include <iostream>

template<typename T>
class Vec3{

public:
    __host__ __device__ Vec3(T x=0, T y=0, T z=0) : x(x), y(y), z(z){};
    __host__ __device__ T getNormSquared() const { return x*x + y*y + z*z; }
    __host__ __device__ T dot(const Vec3<T>& other) const { return x*other.x + y*other.y + z*other.z; }
    
    __host__ __device__ 
    void normalize() {
        const T norm = sqrtf(x*x + y*y + z*z);
        x /= norm;
        y /= norm;
        z /= norm;
    }

    __device__ __forceinline__ 
    float setRandomInHemisphereCosine(float rndForPhi, float rndForTheta){
        const float theta = acosf(sqrtf(rndForTheta));
        const float sinTheta = sinf(theta);
        const float phi = TWO_PI*rndForPhi;
        x = sinTheta*cosf(phi);
        y = sinTheta*sinf(phi);
        z = cosf(theta);
        return PI; // pdf = cosTheta / PI, so cosTheta / pdf = PI
    }

    __host__ 
    float setRandomInHemisphereUniform(byte nbSegments, byte segmentNumber, float rndNumber1, float rndNumber2){
        const float segmentSize = 2.0*PI/nbSegments;
        const float phi = rndNumber1 * segmentSize + segmentSize * segmentNumber;
        const float theta = acos(rndNumber2);
        const float sinTheta = sin(theta);
        const float cosTheta = cos(theta);
        x = sinTheta*cos(phi);
        y = sinTheta*sin(phi);
        z = cosTheta;
        const float pdf = 1.0/TWO_PI;
        return cosTheta / pdf;
    };

    T x, y, z;
};

template<typename T>
std::ostream& operator<<(std::ostream& os, const Vec3<T>& p) {
    os << "Vec3("<<p.x<<","<<p.y<<","<<p.z<<")";
    return os;
}