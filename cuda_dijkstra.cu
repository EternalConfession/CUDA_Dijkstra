/* Name: ZHANG Jianhui
 * ID: 20374500
 * Email:
 */

/*
 * This is code skeleton for COMP5112-17Spring assignment4
 * Compile: nvcc -std=c++11 -arch=sm_52 -o cuda_dijkstra cuda_dijkstra_skeleton.cu
 * Run: ./cuda_dijkstra -n <number of threads> -i <input file>,
 * you will find the output in 'output.txt' file
 *
 *  by Lipeng WANG, 5th Apr 2017
 */

#include <string>
#include <cassert>
#include <iostream>
#include <fstream>
#include <vector>
#include <climits>
#include <cstring>
#include <cmath>
#include <algorithm>
#include <sys/time.h>
#include <time.h>
#include <getopt.h>

#include <cuda_runtime.h>
#include <device_launch_parameters.h>

using std::string;
using std::cout;
using std::endl;
using std::vector;
using std::ceil;
using std::memcpy;

#define INF 1000000

/*
 * This is a CHECK function to check CUDA calls
 */
#define CHECK(call)                                                            \
 {                                                                              \
     const cudaError_t error = call;                                            \
     if (error != cudaSuccess)                                                  \
     {                                                                          \
         fprintf(stderr, "Error: %s:%d, ", __FILE__, __LINE__);                 \
         fprintf(stderr, "code: %d, reason: %s\n", error,                       \
                 cudaGetErrorString(error));                                    \
         exit(1);                                                               \
     }                                                                          \
 }

/*
 * utils is a namespace for utility functions
 * including I/O (read input file and print results) and one matrix dimension convert(2D->1D) function
 */
namespace utils {
    int num_threads; //number of thread
    int N; //number of vertices
    int *mat; // the adjacency matrix

    string filename; // input file name
    string outputfile; //output file name, default: 'output.txt'

    void print_usage() {
        cout << "Usage:\n" << "\tcuda_dijkstra -n <number of threads per block> -i <input file>" << endl;
        exit(0);
    }

    int parse_args(int argc, char **argv) {
        filename = "";
        outputfile = "output.txt";
        num_threads = 0;

        int opt;
        if (argc < 2) {
            print_usage();
        }
        while ((opt = getopt(argc, argv, "n:i:o:h")) != EOF) {
            switch (opt) {
                case 'n':
                    num_threads = atoi(optarg);
                    break;
                case 'i':
                    filename = optarg;
                    break;
                case 'o':
                    outputfile = optarg;
                    break;
                case 'h':
                case '?':
                default:
                    print_usage();
            }
        }
        if (filename.length() == 0 || num_threads == 0)
            print_usage();
        return 0;
    }

    /*
     * convert 2-dimension coordinate to 1-dimension
     */
    int convert_dimension_2D_1D(int x, int y) {
        return x * N + y;
    }

    int read_file(string filename) {
        std::ifstream inputf(filename, std::ifstream::in);
        inputf >> N;
        assert(N < (1024 * 1024 *
                    20)); // input matrix should be smaller than 20MB * 20MB (400MB, we don't have too much memory for multi-processors)
        mat = (int *) malloc(N * N * sizeof(int));
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) {
                inputf >> mat[convert_dimension_2D_1D(i, j)];
            }

        return 0;
    }

    string format_path(int i, int *pred) {
        string out("");
        int current_vertex = i;
        while (current_vertex != 0) {
            string s = std::to_string(current_vertex);
            std::reverse(s.begin(), s.end());
            out = out + s + ">-";
            current_vertex = pred[current_vertex];
        }
        out = out + std::to_string(0);
        std::reverse(out.begin(), out.end());
        return out;
    }

    int print_result(int *dist, int *pred) {
        std::ofstream outputf(outputfile, std::ofstream::out);
        outputf << dist[0];
        for (int i = 1; i < N; i++) {
            outputf << " " << dist[i];
        }
        for (int i = 0; i < N; i++) {
            outputf << "\n";
            if (dist[i] >= 1000000) {
                outputf << "NO PATH";
            } else {
                outputf << format_path(i, pred);
            }
        }
        outputf << endl;
        return 0;
    }
}//namespace utils


//------You may add helper functions and global variables here------

/*
 * function: find the local minimum for each block and store them to d_local_min and d_local_min_index
 * parameters: N: input size, *d_visit: array to record which vertex has been visited, *d_all_dist: array to store the distance,
 *        *d_local_min: array to store the local minimum value for each block, *d_local_min_index: array to store the local minimum index for each block
 */
__global__ void FindLocalMin(int N, int *d_visit, int *d_all_dist, int *d_local_min, int *d_local_min_index) {
    int num_per_thread = (int) ceil(N * 1.0/(blockDim.x * gridDim.x));

    __shared__ int thread_local_min[1024];
    __shared__ int thread_local_min_index[1024];

    int start = (blockIdx.x * blockDim.x + threadIdx.x) * num_per_thread;
    int end = start + num_per_thread;
    if (end > N) {
        end = N;
    }

    int thread_min = INF + 1;
    int thread_min_index = -1;
    for (int i = start; i < end; i++)
    {
        if (d_all_dist[i] < thread_min && !d_visit[i])
        {
            thread_min = d_all_dist[i];
            thread_min_index = i;
        }
    }
    thread_local_min[threadIdx.x] = thread_min;
    thread_local_min_index[threadIdx.x] = thread_min_index;
    __syncthreads();

    if (threadIdx.x == 0) {
        int block_min = INF + 1;
        int block_min_index = -1;
        for (int i = 0; i < blockDim.x; i++)
        {
            if (thread_local_min[i] < block_min)
            {
                block_min = thread_local_min[i];
                block_min_index = thread_local_min_index[i];
            }
        }
        d_local_min[blockIdx.x] = block_min;
        d_local_min_index[blockIdx.x] = block_min_index;
    }
}

/*
 * function: update the global minimum value(and index), store them to a global memory address
 * parameters: *global_min: memory address to store the global min value, *global_min_index: memory address to store the global min index
 *        *d_local_min: array stores the local min value od each block, *d_local_min_index: array stores the local min index of each block
 *        *d_visit: array stores the status(visited/un-visited) for each vertex
 */
__global__ void
UpdateGlobalMin(int *global_min, int *global_min_index, int *d_local_min, int *d_local_min_index, int *d_visit) {
    if(blockIdx.x == 0 && threadIdx.x == 0)
    {
        int global_min_tmp = INF + 1;
        int global_index_tmp = -1;
        for (int i = 0; i < gridDim.x; i++)
        {
            if(global_min_tmp > d_local_min[i])
            {
                global_min_tmp = d_local_min[i];
                global_index_tmp = d_local_min_index[i];
            }
        }
        global_min[0] = global_min_tmp;
        global_min_index[0] = global_index_tmp;
        d_visit[global_min_index[0]] = true;
    }
}

/*
 * function: update the shortest path for every un-visited vertices
 * parameters: N: input size, *mat: input matrix, *d_visit: array stores the status(visited/un-visited) for each vertex
 *             *d_all_dist: array stores the shortest distance for each vertex, *d_all_pred: array stores the predecessors
 *             *global_min: memory address that stores the global min value, *global_min_index: memory address that stores the global min index
 */
__global__ void
UpdatePath(int N, int *mat, int *d_visit, int *d_all_dist, int *d_all_pred, int *global_min, int *global_min_index) {
    int num_per_thread = (int) ceil(N * 1.0/(blockDim.x * gridDim.x));

    int start = (blockIdx.x * blockDim.x + threadIdx.x) * num_per_thread;
    int end = start + num_per_thread;
    if (end > N) {
        end = N;
    }

    for(int i = start; i < end; i++)
    {
        if (global_min[0] + mat[global_min_index[0] * N + i] < d_all_dist[i])
        {
            d_all_dist[i] = global_min[0] + mat[global_min_index[0] * N + i];
            d_all_pred[i] = global_min_index[0];
        }
    }
    __syncthreads();
}

//Do not change anything below this line
void dijkstra(int N, int p, int *mat, int *all_dist, int *all_pred) {

    //threads number for each block should smaller than or equal to 1024
    assert(p <= 1024);

    //we restrict this value to 8, DO NOT change it!
    int blocksPerGrid = 8;

    //NOTICE: (p * 8) may LESS THAN N
    int threadsPerBlock = p;

    dim3 blocks(blocksPerGrid);
    dim3 threads(threadsPerBlock);


    //allocate memory
    int *h_visit;
    int *d_mat, *d_visit, *d_all_dist, *d_all_pred, *d_local_min, *d_local_min_index;
    int *d_global_min, *d_global_min_index;

    h_visit = (int *) calloc(N, sizeof(int));
    cudaMalloc(&d_mat, sizeof(int) * N * N);
    cudaMalloc(&d_visit, sizeof(int) * N);
    cudaMalloc(&d_all_dist, sizeof(int) * N);
    cudaMalloc(&d_all_pred, sizeof(int) * N);
    cudaMalloc(&d_local_min, sizeof(int) * blocksPerGrid);
    cudaMalloc(&d_local_min_index, sizeof(int) * blocksPerGrid);
    cudaMalloc(&d_global_min, sizeof(int));
    cudaMalloc(&d_global_min_index, sizeof(int));

    //initialization and copy data from host to device
    for (int i = 0; i < N; i++) {
        all_dist[i] = mat[i];
        all_pred[i] = 0;
        h_visit[i] = 0;
    }
    //h_visit[0] = 1;

    cudaMemcpy(d_mat, mat, sizeof(int) * N * N, cudaMemcpyHostToDevice);
    cudaMemcpy(d_all_dist, all_dist, sizeof(int) * N, cudaMemcpyHostToDevice);
    cudaMemcpy(d_all_pred, all_pred, sizeof(int) * N, cudaMemcpyHostToDevice);
    cudaMemcpy(d_visit, h_visit, sizeof(int) * N, cudaMemcpyHostToDevice);

    //dijkstra iterations
    for (int iter = 1; iter < N; iter++) {
        FindLocalMin <<< blocks, threads >>> (N, d_visit, d_all_dist, d_local_min, d_local_min_index);
        //CHECK(cudaDeviceSynchronize()); //only for debug
        //printf("%s%d\n", "Iter Num: ", iter);
        UpdateGlobalMin <<< blocks, threads >>>
                                    (d_global_min, d_global_min_index, d_local_min, d_local_min_index, d_visit);
        //CHECK(cudaDeviceSynchronize()); //only for debug
        UpdatePath << < blocks, threads >> >
                                (N, d_mat, d_visit, d_all_dist, d_all_pred, d_global_min, d_global_min_index);
        //CHECK(cudaDeviceSynchronize()); //only for debug
    }

    //copy results from device to host
    cudaMemcpy(all_dist, d_all_dist, sizeof(int) * N, cudaMemcpyDeviceToHost);
    cudaMemcpy(all_pred, d_all_pred, sizeof(int) * N, cudaMemcpyDeviceToHost);

    //free memory
    free(h_visit);
    cudaFree(d_mat);
    cudaFree(d_visit);
    cudaFree(d_all_dist);
    cudaFree(d_all_pred);
    cudaFree(d_local_min);
    cudaFree(d_local_min_index);
    cudaFree(d_global_min);
    cudaFree(d_global_min_index);

}

int main(int argc, char **argv) {
    assert(utils::parse_args(argc, argv) == 0);
    assert(utils::read_file(utils::filename) == 0);

    //`all_dist` stores the distances and `all_pred` stores the predecessors
    int *all_dist;
    int *all_pred;
    all_dist = (int *) calloc(utils::N, sizeof(int));
    all_pred = (int *) calloc(utils::N, sizeof(int));

    //time counter
    timeval start_wall_time_t, end_wall_time_t;
    float ms_wall;

    cudaDeviceReset();

    //start timer
    gettimeofday(&start_wall_time_t, nullptr);
    dijkstra(utils::N, utils::num_threads, utils::mat, all_dist, all_pred);
    CHECK(cudaDeviceSynchronize());

    //end timer
    gettimeofday(&end_wall_time_t, nullptr);
    ms_wall = ((end_wall_time_t.tv_sec - start_wall_time_t.tv_sec) * 1000 * 1000
               + end_wall_time_t.tv_usec - start_wall_time_t.tv_usec) / 1000.0;

    std::cerr << "Time(ms): " << ms_wall << endl;

    utils::print_result(all_dist, all_pred);

    free(utils::mat);
    free(all_dist);
    free(all_pred);

    return 0;
}
