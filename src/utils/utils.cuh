#pragma once

#include <stdio.h>
#include <iostream>

#define checkError(val) check_error((val), #val, __FILE__, __LINE__)

void check_error(cudaError_t result, const char* const func, const char* const file, const int line);
void printDevicesInfos();