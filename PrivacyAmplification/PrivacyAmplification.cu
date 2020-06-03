#include <iostream>
#include <iomanip>
#include <cuda_runtime.h>
#include <cufftXt.h>
#include <cuda_fp16.h>
#include <assert.h>
#include <algorithm>
#include <iterator>
#include <math.h>
#include <zmq.h>
#ifdef _WIN32
#include <windows.h>
#endif
#include <thread>
#include <chrono>
#include <atomic>
#include <bitset>
#include <future>
#include <iostream>
#include <fstream>

typedef float    Real;
typedef float2   Complex;

#define factor 27
#define pwrtwo(x) (1 << (x))
#define sample_size pwrtwo(factor)
#define reduction pwrtwo(11)
#define pre_mul_reduction pwrtwo(5)
#define total_reduction reduction*pre_mul_reduction
#define min_template(a,b) (((a) < (b)) ? (a) : (b))
#define SHOW_AMPOUT TRUE
#define SHOW_DEBUG_OUTPUT FALSE
#define SHOW_SHOW_KEY_DEBUG_OUTPUT FALSE
#define USE_MATRIX_SEED_SERVER FALSE
#define USE_KEY_SERVER FALSE
#define HOST_AMPOUT_SERVER FALSE
#define AMPOUT_REVERSE_ENDIAN TRUE
#define TOEPLITZ_SEED_PATH "toeplitz_seed.bin"
#define KEYFILE_PATH "keyfile.bin"
const Real normalisation_float = ((float)sample_size)/((float)total_reduction)/((float)total_reduction);

#if USE_MATRIX_SEED_SERVER == TRUE
const char* address_seed_in = "tcp://127.0.0.1:45555"; //seed_in_alice
//const char* address_seed_in = "tcp://127.0.0.1:46666"; //seed_in_bob
#endif
#if USE_KEY_SERVER == TRUE
const char* address_key_in = "tcp://127.0.0.1:47777"; //key_in
#endif
#if HOST_AMPOUT_SERVER == TRUE
const char* address_amp_out = "tcp://127.0.0.1:48888"; //amp_out
#endif
constexpr int vertical_len = sample_size/4 + sample_size/8;
constexpr int horizontal_len = sample_size/2 + sample_size/8;
constexpr int key_len = sample_size+1;
constexpr int vertical_block = vertical_len / 32;
constexpr int horizontal_block = horizontal_len / 32;
constexpr int key_blocks = vertical_block + horizontal_block + 1;
constexpr int desired_block = vertical_block + horizontal_block;
constexpr int desired_len = vertical_len + horizontal_len;
unsigned int* toeplitz_seed = (unsigned int*)malloc(desired_block * sizeof(unsigned int));
unsigned int* recv_key = (unsigned int*)malloc(key_blocks * sizeof(unsigned int));
unsigned int* key_start = (unsigned int*)malloc(desired_block * sizeof(unsigned int));
unsigned int* key_rest = (unsigned int*)malloc(desired_block * sizeof(unsigned int));
std::atomic<int> continueGeneratingNextBlock = 0;
std::atomic<int> blockReady = 0;
std::mutex printlock;
char syn[3];
char ack[3];


__device__ __constant__ Complex c0_dev;
__device__ __constant__ float h0_dev;
__device__ __constant__ float h1_reduced_dev;
__device__ __constant__ float normalisation_float_dev;

__device__ __constant__ unsigned int intTobinMask_dev[32] =
{
    0b10000000000000000000000000000000,
    0b01000000000000000000000000000000,
    0b00100000000000000000000000000000,
    0b00010000000000000000000000000000,
    0b00001000000000000000000000000000,
    0b00000100000000000000000000000000,
    0b00000010000000000000000000000000,
    0b00000001000000000000000000000000,
    0b00000000100000000000000000000000,
    0b00000000010000000000000000000000,
    0b00000000001000000000000000000000,
    0b00000000000100000000000000000000,
    0b00000000000010000000000000000000,
    0b00000000000001000000000000000000,
    0b00000000000000100000000000000000,
    0b00000000000000010000000000000000,
    0b00000000000000001000000000000000,
    0b00000000000000000100000000000000,
    0b00000000000000000010000000000000,
    0b00000000000000000001000000000000,
    0b00000000000000000000100000000000,
    0b00000000000000000000010000000000,
    0b00000000000000000000001000000000,
    0b00000000000000000000000100000000,
    0b00000000000000000000000010000000,
    0b00000000000000000000000001000000,
    0b00000000000000000000000000100000,
    0b00000000000000000000000000010000,
    0b00000000000000000000000000001000,
    0b00000000000000000000000000000100,
    0b00000000000000000000000000000010,
    0b00000000000000000000000000000001
};

__global__
void calculateCorrectionFloat(uint32_t* count_one_global_seed, uint32_t* count_one_global_key, float* correction_float_dev)
{
    //*correction_float_dev = (float)((unsigned long)(*count_one_global_key-60000000));
    uint64_t count_multiblicated = *count_one_global_seed * *count_one_global_key;
    double count_multiblicated_normalized = count_multiblicated / (double)sample_size;
    double two = 2.0;
    float count_multiblicated_normalized_modulo = (float)modf(count_multiblicated_normalized, &two);
    *correction_float_dev = count_multiblicated_normalized_modulo;
}

__global__
void setFirstElementToZero(Complex* do1, Complex* do2)
{
    do1[0] = c0_dev;
    do2[0] = c0_dev;
}

__global__
void ElementWiseProduct(int n, Complex* do1, Complex* do2)
{
    //Requires at least sm_53 as sm_52 and below don't support float maths.
    //Tegra/Jetson from Maxwell, Pascal, Volta, Turing and probably the upcomming Ampere
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    float r = pre_mul_reduction;
    Real do1x = do1[i].x/r;
    Real do1y = do1[i].y/r;
    Real do2x = do2[i].x/r;
    Real do2y = do2[i].y/r;
    do1[i].x = do1x * do2x - do1y * do2y;
    do1[i].y = do1x * do2y + do1y * do2x;
}

__global__
void ToFloatArray(int n, unsigned int b, Real* floatOut, Real normalisation_float)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    int j = i * 32;

    floatOut[j]    = (b & 0b10000000000000000000000000000000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+1]  = (b & 0b01000000000000000000000000000000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+2]  = (b & 0b00100000000000000000000000000000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+3]  = (b & 0b00010000000000000000000000000000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+4]  = (b & 0b00001000000000000000000000000000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+5]  = (b & 0b00000100000000000000000000000000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+6]  = (b & 0b00000010000000000000000000000000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+7]  = (b & 0b00000001000000000000000000000000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+8]  = (b & 0b00000000100000000000000000000000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+9]  = (b & 0b00000000010000000000000000000000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+10] = (b & 0b00000000001000000000000000000000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+11] = (b & 0b00000000000100000000000000000000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+12] = (b & 0b00000000000010000000000000000000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+13] = (b & 0b00000000000001000000000000000000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+14] = (b & 0b00000000000000100000000000000000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+15] = (b & 0b00000000000000010000000000000000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+16] = (b & 0b00000000000000001000000000000000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+17] = (b & 0b00000000000000000100000000000000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+18] = (b & 0b00000000000000000010000000000000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+19] = (b & 0b00000000000000000001000000000000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+20] = (b & 0b00000000000000000000100000000000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+21] = (b & 0b00000000000000000000010000000000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+22] = (b & 0b00000000000000000000001000000000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+23] = (b & 0b00000000000000000000000100000000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+24] = (b & 0b00000000000000000000000010000000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+25] = (b & 0b00000000000000000000000001000000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+26] = (b & 0b00000000000000000000000000100000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+27] = (b & 0b00000000000000000000000000010000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+28] = (b & 0b00000000000000000000000000001000 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+29] = (b & 0b00000000000000000000000000000100 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+30] = (b & 0b00000000000000000000000000000010 > 0) ? h1_reduced_dev : h0_dev;
    floatOut[j+31] = (b & 0b00000000000000000000000000000001 > 0) ? h1_reduced_dev : h0_dev;
}

__global__
void ToBinaryArray(Real* invOut, unsigned int* binOut, unsigned int* key_rest_dev, Real* correction_float_dev)
{
    Real correction_float = *correction_float_dev;
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    int j = i * 32;
    binOut[i] = 
        (((__float2int_rn(invOut[j    ] / normalisation_float_dev + correction_float) & 1) << 31) |
        ((__float2int_rn(invOut[j +  1] / normalisation_float_dev + correction_float) & 1) << 30) |
        ((__float2int_rn(invOut[j +  2] / normalisation_float_dev + correction_float) & 1) << 29) |
        ((__float2int_rn(invOut[j +  3] / normalisation_float_dev + correction_float) & 1) << 28) |
        ((__float2int_rn(invOut[j +  4] / normalisation_float_dev + correction_float) & 1) << 27) |
        ((__float2int_rn(invOut[j +  5] / normalisation_float_dev + correction_float) & 1) << 26) |
        ((__float2int_rn(invOut[j +  6] / normalisation_float_dev + correction_float) & 1) << 25) |
        ((__float2int_rn(invOut[j +  7] / normalisation_float_dev + correction_float) & 1) << 24) |
        ((__float2int_rn(invOut[j +  8] / normalisation_float_dev + correction_float) & 1) << 23) |
        ((__float2int_rn(invOut[j +  9] / normalisation_float_dev + correction_float) & 1) << 22) |
        ((__float2int_rn(invOut[j + 10] / normalisation_float_dev + correction_float) & 1) << 21) |
        ((__float2int_rn(invOut[j + 11] / normalisation_float_dev + correction_float) & 1) << 20) |
        ((__float2int_rn(invOut[j + 12] / normalisation_float_dev + correction_float) & 1) << 19) |
        ((__float2int_rn(invOut[j + 13] / normalisation_float_dev + correction_float) & 1) << 18) |
        ((__float2int_rn(invOut[j + 14] / normalisation_float_dev + correction_float) & 1) << 17) |
        ((__float2int_rn(invOut[j + 15] / normalisation_float_dev + correction_float) & 1) << 16) |
        ((__float2int_rn(invOut[j + 16] / normalisation_float_dev + correction_float) & 1) << 15) |
        ((__float2int_rn(invOut[j + 17] / normalisation_float_dev + correction_float) & 1) << 14) |
        ((__float2int_rn(invOut[j + 18] / normalisation_float_dev + correction_float) & 1) << 13) |
        ((__float2int_rn(invOut[j + 19] / normalisation_float_dev + correction_float) & 1) << 12) |
        ((__float2int_rn(invOut[j + 20] / normalisation_float_dev + correction_float) & 1) << 11) |
        ((__float2int_rn(invOut[j + 21] / normalisation_float_dev + correction_float) & 1) << 10) |
        ((__float2int_rn(invOut[j + 22] / normalisation_float_dev + correction_float) & 1) << 9) |
        ((__float2int_rn(invOut[j + 23] / normalisation_float_dev + correction_float) & 1) << 8) |
        ((__float2int_rn(invOut[j + 24] / normalisation_float_dev + correction_float) & 1) << 7) |
        ((__float2int_rn(invOut[j + 25] / normalisation_float_dev + correction_float) & 1) << 6) |
        ((__float2int_rn(invOut[j + 26] / normalisation_float_dev + correction_float) & 1) << 5) |
        ((__float2int_rn(invOut[j + 27] / normalisation_float_dev + correction_float) & 1) << 4) |
        ((__float2int_rn(invOut[j + 28] / normalisation_float_dev + correction_float) & 1) << 3) |
        ((__float2int_rn(invOut[j + 29] / normalisation_float_dev + correction_float) & 1) << 2) |
        ((__float2int_rn(invOut[j + 30] / normalisation_float_dev + correction_float) & 1) << 1) |
         (__float2int_rn(invOut[j + 31] / normalisation_float_dev + correction_float) & 1)) ^ key_rest_dev[i];
}

__global__
void ToBinaryArray_reverse_endianness(Real* invOut, unsigned int* binOut, unsigned int* key_rest_dev, Real* correction_float_dev)
{
    Real correction_float = *correction_float_dev;
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    int key_rest_little = key_rest_dev[i];
    int key_rest_big =
        ((((key_rest_little) & 0xff000000) >> 24) |
        (((key_rest_little) & 0x00ff0000) >> 8) |
        (((key_rest_little) & 0x0000ff00) << 8) |
        (((key_rest_little) & 0x000000ff) << 24));
    int j = i * 32;
    binOut[i] =
        (((__float2int_rn(invOut[j    ] / normalisation_float_dev + correction_float) & 1) << 7) |
        ((__float2int_rn(invOut[j +  1] / normalisation_float_dev + correction_float) & 1) << 6) |
        ((__float2int_rn(invOut[j +  2] / normalisation_float_dev + correction_float) & 1) << 5) |
        ((__float2int_rn(invOut[j +  3] / normalisation_float_dev + correction_float) & 1) << 4) |
        ((__float2int_rn(invOut[j +  4] / normalisation_float_dev + correction_float) & 1) << 3) |
        ((__float2int_rn(invOut[j +  5] / normalisation_float_dev + correction_float) & 1) << 2) |
        ((__float2int_rn(invOut[j +  6] / normalisation_float_dev + correction_float) & 1) << 1) |
        ((__float2int_rn(invOut[j +  7] / normalisation_float_dev + correction_float) & 1) << 0) |
        ((__float2int_rn(invOut[j +  8] / normalisation_float_dev + correction_float) & 1) << 15) |
        ((__float2int_rn(invOut[j +  9] / normalisation_float_dev + correction_float) & 1) << 14) |
        ((__float2int_rn(invOut[j + 10] / normalisation_float_dev + correction_float) & 1) << 13) |
        ((__float2int_rn(invOut[j + 11] / normalisation_float_dev + correction_float) & 1) << 12) |
        ((__float2int_rn(invOut[j + 12] / normalisation_float_dev + correction_float) & 1) << 11) |
        ((__float2int_rn(invOut[j + 13] / normalisation_float_dev + correction_float) & 1) << 10) |
        ((__float2int_rn(invOut[j + 14] / normalisation_float_dev + correction_float) & 1) << 9) |
        ((__float2int_rn(invOut[j + 15] / normalisation_float_dev + correction_float) & 1) << 8) |
        ((__float2int_rn(invOut[j + 16] / normalisation_float_dev + correction_float) & 1) << 23) |
        ((__float2int_rn(invOut[j + 17] / normalisation_float_dev + correction_float) & 1) << 22) |
        ((__float2int_rn(invOut[j + 18] / normalisation_float_dev + correction_float) & 1) << 21) |
        ((__float2int_rn(invOut[j + 19] / normalisation_float_dev + correction_float) & 1) << 20) |
        ((__float2int_rn(invOut[j + 20] / normalisation_float_dev + correction_float) & 1) << 19) |
        ((__float2int_rn(invOut[j + 21] / normalisation_float_dev + correction_float) & 1) << 18) |
        ((__float2int_rn(invOut[j + 22] / normalisation_float_dev + correction_float) & 1) << 17) |
        ((__float2int_rn(invOut[j + 23] / normalisation_float_dev + correction_float) & 1) << 16) |
        ((__float2int_rn(invOut[j + 24] / normalisation_float_dev + correction_float) & 1) << 31) |
        ((__float2int_rn(invOut[j + 25] / normalisation_float_dev + correction_float) & 1) << 30) |
        ((__float2int_rn(invOut[j + 26] / normalisation_float_dev + correction_float) & 1) << 29) |
        ((__float2int_rn(invOut[j + 27] / normalisation_float_dev + correction_float) & 1) << 28) |
        ((__float2int_rn(invOut[j + 28] / normalisation_float_dev + correction_float) & 1) << 27) |
        ((__float2int_rn(invOut[j + 29] / normalisation_float_dev + correction_float) & 1) << 26) |
        ((__float2int_rn(invOut[j + 30] / normalisation_float_dev + correction_float) & 1) << 25) |
        ((__float2int_rn(invOut[j + 31] / normalisation_float_dev + correction_float) & 1) << 24)) ^ key_rest_big;
}

__global__
void binInt2float(unsigned int* binIn, Real* realOut, uint32_t* count_one_global)
{
    unsigned int i;
    int block = blockIdx.x;
    int idx = threadIdx.x;
    unsigned int pos;
    unsigned int databyte;
    unsigned int count_one;
    count_one = 0; //Required!

    pos = (1024 * block * 32) + (idx * 32);
    databyte = binIn[1024 * block + idx];
    
    #pragma unroll (32)
    for (i = 0; i < 32; ++i)
    {
        if ((databyte & intTobinMask_dev[i]) == 0) {
            realOut[pos++] = h0_dev;
        }
        else
        {
            ++count_one;
            realOut[pos++] = h1_reduced_dev;
        }
    }

    atomicAdd(count_one_global, count_one);
}

void intToBinCPU(int* intIn, unsigned int* binOut, int outSize) {
    int j = 0;
    for (int i = 0; i < outSize; ++i) {
        binOut[i] =
            (intIn[j] & 1 << 31) |
            (intIn[j + 1] & 1 << 30) |
            (intIn[j + 2] & 1 << 29) |
            (intIn[j + 3] & 1 << 28) |
            (intIn[j + 4] & 1 << 27) |
            (intIn[j + 5] & 1 << 26) |
            (intIn[j + 6] & 1 << 25) |
            (intIn[j + 7] & 1 << 24) |
            (intIn[j + 8] & 1 << 23) |
            (intIn[j + 9] & 1 << 22) |
            (intIn[j + 10] & 1 << 21) |
            (intIn[j + 11] & 1 << 20) |
            (intIn[j + 12] & 1 << 19) |
            (intIn[j + 13] & 1 << 18) |
            (intIn[j + 14] & 1 << 17) |
            (intIn[j + 15] & 1 << 16) |
            (intIn[j + 16] & 1 << 15) |
            (intIn[j + 17] & 1 << 14) |
            (intIn[j + 18] & 1 << 13) |
            (intIn[j + 19] & 1 << 12) |
            (intIn[j + 20] & 1 << 11) |
            (intIn[j + 21] & 1 << 10) |
            (intIn[j + 22] & 1 << 9) |
            (intIn[j + 23] & 1 << 8) |
            (intIn[j + 24] & 1 << 7) |
            (intIn[j + 25] & 1 << 6) |
            (intIn[j + 26] & 1 << 5) |
            (intIn[j + 27] & 1 << 4) |
            (intIn[j + 28] & 1 << 3) |
            (intIn[j + 29] & 1 << 2) |
            (intIn[j + 30] & 1 << 1) |
            (intIn[j + 31] & 1);
        j += 32;
    }
}


void printBin(const unsigned char* position, const unsigned char* end) {
    while (position < end) {
        printf("%s", std::bitset<8>(*position).to_string().c_str());
        ++position;
    }
    std::cout << std::endl;
}

void printBin(const unsigned int* position, const unsigned int* end) {
    while (position < end) {
        printf("%s", std::bitset<32>(*position).to_string().c_str());
        ++position;
    }
    std::cout << std::endl;
}



inline void key2StartRest() {
    memcpy(key_start, recv_key, key_blocks * sizeof(unsigned int));
    *(key_start + horizontal_block) = *(recv_key + horizontal_block) & 0b10000000000000000000000000000000;
    memset(key_start + horizontal_block + 1, 0b00000000, (desired_block - horizontal_block - 1) * sizeof(unsigned int));

    int j = horizontal_block;
    for (int i = 0; i < vertical_block + 1; ++i)
    {
        key_rest[i] = ((recv_key[j] << 1) | (recv_key[j + 1] >> 31));
        ++j;
    }
    memset(key_rest + desired_block - horizontal_block, 0b00000000, vertical_block - (vertical_block - horizontal_block));
}


void recive() {

    #if USE_MATRIX_SEED_SERVER == TRUE
    void* context_seed_in = zmq_ctx_new();
    void* socket_seed_in = zmq_socket(context_seed_in, ZMQ_REQ);
    zmq_connect(socket_seed_in, address_seed_in);
    #else
    //Cryptographically random Toeplitz seed generated by XOR a self-generated
    //VeraCrypt key file (PRF: SHA-512) with ANU_20Oct2017_100MB_7
    //from the ANU Quantum Random Numbers Server (https://qrng.anu.edu.au/)
    std::ifstream seedfile(TOEPLITZ_SEED_PATH, std::ios::binary);
    size_t length_seedfile;

    if (seedfile.fail())
    {
        std::cout << "Can't open file \"" << TOEPLITZ_SEED_PATH << "\" => terminating!" << std::endl;
        exit(1);
        abort();
    }

    seedfile.seekg(0, std::ios::end);
    size_t seedfile_length = seedfile.tellg();
    seedfile.seekg(0, std::ios::beg);

    if (seedfile_length < desired_block * sizeof(unsigned int))
    {
        std::cout << "File \"" << TOEPLITZ_SEED_PATH << "\" is with " << seedfile_length << " bytes too short!" << std::endl;
        std::cout << "it is required to be at least " << desired_block * sizeof(unsigned int) << " bytes => terminating!" << std::endl;
        exit(1);
        abort();
    }

    char* toeplitz_seed_char = reinterpret_cast<char*>(toeplitz_seed);
    seedfile.read(toeplitz_seed_char, desired_block * sizeof(unsigned int));
    #endif

    #if USE_KEY_SERVER == TRUE
    void* context_key_in = zmq_ctx_new();
    void* USE_TOEPLITZ_SEED_SERVER = zmq_socket(context_key_in, ZMQ_REQ);
    zmq_connect(USE_TOEPLITZ_SEED_SERVER, address_key_in);
    #else
    //Cryptographically random Toeplitz seed generated by XOR a self-generated
    //VeraCrypt key file (PRF: SHA-512) with ANU_20Oct2017_100MB_49
    //from the ANU Quantum Random Numbers Server (https://qrng.anu.edu.au/)
    std::ifstream keyfile(KEYFILE_PATH, std::ios::binary);

    if (keyfile.fail())
    {
        std::cout << "Can't open file \"" << KEYFILE_PATH << "\" => terminating!" << std::endl;
        exit(1);
        abort();
    }

    keyfile.seekg(0, std::ios::end);
    size_t keyfile_length = keyfile.tellg();
    keyfile.seekg(0, std::ios::beg);

    if (keyfile_length < key_blocks * sizeof(unsigned int))
    {
        std::cout << "File \"" << KEYFILE_PATH << "\" is with " << keyfile_length << " bytes too short!" << std::endl;
        std::cout << "it is required to be at least " << key_blocks * sizeof(unsigned int) << " bytes => terminating!" << std::endl;
        exit(1);
        abort();
    }

    char* recv_key_char = reinterpret_cast<char*>(recv_key);
    keyfile.read(recv_key_char, key_blocks * sizeof(unsigned int));
    key2StartRest();
    #endif

    while (true) {
        #if USE_MATRIX_SEED_SERVER == TRUE
        printf("socket_seed_in\n");
        zmq_send(socket_seed_in, "SYN", 3, 0);
        printf("SYN SENT\n");
        zmq_recv(socket_seed_in, toeplitz_seed, desired_block * sizeof(unsigned int), 0);
        printf("ACK SENT\n");
        zmq_send(socket_seed_in, "ACK", 3, 0);
        #endif

        #if USE_KEY_SERVER == TRUE
        printf("USE_TOEPLITZ_SEED_SERVER\n");
        zmq_send(USE_TOEPLITZ_SEED_SERVER, "SYN", 3, 0);
        zmq_recv(USE_TOEPLITZ_SEED_SERVER, recv_key, key_blocks * sizeof(unsigned int), 0);
        zmq_send(USE_TOEPLITZ_SEED_SERVER, "ACK", 3, 0);
        key2StartRest();
        #endif

        #if SHOW_KEY_DEBUG_OUTPUT TRUE
        printlock.lock();
        std::cout << "Toeplitz Seed: ";
        printBin(toeplitz_seed, toeplitz_seed + desired_block);
        std::cout << "Key: ";
        printBin(recv_key, recv_key + key_blocks);
        std::cout << "Key Start: ";
        printBin(key_start, key_start + desired_block + 1);
        std::cout << "Key Rest: ";
        printBin(key_rest, key_rest + vertical_block + 1);
        fflush(stdout);
        printlock.unlock();
        #endif

        blockReady = 1;
        while (continueGeneratingNextBlock == 0) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        continueGeneratingNextBlock = 0;
    }

    #if USE_MATRIX_SEED_SERVER == TRUE
    zmq_disconnect(socket_seed_in, address_seed_in);
    zmq_close(socket_seed_in);
    zmq_ctx_destroy(socket_seed_in);
    #endif
    #if USE_KEY_SERVER == TRUE
    zmq_disconnect(USE_TOEPLITZ_SEED_SERVER, address_key_in);
    zmq_close(USE_TOEPLITZ_SEED_SERVER);
    zmq_ctx_destroy(USE_TOEPLITZ_SEED_SERVER);
    #endif
}


int main(int argc, char* argv[])
{
    std::cout << "PrivacyAmplification with " << sample_size << " bits" << std::endl;
    std::cout << "normalisation_float: " << normalisation_float << std::endl;

    #if HOST_AMPOUT_SERVER == TRUE
    void* amp_out_context = zmq_ctx_new();
    void* amp_out_socket = zmq_socket(amp_out_context, ZMQ_REP);
    int rc = zmq_bind(amp_out_socket, address_amp_out);
    assert(rc == 0);
    #endif

    #ifdef _WIN32
    HANDLE hConsole = GetStdHandle(STD_OUTPUT_HANDLE);
    CONSOLE_SCREEN_BUFFER_INFO csbi;
    DWORD dwConSize;
    COORD coordScreen = { 0, 0 };
    DWORD cCharsWritten;
    GetConsoleScreenBufferInfo(hConsole, &csbi);
    dwConSize = csbi.dwSize.X * csbi.dwSize.Y;
    FillConsoleOutputAttribute(hConsole, FOREGROUND_RED | FOREGROUND_BLUE | FOREGROUND_GREEN | FOREGROUND_INTENSITY | BACKGROUND_BLUE, dwConSize, coordScreen, &cCharsWritten);
    SetConsoleTextAttribute(hConsole, FOREGROUND_RED | FOREGROUND_BLUE | FOREGROUND_GREEN | FOREGROUND_INTENSITY | BACKGROUND_BLUE);
    #endif

    std::thread threadReciveObj(recive);
    threadReciveObj.detach();
    std::this_thread::sleep_for(std::chrono::seconds(1));
    
    const int batch_size = 1; ; //Storage would also have to be increased for this to work
    long long int dist_sample = sample_size, dist_freq = sample_size / 2 + 1;
    const int loops = 10000;

    uint32_t* count_one_global_seed;
    uint32_t* count_one_global_key;
    float* correction_float_dev;
    unsigned int* key_start_dev;
    unsigned int* key_rest_dev;
    unsigned int* toeplitz_seed_dev;
    Real* di1;
    Real* di2;
    Real* invOut;
    Complex* do1;
    Complex* do2;
    unsigned int* binOut;
    unsigned char* Output;
    cudaStream_t FFTStream, BinInt2floatKeyStream, BinInt2floatSeedStream, CalculateCorrectionFloatStream,
        cpu2gpuKeyStartStream, cpu2gpuKeyRestStream, cpu2gpuSeedStream, gpu2cpuStream, ElementWiseProductStream, ToBinaryArrayStream;
    cudaStreamCreate(&FFTStream);
    cudaStreamCreate(&BinInt2floatKeyStream);
    cudaStreamCreate(&BinInt2floatSeedStream);
    cudaStreamCreate(&CalculateCorrectionFloatStream);
    cudaStreamCreate(&cpu2gpuKeyStartStream);
    cudaStreamCreate(&cpu2gpuKeyRestStream);
    cudaStreamCreate(&cpu2gpuSeedStream);
    cudaStreamCreate(&gpu2cpuStream);
    cudaStreamCreate(&ElementWiseProductStream);
    cudaStreamCreate(&ToBinaryArrayStream);

    // create cuda event to measure the performance
    cudaEvent_t start;
    cudaEvent_t stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    // Allocate host pinned memory on RAM
    cudaMallocHost((void**)&Output, vertical_block * sizeof(unsigned int));
    #if SHOW_DEBUG_OUTPUT TRUE
    float* OutputFloat;
    cudaMallocHost((void**)&OutputFloat, dist_sample * sizeof(float));
    #endif

    // Allocate memory on GPU
    cudaMalloc(&count_one_global_seed, sizeof(uint32_t));
    cudaMalloc(&count_one_global_key, sizeof(uint32_t));
    cudaMalloc(&correction_float_dev, sizeof(float));
    cudaMalloc((void**)&key_start_dev, (sample_size/8));
    cudaMalloc((void**)&key_rest_dev, (sample_size/8));
    cudaMalloc((void**)&toeplitz_seed_dev, (sample_size/8));
    cudaMalloc((void**)&di1, sizeof(Real) * sample_size);
    cudaMalloc((void**)&di2, sizeof(Real) * sample_size);
    cudaMalloc((void**)&do1, sample_size * sizeof(Complex));
    cudaMalloc((void**)&do2, sample_size * sizeof(Complex));
    cudaMalloc(&invOut, sizeof(Real) * dist_sample);
    cudaMalloc(&binOut, sizeof(unsigned int) * sample_size/8);

    register const Complex complex0 = make_float2(0.0f, 0.0f);
    register const float float0 = 0.0f;
    register const float float1_reduced = 1.0f/reduction;

    cudaMemcpyToSymbol(c0_dev, &complex0, sizeof(Complex));
    cudaMemcpyToSymbol(h0_dev, &float0, sizeof(float));
    cudaMemcpyToSymbol(h1_reduced_dev, &float1_reduced, sizeof(float));
    cudaMemcpyToSymbol(normalisation_float_dev, &normalisation_float, sizeof(float));


    int rank = 1;
    int stride_sample = 1, stride_freq = 1;
    long long embed_sample[] = { 0 };
    long long embedo1[] = { 0 };
    size_t workSize = 0;
    cufftHandle plan_forward_R2C;
    cufftResult r;
    r = cufftPlan1d(&plan_forward_R2C, dist_sample, CUFFT_R2C, 1);
    if (r != CUFFT_SUCCESS)
    {
        printf("Failed to plan FFT 1! Error Code: %i\n", r);
        exit(0);
    }
    cufftSetStream(plan_forward_R2C, FFTStream);

    cufftHandle plan_inverse_C2R;
    r = cufftPlan1d(&plan_inverse_C2R, dist_sample, CUFFT_C2R, 1);
    if (r != CUFFT_SUCCESS)
    {
        printf("Failed to plan IFFT 1! Error Code: %i\n", r);
        exit(0);
    }
    cufftSetStream(plan_forward_R2C, FFTStream);

    printlock.lock();
    printf("Bob!!!\n");
    fflush(stdout);
    printlock.unlock();
    while (blockReady == 0) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    printlock.lock();
    printf("Ready!!!\n");
    fflush(stdout);
    printlock.unlock();
    
    cudaMemcpy(key_start_dev, key_start, dist_sample / 8, cudaMemcpyHostToDevice);
    cudaMemcpy(key_rest_dev, key_rest, dist_sample / 8, cudaMemcpyHostToDevice);
    cudaMemset(key_rest_dev + horizontal_block + 1, 0, (sample_size / 8) - horizontal_block + 1);
    cudaMemcpy(toeplitz_seed_dev, toeplitz_seed, dist_sample / 8, cudaMemcpyHostToDevice);

    binInt2float <<< (int)(((int)(sample_size / (1 * 32)) + 1023) / 1024), std::min(sample_size / 32, 1024), 0,
        BinInt2floatKeyStream >>> (key_start_dev, di1, count_one_global_key);
    binInt2float <<< (int)(((int)(sample_size / (1 * 32)) + 1023) / 1024), std::min(sample_size / 32, 1024), 0,
        BinInt2floatSeedStream >>> (toeplitz_seed_dev, di2, count_one_global_seed);

    while (true) {

        cudaEventRecord(start);
        cudaEventSynchronize(start);

        cudaMemset(count_one_global_key, 0x00, sizeof(uint32_t));
        cudaMemset(count_one_global_seed, 0x00, sizeof(uint32_t));

        //cudaStreamSynchronize(BinInt2floatKeyStream);
        //cudaStreamSynchronize(BinInt2floatSeedStream);
        cudaMemcpyAsync(key_start_dev, key_start, dist_sample / 8, cudaMemcpyHostToDevice, cpu2gpuKeyStartStream);
        cudaMemcpyAsync(key_rest_dev, key_rest, dist_sample / 8, cudaMemcpyHostToDevice, cpu2gpuKeyRestStream);
        cudaMemsetAsync(key_rest_dev + horizontal_block + 1, 0, (sample_size / 8) - horizontal_block + 1, cpu2gpuKeyRestStream);
        cudaMemcpyAsync(toeplitz_seed_dev, toeplitz_seed, dist_sample / 8, cudaMemcpyHostToDevice, cpu2gpuSeedStream);
        calculateCorrectionFloat <<<1, 1, 0, CalculateCorrectionFloatStream>>> (count_one_global_key, count_one_global_seed, correction_float_dev);
        cufftExecR2C(plan_forward_R2C, di1, do1);
        cufftExecR2C(plan_forward_R2C, di2, do2);
        cudaStreamSynchronize(cpu2gpuKeyStartStream);
        cudaStreamSynchronize(cpu2gpuKeyRestStream);
        cudaStreamSynchronize(cpu2gpuSeedStream);
        blockReady = 0;
        continueGeneratingNextBlock = 1;
        binInt2float <<< (int)(((int)(sample_size / (1 * 32)) + 1023) / 1024), std::min(sample_size / 32, 1024), 0,
            BinInt2floatKeyStream >> > (key_start_dev, di1, count_one_global_key);
        binInt2float <<< (int)(((int)(sample_size / (1 * 32)) + 1023) / 1024), std::min(sample_size / 32, 1024), 0,
            BinInt2floatSeedStream >> > (toeplitz_seed_dev, di2, count_one_global_seed);
        cudaStreamSynchronize(CalculateCorrectionFloatStream);
        setFirstElementToZero <<<1, 1, 0, ElementWiseProductStream>>> (do1, do2);
        cudaStreamSynchronize(ElementWiseProductStream);
        ElementWiseProduct <<<(int)((dist_freq + 1023) / 1024), std::min((int)dist_freq, 1024), 0, ElementWiseProductStream >>> (dist_freq, do1, do2);
        cudaStreamSynchronize(ElementWiseProductStream);
        cufftExecC2R(plan_inverse_C2R, do1, invOut);
        #if AMPOUT_REVERSE_ENDIAN == TRUE
        ToBinaryArray_reverse_endianness <<<(int)(((int)(vertical_block) + 1023) / 1024), std::min(vertical_block, 1024), 0, ToBinaryArrayStream >>> (invOut, binOut, key_rest_dev, correction_float_dev);
        #else
        ToBinaryArray <<< (int)(((int)(vertical_block)+1023) / 1024), std::min(vertical_block, 1024), 0, ToBinaryArrayStream >>> (invOut, binOut, key_rest_dev, correction_float_dev);
        #endif
        cudaStreamSynchronize(ToBinaryArrayStream);
        cudaMemcpy(Output, binOut, vertical_block * sizeof(unsigned int), cudaMemcpyDeviceToHost);
        #if SHOW_DEBUG_OUTPUT TRUE
        cudaMemcpy(OutputFloat, invOut, dist_freq * sizeof(float), cudaMemcpyDeviceToHost);
        cudaMemcpy(OutputFloat, correction_float_dev, sizeof(float), cudaMemcpyDeviceToHost);
        #endif
        //}
        cudaEventRecord(stop);
        cudaEventSynchronize(stop);

        float et;
        cudaEventElapsedTime(&et, start, stop);
        printf("FFT time for %lld samples: %f ms\n", (sample_size), et);

        

        #if HOST_AMPOUT_SERVER == TRUE
        printlock.lock();
        zmq_recv(amp_out_socket, syn, 3, 0);
        printf("Recived: %c%c%c\n", syn[0], syn[1], syn[2]);
        zmq_send(amp_out_socket, Output, sample_size / 8, 0);
        zmq_recv(amp_out_socket, ack, 3, 0);
        printf("Recived: %c%c%c\n", ack[0], ack[1], ack[2]);
        fflush(stdout);
        printlock.unlock();
        #endif

        #if SHOW_DEBUG_OUTPUT TRUE
        printlock.lock();
        for (size_t i = 0; i < min_template(dist_freq, 64); ++i)
        {
            printf("%f\n", OutputFloat[i]);
        }
        printlock.unlock();
        #endif

        #if SHOW_AMPOUT TRUE
        printlock.lock();
        for (size_t i = 0; i < min_template(vertical_block * sizeof(unsigned int), 64); ++i)
        {
            printf("0x%02X: %s\n", Output[i], std::bitset<8>(Output[i]).to_string().c_str());
        }
        fflush(stdout);
        printlock.unlock();
        #endif
        //break;
    }


    // Delete CUFFT Plans
    cufftDestroy(plan_forward_R2C);
    cufftDestroy(plan_inverse_C2R);

    // Deallocate memoriey on GPU and RAM
    cudaFree(di1);
    cudaFree(di2);
    cudaFree(invOut);
    cudaFree(do1);
    cudaFree(do2);
    cudaFree(binOut);
    cudaFree(Output);

    // Delete cuda events
    cudaEventDestroy(start);
    cudaEventDestroy(stop);

    return 0;
}
