#pragma once

#include "../primitives/Bbox.cuh"
#include "../primitives/Ray.cuh"
#include "../utils/utils.cuh"
#include "../array/Array.cuh"

#include <cstdio>
#include <iostream>
#include <ostream>

#include <vector>

#define TILE_SIZE (Float)0.5 

constexpr unsigned char ELEMENTS_MAX_SIZE = 4;

struct __align__(16) BVHNode{
    Bbox<Float> bboxLeft = Bbox<Float>();
    Bbox<Float> bboxRight = Bbox<Float>();
    unsigned int elementsIndex = 0;
    unsigned int sizeLeft      = 0;
    unsigned int sizeRight     = 0;
    unsigned char nbElements   = 0;
    /*unsigned char cacheIdLeft  = 255;
    unsigned char cacheIdRight = 255;*/
};

template <typename T>
struct ArraySegment{
    ArraySegment* parent;
    Point3<Float>** head;
    Point3<Float>** tail;
    BVHNode* node = nullptr;
};


class BVH{
public:
    __host__ BVH(const unsigned int nbPixels): nbPixels(nbPixels) {
        bvhNodes       = (BVHNode*)             calloc(2*nbPixels, sizeof(BVHNode));
        elementsMemory = (Point3<Float>*)       calloc(nbPixels,   sizeof(Point3<Float>));
        stackMemory    = (ArraySegment<Float>*) calloc(nbPixels,   sizeof(ArraySegment<Float>));
        workingBuffer  = (Point3<Float>**)      calloc(nbPixels,   sizeof(Point3<Float>*));
    }

    __host__ void freeAfterBuild(){
        free(stackMemory);
        free(workingBuffer);
        stackMemory   = nullptr;
        workingBuffer = nullptr;
    }
    
    __host__ void freeAllMemory(){
        free(elementsMemory);
        free(bvhNodes);
    }

    __host__ BVH* toGPU() const {
        BVHNode*  bvhNodesGPU       = (BVHNode*) allocGPU(2*nbPixels, sizeof(BVHNode));
        Point3<Float>*   elementsMemoryGPU = (Point3<Float>*)  allocGPU(nbPixels, sizeof(Point3<Float>));
        
        checkError(cudaMemcpy(bvhNodesGPU,       bvhNodes,       2*nbPixels*sizeof(BVHNode), cudaMemcpyHostToDevice));
        checkError(cudaMemcpy(elementsMemoryGPU, elementsMemory, nbPixels*sizeof(Point3<Float>),  cudaMemcpyHostToDevice));

        ArraySegment<Float>* stackMemoryGPU = nullptr;
        if(stackMemory != nullptr){
            stackMemoryGPU    = (ArraySegment<Float>*)  allocGPU(nbPixels,   sizeof(ArraySegment<Float>));
            checkError(cudaMemcpy(stackMemoryGPU, stackMemory, nbPixels*sizeof(ArraySegment<Float>), cudaMemcpyHostToDevice));
        }

        Point3<Float>** workingBufferGPU = nullptr;
        if(workingBuffer != nullptr){
            workingBufferGPU = (Point3<Float>**) allocGPU(nbPixels, sizeof(Point3<Float>*));
            checkError(cudaMemcpy(workingBufferGPU, workingBuffer, nbPixels*sizeof(Point3<Float>*), cudaMemcpyHostToDevice));
        }

        BVH tmp = BVH(nbPixels);
        tmp.freeAfterBuild();
        tmp.freeAllMemory();
        tmp.nbNodes        = nbNodes;
        tmp.bvhNodes       = bvhNodesGPU;
        tmp.elementsMemory = elementsMemoryGPU;
        tmp.stackMemory    = stackMemoryGPU;
        tmp.workingBuffer  = workingBufferGPU;
        BVH* replica = (BVH*) allocGPU(sizeof(BVH));
        checkError(cudaMemcpy(replica, &tmp, sizeof(BVH), cudaMemcpyHostToDevice));
        return replica;
    }

    __host__ void fromGPU(BVH* replica){
        BVH tmp = BVH(nbPixels);
        tmp.freeAfterBuild();
        tmp.freeAllMemory();
        checkError(cudaMemcpy(&tmp, replica, sizeof(BVH), cudaMemcpyDeviceToHost));
        checkError(cudaMemcpy(bvhNodes,       tmp.bvhNodes,       2*nbPixels*sizeof(BVHNode),       cudaMemcpyDeviceToHost));
        checkError(cudaMemcpy(elementsMemory, tmp.elementsMemory, nbPixels*sizeof(Point3<Float>), cudaMemcpyDeviceToHost));
        
        freeGPU(tmp.bvhNodes);
        freeGPU(tmp.elementsMemory);

        if(stackMemory != nullptr){
            checkError(cudaMemcpy(stackMemory, tmp.stackMemory, nbPixels*sizeof(ArraySegment<Float>), cudaMemcpyDeviceToHost));
            freeGPU(tmp.stackMemory);
        }
        if(workingBuffer != nullptr){
            checkError(cudaMemcpy(workingBuffer, tmp.workingBuffer, nbPixels*sizeof(Point3<Float>*), cudaMemcpyDeviceToHost));
            freeGPU(tmp.workingBuffer);
        }

        nbNodes = tmp.nbNodes;

        freeGPU(replica);
    }

    __host__ void printInfos(){std::cout<<"BVH : \n   Nodes : "<<nbNodes<<"\n";}
    __host__ __device__ int size() const {return nbNodes;}
    __host__ __device__ BVHNode* root() const {return &bvhNodes[0];}

    __device__ Float getLighting(const Point3<Float>& origin, const Vec3<Float>& invDir) const {
        unsigned int nodeIndex = 0;
        const unsigned int maxIndex = nbNodes;
        const Float margin = TILE_SIZE/TWO;

        while(nodeIndex < maxIndex){
            const BVHNode node = bvhNodes[nodeIndex];

            for(unsigned char i=0; i<node.nbElements; i++){
                if(intersectBox(elementsMemory[node.elementsIndex+i], invDir, origin, margin)){
                    return 0;
                }
                // continue ??
            }

            const bool intersectRight = node.bboxRight.intersects(invDir, origin);
            const bool intersectLeft  = node.bboxLeft.intersects(invDir, origin);
            
            nodeIndex += intersectLeft + 
                (!intersectLeft && intersectRight)*(node.sizeLeft+1) + 
                (!intersectLeft && !intersectRight)*(node.sizeRight+node.sizeLeft+1);
        }
        return 1;
    }

    __device__ Float getLighting2(const Point3<Float>& origin, const Vec3<Float>& invDir, BVHNode* const cache) const {
        /*unsigned int nodeIndex = 0;
        const unsigned int maxIndex = nbNodes;
        const Float margin = TILE_SIZE/TWO;

        unsigned char nextId = 0;

        while(nodeIndex < maxIndex){

            BVHNode node;
            if(nextId < 64){
                node = cache[nextId];
                if(node.sizeLeft == 0){
                    node = cache[nextId] = bvhNodes[nodeIndex];
                }
            }else{
                node = bvhNodes[nodeIndex];
            }

            for(unsigned char i=0; i<node.nbElements; i++){
                if(intersectBox(elementsMemory[node.elementsIndex+i], invDir, origin, margin)){
                    return 0;
                }
                // continue ??
            }

            const bool intersectRight = node.bboxRight.intersects(invDir, origin);
            const bool intersectLeft  = node.bboxLeft.intersects(invDir, origin);
            
            nodeIndex += intersectLeft + 
                (!intersectLeft && intersectRight)*(node.sizeLeft+1) + 
                (!intersectLeft && !intersectRight)*(node.sizeRight+node.sizeLeft+1);

            nextId = intersectLeft * node.cacheIdLeft + 
                (!intersectLeft && intersectRight)*(node.cacheIdRight) + 
                (!intersectLeft && !intersectRight)*255;
        }*/
        return 1;
    }


    __host__ void build(Array2D<Point3<Float>*>& points) {
        const Float margin = TILE_SIZE/TWO;

        std::vector<int> stack = std::vector<int>();

        unsigned int elementsCounter = 0;
        unsigned int nbSegments = 0;

        stack.push_back(nbSegments);
        stackMemory[nbSegments++] = ArraySegment<Float>{nullptr, points.begin(), points.end()};
        
        while(stack.size() != 0){
            ArraySegment<Float>* curSegment = &stackMemory[stack.back()];
            stack.pop_back();
            curSegment->node = new (&bvhNodes[nbNodes++]) BVHNode();

            const unsigned int curSize = curSegment->tail-curSegment->head;
            
            if(curSize < ELEMENTS_MAX_SIZE){
                for(int i=0; i<curSize; i++){
                    elementsMemory[elementsCounter+i] = *(curSegment->head[i]);
                }
                curSegment->node->elementsIndex = elementsCounter;
                curSegment->node->nbElements = curSize;
                elementsCounter += curSize;

            }else{

                Bbox<Float> globalBbox = Bbox<Float>();
                globalBbox.setEnglobing(curSegment->head, curSize, margin);
                const unsigned int splitIndex = split(curSegment->head, curSize, globalBbox);
                Point3<Float>** middle = &(curSegment->head[splitIndex]);

                curSegment->node->bboxRight.setEnglobing(middle, curSegment->tail-middle, margin);
                stack.push_back(nbSegments);
                stackMemory[nbSegments++] = ArraySegment<Float>{curSegment, middle, curSegment->tail};
                

                curSegment->node->bboxLeft.setEnglobing(curSegment->head, middle-curSegment->head, margin);
                stack.push_back(nbSegments);
                stackMemory[nbSegments++] = ArraySegment<Float>{curSegment, curSegment->head, middle};
            }

            ArraySegment<Float>* segment = curSegment;
            while(segment->parent != nullptr){
                if(segment->node == segment->parent->node+1 ){ // If left child
                    segment->parent->node->sizeLeft++;
                }else{
                    segment->parent->node->sizeRight++;
                }
                segment = segment->parent;
            }
        }

        /*const unsigned int nbCachedNodes = 64;
        int nodesIdFIFO[2*nbCachedNodes];
        int headFIFO = 0;
        int tailFIFO = 0;
        nodesIdFIFO[headFIFO++] = 0;
        bvhNodes[0].cacheIdLeft = 0;
        bvhNodes[0].cacheIdRight = 1;
        for(int i=0; headFIFO!=tailFIFO; i+=2){
            int curNodeId = nodesIdFIFO[tailFIFO++];
            BVHNode& node = bvhNodes[curNodeId];
            node.cacheIdLeft = i+1;
            node.cacheIdRight = i+2;
            if(i<nbCachedNodes){
                nodesIdFIFO[headFIFO++] = curNodeId+1;
                nodesIdFIFO[headFIFO++] = curNodeId+node.sizeLeft;
            }
        }*/

    }

private:

    const unsigned int nbPixels;
    unsigned int nbNodes = 0;

    BVHNode*             bvhNodes;
    Point3<Float>*       elementsMemory;
    ArraySegment<Float>* stackMemory;
    Point3<Float>**      workingBuffer;


    __host__ __device__ bool intersectBox(const Point3<Float>& top, const Vec3<Float>& invRayDir, const Point3<Float>& rayOrigin, const Float margin) const {
        Float min, max;

        const Float tNearX = (top.x - margin - rayOrigin.x) * invRayDir.x;
        const Float tFarX  = (top.x + margin - rayOrigin.x) * invRayDir.x;

        if(tNearX > tFarX){
            min = tFarX;
            max = tNearX;
        }else{
            min = tNearX;
            max = tFarX;
        }
        
        const Float tNearY = (top.y - margin - rayOrigin.y) * invRayDir.y;
        const Float tFarY  = (top.y + margin - rayOrigin.y) * invRayDir.y;

        if(tNearY > tFarY){
            min = min < tFarY  ? tFarY  : min;
            max = max > tNearY ? tNearY : max;
        }else{
            min = min < tNearY ? tNearY : min;
            max = max > tFarY  ? tFarY  : max;
        }

        const Float tNearZ = (-rayOrigin.z) * invRayDir.z;
        const Float tFarZ  = (top.z - rayOrigin.z) * invRayDir.z;

       if(tNearZ > tFarZ){
            min = min < tFarZ  ? tFarZ  : min;
            max = max > tNearZ ? tNearZ : max;
        }else{
            min = min < tNearZ ? tNearZ : min;
            max = max > tFarZ  ? tFarZ  : max;
        }

        return min < max && min > ZERO;
    }

    __host__ __device__ bool intersectSphere(const Point3<Float>& top, const Ray<Float>& ray, const Float radius) const {
        ray.getDirection().normalize();
        const Point3<Float> center = Point3<Float>(top.x, top.y, top.z-TILE_SIZE/TWO);
        const Float radius_squared = radius*radius;
        const Vec3<Float> d_co = ray.getOrigin() - center;
        const Float d_co_norm_sqr = d_co.getNormSquared();
        if(d_co_norm_sqr <= radius_squared) return false;
        const Float tmp = ray.getDirection().dot(d_co);
        const Float delta = tmp*tmp - (d_co_norm_sqr - radius_squared);
        const Float t = -ONE*(tmp+(Float)sqrt((float)delta));
        return delta >= ZERO && t > ZERO;
    }

    __host__ __device__ int split(Point3<Float>** points, unsigned int size, const Bbox<Float>& bbox) const {
        const Float dx = bbox.getEdgeLength('X');
        const Float dy = bbox.getEdgeLength('Y');
        //const Float dz = bbox->getEdgeLength('Z');
        const Point3<Float> center = bbox.getCenter();

        int nbLeft  = 0;
        int nbRight = 0;


        for(int i=0; i<size; i++){
            Point3<Float>* const point = points[i];
            if(dx>=dy /*&& dx>=dz*/){
                if(point->x < center.x){
                    workingBuffer[nbLeft++] = point;
                }else{
                    workingBuffer[size-nbRight-1] = point;
                    nbRight++;
                }
            }else /*if(dy>=dx && dy>=dz)*/{
                if(point->y < center.y){
                    workingBuffer[nbLeft++] = point;
                }else{
                    workingBuffer[size-nbRight-1] = point;
                    nbRight++;
                }
            }/*else{
                if(point->z < center.z){
                    workingBuffer[nbLeft++] = point;
                }else{
                    workingBuffer[size-nbRight-1] = point;
                    nbRight++;
                }
            }*/
        }
        for(int i=0; i<size; i++){
            points[i] = workingBuffer[i];
        }
        return nbLeft;
    }

};