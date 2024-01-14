#include "Tracer.cuh"
#include "../utils/utils.cuh"

#include <random>

std::default_random_engine genEngine;
std::uniform_real_distribution<> uniform0_1 = std::uniform_real_distribution<>(0.001, 1);

constexpr unsigned int NB_STRATIFIED_DIRS = 32;
constexpr unsigned int SEED = 1423;
constexpr dim3 threads(8,8);


__host__ __device__ 
void initRender(const Array2D<float>& data, Point3<float>* const points, BVH<float>* const bvh, const float pixelSize){
    Point3<float>** pointsArray = (Point3<float>**) malloc(data.width()*data.height()*sizeof(Point3<float>*));
    for(unsigned int y=0; y<data.height(); y++){
        for(unsigned int x=0; x<data.width(); x++){
            const int index = y*data.width()+x;
            points[index] = Point3<float>((float)x*pixelSize,(float)y*pixelSize, data[index]);
            pointsArray[index] = &(points[index]);
        }
    }
    Array<Point3<float>*> pointsPointersArray = Array<Point3<float>*>(pointsArray, data.width()*data.height());
    bvh->build(pointsPointersArray);
    free(pointsArray);
}

__global__
void initRenderGPU(const Array2D<float>& data, Point3<float>* points, BVH<float>* bvh, float pixelSize) {
    const unsigned int x = threadIdx.x + blockIdx.x * blockDim.x;
    const unsigned int y = threadIdx.y + blockIdx.y * blockDim.y;
    if(x>=data.width() || y>=data.height()) return;
    const unsigned int index = y*data.width() + x;
    initRender(data, points, bvh, pixelSize);
}


__host__ 
void render(float* const data, const unsigned int index, const unsigned int raysPerPoint, Point3<float>* points, BVH<float>* bvh, BVHNode<float>** traceBuffer, const unsigned int traceBufferSizePerThread){
    Point3<float> origin  = points[index];
    Vec3<float> direction = Vec3<float>(0,0,0);
    Ray<float> ray        = Ray<float>(origin, direction);

    float result = 0;
    for(unsigned int i=0; i<raysPerPoint; i++){
        const unsigned int segmentNumber = i%NB_STRATIFIED_DIRS;
        const float rnd1 = uniform0_1(genEngine);
        const float rnd2 = uniform0_1(genEngine);
        const float cosThetaOverPdf = ray.getDirection().setRandomInHemisphereCosine( NB_STRATIFIED_DIRS , segmentNumber, rnd1, rnd2);
        result += cosThetaOverPdf*bvh->getLighting(ray, &traceBuffer[index*traceBufferSizePerThread]);
    }
    data[index] = (result/raysPerPoint)*(1/PI); // Diffuse BSDF
}

__global__
void renderGPU(Array2D<float>& data, Point3<float>* points, BVH<float>* bvh, const int raysPerPoint, curandState* const rndState, BVHNode<float>** traceBuffer, int traceBufferSize){
    const unsigned int width = data.width();
    const unsigned int height = data.height();
    const int x = threadIdx.x + blockIdx.x * blockDim.x;
    const int y = threadIdx.y + blockIdx.y * blockDim.y;
    if(x>=width || y>=height) return;
    const unsigned int index = y*width + x;

    curandState localRndState = rndState[index];
    curand_init(SEED, index, 0, &localRndState);

    Point3<float> origin  = points[index];
    Vec3<float> direction = Vec3<float>(0,0,0);
    Ray<float> ray        = Ray<float>(origin, direction);

    float result = 0;
    for(unsigned int i=0; i<raysPerPoint; i++){
        const float rnd1 = curand_uniform(&localRndState);
        const float rnd2 = curand_uniform(&localRndState);
        const unsigned int segmentNumber = i%NB_STRATIFIED_DIRS;
        const float cosThetaOverPdf = ray.getDirection().setRandomInHemisphereCosine( NB_STRATIFIED_DIRS , segmentNumber, rnd1, rnd2);
        result += cosThetaOverPdf*bvh->getLighting(ray, &traceBuffer[index*traceBufferSize]);
    }
    data[index] = (result/raysPerPoint)*(1/PI); // Diffuse BSDF
}


Tracer::Tracer(Array2D<float>& data, const float pixelSize, const bool useGPU) : 
    data(data), width(data.width()), height(data.height()),
    useGPU(useGPU),
    pixelSize(pixelSize),
    randomState(useGPU ? (curandState*) allocGPU(width*height, sizeof(curandState)) : nullptr),
    points((Point3<float>*) allocMemory(width*height, sizeof(Point3<float>), useGPU)){}

Tracer::~Tracer(){
    if(useGPU) cudaFree(randomState);
    freeMemory(points, useGPU);
}

void Tracer::init(const bool prinInfos){
    bvh = new BVH<float>(useGPU, width*height);
    if(useGPU){
        BVH<float>* bvhDevice = (BVH<float>*) allocGPU(sizeof(BVH<float>)); // TODO free
        checkError(cudaMemcpy(bvhDevice, bvh, sizeof(BVH<float>), cudaMemcpyHostToDevice));
        free(bvh);
        bvh = bvhDevice;

        Array2D<float>* dataGPU = data.createReplicaGPU();
        initRenderGPU<<<1,1>>>(*dataGPU, points, bvh, pixelSize);
        syncGPU();
        data.consumeReplicaGPU(dataGPU);
    }else{
        initRender(data, points, bvh, pixelSize);
        if(prinInfos) bvh->printInfos();
    }
}


void Tracer::trace(const unsigned int raysPerPoint){
    BVH<float>* bvhLocal = nullptr;
    if(useGPU){
        bvhLocal = (BVH<float>*) malloc(sizeof(BVH<float>));
        cudaMemcpy(bvhLocal, bvh, sizeof(BVH<float>), cudaMemcpyDeviceToHost);
    }else{
        bvhLocal = bvh;
    }

    const int traceBufferSizePerThread = std::log2(bvhLocal->size())+1;
    BVHNode<float>** traceBuffer = (BVHNode<float>**) allocMemory(width*height*traceBufferSizePerThread, sizeof(BVHNode<float>*), useGPU);

    if(useGPU){
        const dim3 blocks(width/threads.x+1, height/threads.y+1);
        Array2D<float>* dataGPU = data.createReplicaGPU();
        renderGPU<<<blocks, threads>>>(*dataGPU, points, bvh, raysPerPoint, randomState, traceBuffer, traceBufferSizePerThread);
        syncGPU();
        data.consumeReplicaGPU(dataGPU);
    }else{
        float progress = 0;
        float nextProgress = 0.1;

        #pragma omp parallel for
        for(int y=0; y<height; y++){
            for(int x=0; x<width; x++){
                render(data.begin(), y*width+x, raysPerPoint, points, bvh, traceBuffer, traceBufferSizePerThread);
            }

            #pragma omp atomic
            progress++;
            if(progress >= nextProgress*height){
                std::cout << "Progress " << 100*nextProgress << "%\n";
                std::flush(std::cout);
                nextProgress += 0.1;
            }
        }
    }
    freeMemory(traceBuffer, useGPU);
}
