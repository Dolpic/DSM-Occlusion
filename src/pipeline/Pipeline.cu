#include "Pipeline.cuh"

#include <atomic>
#include <iostream>
#include <mutex>
#include <condition_variable>

condition_variable cv;
atomic<int> nbFinished(0);
mutex global_mutex;

Pipeline::Pipeline(Raster& rasterIn, Raster* rasterOut, uint tileSize, uint rayPerPoint, uint tileBuffer, float exaggeration, uint maxBounces, float bias, uint startTile): 
rasterIn(rasterIn), rasterOut(rasterOut){
    const uint nbTiles = (uint)ceil((float)rasterIn.getHeight()/tileSize) * (uint)ceil((float)rasterIn.getWidth()/tileSize);

    for(uint i=0; i<NB_PIPELINE_STAGES; i++){
        stages[i].state = new PipelineState();
        stages[i].id = i;
    }

    stages[0].thread = new thread(Pipeline::readData,  &stages[0], &rasterIn, tileSize, tileBuffer, startTile);
    stages[1].thread = new thread(Pipeline::initTile,  &stages[1], rasterIn.getPixelSize(), exaggeration, maxBounces);
    stages[2].thread = new thread(Pipeline::trace,     &stages[2], rayPerPoint, bias);
    stages[3].thread = new thread(Pipeline::writeData, &stages[3], rasterOut, &rasterIn);
}

Pipeline::~Pipeline(){
    debug_print("Stopping pipeline \n");
    for(uint i=0; i<NB_PIPELINE_STAGES; i++){
        stages[i].thread->join();
        delete stages[i].state;
        delete stages[i].thread;
    }
}

bool Pipeline::step(){
    while(nbFinished < NB_PIPELINE_STAGES){}
    lock_guard<mutex> lock(global_mutex);
    debug_print("Next pipeline step - Releasing threads \n");

    PipelineState* state1Tmp = stages[0].state;
    stages[0].state = stages[3].state;
    stages[3].state = stages[2].state;
    stages[2].state = stages[1].state;
    stages[1].state = state1Tmp;

    nbFinished = 0;
    for(uint i=0; i < NB_PIPELINE_STAGES; i++){
        stages[i].ready = true;
    }
    cv.notify_all();
    return !stages[3].state->finished;
}

void Pipeline::waitForNextStep(PipelineStage* stage, timePoint startTime){
    int elapsedTime = chrono::duration_cast<chrono::milliseconds>(chrono::high_resolution_clock::now() - startTime).count();
    debug_print("Thread " + STAGE_NAMES[stage->id] + " waiting [" + to_string(elapsedTime) + " ms]\n");
    unique_lock<mutex> lock(global_mutex);
    nbFinished++;
    cv.wait(lock, [stage]{ return stage->ready; });
    //debug_print("Thread " + to_string(stage->id) + " released \n");
    stage->ready = false;
}


void Pipeline::readData(PipelineStage* stage, const Raster* rasterIn, uint tileSize, uint tileBuffer, uint startTile){
    const float noDataValue = rasterIn->getNoDataValue();
    const uint nbTiles = (uint)ceil((float)rasterIn->getHeight()/tileSize) * (uint)ceil((float)rasterIn->getWidth()/tileSize);
    uint nbTileProcessed = 0;
    timePoint startTime = chrono::high_resolution_clock::now();
    for(uint y=0; y<rasterIn->getHeight(); y+=tileSize){
        for(uint x=0; x<rasterIn->getWidth(); x+=tileSize){

            if (nbTileProcessed < startTile){
                nbTileProcessed++;
                continue;
            }

            Pipeline::waitForNextStep(stage, startTime);
            startTime = chrono::high_resolution_clock::now();
            PipelineState* state = stage->state;
            print_atomic("Processing tile " + to_string(nbTileProcessed+1) + "/" + to_string(nbTiles) + " (" + to_string(100*nbTileProcessed/nbTiles) + "%)...\n");

            state->id = nbTileProcessed;
            state->x = x;
            state->y = y;
            state->width  = min(tileSize, rasterIn->getWidth()-x);
            state->height = min(tileSize, rasterIn->getHeight()-y);
            state->extent.xMin = max(0, (int)x-(int)tileBuffer);
            state->extent.yMin = max(0, (int)y-(int)tileBuffer);
            state->extent.xMax = min(rasterIn->getWidth(), x+state->width+tileBuffer);
            state->extent.yMax = min(rasterIn->getHeight(),y+state->height+tileBuffer);

            if(state->dataIn != nullptr){
                delete state->dataIn;
            }
            if(state->dataOut != nullptr){
                delete state->dataOut; 
            }
            state->dataIn = new Array2D<float>(state->extent.xMax-state->extent.xMin, state->extent.yMax-state->extent.yMin);
            state->dataOut = new Array2D<float>(state->extent.xMax-state->extent.xMin, state->extent.yMax-state->extent.yMin);

            rasterIn->readData(state->dataIn->begin(), state->extent.xMin, state->extent.yMin, state->extent.xMax-state->extent.xMin, state->extent.yMax-state->extent.yMin);

            for(uint i=0; i<state->dataIn->size(); i++){
                if((*state->dataIn)[i] != noDataValue){
                    state->hasData = true;
                }
                (*state->dataOut)[i] = (*state->dataIn)[i];
            }

            nbTileProcessed++;
        }
    }
    debug_print("> Thread " + STAGE_NAMES[stage->id] + " finished...\n");
    for(uint i=3; i>0; i--){
        PipelineState* state = stage->state;
        state->finished = true;
        Pipeline::waitForNextStep(stage, startTime);
    }
    debug_print("> Thread " + STAGE_NAMES[stage->id] + " exit\n");
}

void Pipeline::initTile(PipelineStage* stage, float pixelSize, float exaggeration, uint maxBounces){
    PipelineState* state = stage->state;
    timePoint startTime = chrono::high_resolution_clock::now();
    while(!state->finished){
        Pipeline::waitForNextStep(stage, startTime);
        startTime = chrono::high_resolution_clock::now();
        state = stage->state;
        if(state->hasData && state->id >= 0){
            debug_print("> Building BVH of tile " + to_string(state->id+1) + "...\n");
            if(state->tracer != nullptr){
                delete state->tracer;
            }
            state->tracer = new Tracer(*state->dataOut, pixelSize, exaggeration, maxBounces);
            state->tracer->init(false);
        }else if(state->id >= 0){
            logger::cout() << "> Tile "<< state->id+1  <<" skipped because it had no data \n";
        }
    }
    debug_print("> Thread " + STAGE_NAMES[stage->id] + " finished...\n");
    Pipeline::waitForNextStep(stage, startTime);
    Pipeline::waitForNextStep(stage, startTime);
    debug_print("> Thread " + STAGE_NAMES[stage->id] + " exit\n");
}

void Pipeline::trace(PipelineStage* stage, uint rayPerPoint, float bias){
    PipelineState* state = stage->state;
    timePoint startTime = chrono::high_resolution_clock::now();
    while(!state->finished){
        Pipeline::waitForNextStep(stage, startTime);
        startTime = chrono::high_resolution_clock::now();
        state = stage->state;
        if(state->hasData && state->id >= 0){
            debug_print("> Tracing tile " + to_string(state->id+1) + "...\n");
            state->tracer->trace(true, rayPerPoint, bias);
        }
    }
    debug_print("> Thread " + STAGE_NAMES[stage->id] + " finished...\n");
    Pipeline::waitForNextStep(stage, startTime);
    debug_print("> Thread " + STAGE_NAMES[stage->id] + " exit\n");
}

void Pipeline::writeData(PipelineStage* stage, const Raster* const rasterOut, const Raster* const rasterIn){
    PipelineState* state = stage->state;
    timePoint startTime = chrono::high_resolution_clock::now();
    while(!state->finished){
        Pipeline::waitForNextStep(stage, startTime);
        startTime = chrono::high_resolution_clock::now();
        state = stage->state;
        if(state->hasData && state->id >= 0){
            debug_print("> Writing tile " + to_string(state->id+1) + "...\n");
            const float noDataValue = rasterIn->getNoDataValue();
            Array2D<float> dataCropped(state->width, state->height);
            uint i=0, j=0;
            bool hasData = false;
            for(int curY=state->extent.yMin; curY < state->extent.yMax; curY++){
                for(int curX=state->extent.xMin; curX < state->extent.xMax; curX++){
                    if(curY>=state->y && curY < state->y+(int)state->height && curX>=state->x && curX < state->x+(int)state->width){
                        if((*state->dataIn)[j] != noDataValue){
                            hasData = true;
                            dataCropped[i++] = (*state->dataOut)[j];
                        }else{
                            dataCropped[i++] = noDataValue;
                        }
                    }
                    j++;
                }
            }

            if(rasterOut != nullptr){
                rasterOut->writeData(dataCropped.begin(), state->x, state->y, state->width, state->height);
            }else if(hasData){
                const int tileX = state->x / state->width;
                const int tileY = state->y / state->height;
                std::ostringstream oss;
                oss << "./output_tiles/" << std::setw(8) << std::setfill('0') << state->id <<"_tile_" 
                    << std::setw(5) << std::setfill('0') << tileX << "_" << std::setw(5) << std::setfill('0') << tileY << ".tif";
                Raster::writeTile(dataCropped.begin(), state->x, state->y, state->width, state->height, rasterIn, oss.str().c_str());
            }else{
                logger::cout() << "> Tile "<< state->id+1  <<" not written because it had no data \n";
            }
        }
    }
    debug_print("> Thread " + STAGE_NAMES[stage->id] + " finished...\n");
    debug_print("> Thread " + STAGE_NAMES[stage->id] + " exit\n");
}