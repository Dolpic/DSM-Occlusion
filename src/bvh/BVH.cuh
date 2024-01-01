#pragma once

#include "../primitives/Bbox.cuh"
#include "../primitives/Ray.cuh"
#include "../array/Array.cuh"
#include <ostream>


template<typename T>
struct BVHNode{
    Bbox<T>* bbox;
    BVHNode* left;
    BVHNode* right;
    Array<Point3<T>>* elements;
    __host__ __device__ BVHNode() : bbox(nullptr), left(nullptr), right(nullptr), elements(nullptr) {}
};

template <typename T>
struct ArraySegment{
    Point3<T>** head;
    Point3<T>** tail;
    BVHNode<T>* node;
};

template <typename T>
struct Stack {
    ArraySegment<T>* data;
    unsigned int size;
    __host__ __device__ void push(ArraySegment<T> value) {data[size++] = value;}
    __host__ __device__ ArraySegment<T> pop() {return data[--size];}
};



template<typename T>
class BVH{

public:
    __host__ __device__ BVH(
        Array<Point3<T>*>& points, 
        ArraySegment<T>* stackMemory, 
        Array<Point3<T>*>& workingBuffer, 
        BVHNode<T>* BVHNodeMemory, 
        Bbox<T>* bboxMemory, 
        Array<Point3<T>>* elementsMemory){
            root = BVH::build(points, workingBuffer, stackMemory,  BVHNodeMemory, bboxMemory, elementsMemory);
    }
    
    __host__ __device__ int size() const {return nbElements;}

    __host__ __device__ float getLighting(const Ray<T>& ray, BVHNode<T>** buffer) const { 
        ray.getDirection().normalize();
        unsigned int bufferSize = 0;
        buffer[bufferSize++] = root;

        while(bufferSize > 0){
            BVHNode<T>* node = buffer[--bufferSize];
            if(node != nullptr && node->bbox->intersects(ray)){
                if(node->elements != nullptr){
                    for(const Point3<T>& point : *node->elements){
                        if(point != ray.getOrigin() && BVH::intersectSphere(point, ray, 0.25)){
                            //std::cout << ray.getOrigin() << " " << ray.getDirection() << " " << point << '\n';
                            return 0;
                        }
                    }
                }
                buffer[bufferSize++] = node->left;
                buffer[bufferSize++] = node->right;
            }
        }
        return 1;
    }

private:

    BVHNode<T>* root;
    int nbElements = 0;

    __host__ __device__ bool intersectBox(const Point3<T>& center, const Ray<T>& ray, const float margin) const {
        const Vec3<T>& rayDir = ray.getDirection();
        const Point3<T>& rayOrigin = ray.getOrigin();

        float min, max;

        const float xInverse = 1 / rayDir.x;
        const float tNearX = (center.x - margin - rayOrigin.x) * xInverse;
        const float tFarX  = (center.x + margin - rayOrigin.x) * xInverse;

        if(tNearX > tFarX){
            min = tFarX;
            max = tNearX;
        }else{
            min = tNearX;
            max = tFarX;
        }
        
        const float yInverse = 1 / rayDir.y;
        const float tNearY = (center.y - margin - rayOrigin.y) * yInverse;
        const float tFarY  = (center.y + margin - rayOrigin.y) * yInverse;

        if(tNearY > tFarY){
            min = min < tFarY  ? tFarY  : min;
            max = max > tNearY ? tNearY : max;
        }else{
            min = min < tNearY ? tNearY : min;
            max = max > tFarY  ? tFarY  : max;
        }

        if(max < min && min > 0) return false;

        const float zInverse = 1 / rayDir.z;
        const float tNearZ = (center.z - margin - rayOrigin.z) * zInverse;
        const float tFarZ  = (center.z + margin - rayOrigin.z) * zInverse;

       if(tNearZ > tFarZ){
            min = min < tFarZ  ? tFarZ  : min;
            max = max > tNearZ ? tNearZ : max;
        }else{
            min = min < tNearZ ? tNearZ : min;
            max = max > tFarZ  ? tFarZ  : max;
        }

        return min < max && min > 0;
    }

    __host__ __device__ bool intersectSphere(const Point3<T>& center, const Ray<T>& ray, const float radius) const {
        const T radius_squared = radius*radius;
        const Vec3<T> d_co = ray.getOrigin() - center;
        const T d_co_norm_sqr = d_co.getNormSquared();
        if(d_co_norm_sqr <= radius_squared) return false;
        const T tmp = ray.getDirection().dot(d_co);
        const T delta = tmp*tmp - (d_co_norm_sqr - radius_squared);
        const T t = -tmp-sqrt(delta);
        //if(delta > 0) std::cout << "delta : " << delta << '\n';
        return delta >= 0 && t > 0;
    }

    __host__ __device__ BVHNode<T>* build(Array<Point3<T>*>& points, Array<Point3<T>*> workingBuffer, ArraySegment<T>* stackMemory, BVHNode<T>* BVHNodeMemory, Bbox<T>* bboxMemory, Array<Point3<T>>* elementsMemory) {

        const float margin = 0.25;
        const unsigned int bboxMaxSize = 3;

        int BVHNodeCounter = 0;
        int bboxCounter = 0;
        int elementsCounter = 0;

        Stack<T> stack = Stack<T>{stackMemory, 0};

        BVHNode<T>* root = new (&BVHNodeMemory[BVHNodeCounter++]) BVHNode<T>();

        Point3<T>** begin = points.begin();
        Point3<T>** end   = points.end();
        stack.push(ArraySegment<T>{begin, end, root});
        
        while(stack.size > 0){
            nbElements++;
            ArraySegment curSegment = stack.pop();
            const unsigned int curSize = curSegment.tail-curSegment.head;

            Bbox<T>* bbox = new (&bboxMemory[bboxCounter++]) Bbox<T>();
            bbox->setEnglobing(curSegment.head, curSize, margin);
            curSegment.node->bbox = bbox;

            if(curSize < bboxMaxSize){
                curSegment.node->elements = new (&elementsMemory[elementsCounter++]) Array<Point3<T>>(*curSegment.head, curSize);
            }else{

                const unsigned int splitIndex = BVH::split(curSegment.head, workingBuffer, curSize, bbox);
                Point3<T>** middle = &(curSegment.head[splitIndex]);

                curSegment.node->left  = new (&BVHNodeMemory[BVHNodeCounter++]) BVHNode<T>();
                curSegment.node->right = new (&BVHNodeMemory[BVHNodeCounter++]) BVHNode<T>();

                stack.push(ArraySegment<T>{curSegment.head, middle, curSegment.node->left});
                stack.push(ArraySegment<T>{middle, curSegment.tail, curSegment.node->right});
            }
        }
        return root;
    }

    __host__ __device__ int split(Point3<T>** points, Array<Point3<T>*> workingBuffer, unsigned int size, const Bbox<T>* bbox) const {
        const T dx = bbox->getEdgeLength('X');
        const T dy = bbox->getEdgeLength('Y');
        const T dz = bbox->getEdgeLength('Z');
        const Point3<T> center = bbox->getCenter();

        int nbLeft  = 0;
        int nbRight = 0;

        for(int i=0; i<size; i++){
            Point3<T>* const point = points[i];
            if(dx>=dy && dx>=dz){
                if(point->x < center.x){
                    workingBuffer[nbLeft++] = point;
                }else{
                    workingBuffer[size-nbRight-1] = point;
                    nbRight++;
                }
            }else if(dy>=dx && dy>=dz){
                if(point->y < center.y){
                    workingBuffer[nbLeft++] = point;
                }else{
                    workingBuffer[size-nbRight-1] = point;
                    nbRight++;
                }
            }else{
                if(point->z < center.z){
                    workingBuffer[nbLeft++] = point;
                }else{
                    workingBuffer[size-nbRight-1] = point;
                    nbRight++;
                }
            }
        }
        for(int i=0; i<size; i++){
            points[i] = workingBuffer[i];
        }
        return nbLeft;
    }

};