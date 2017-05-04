# CUDA_Dijkstra

A dijkstra CUDA version

Compile with:

 $ nvcc -std=c++11 -arch=sm_52 -o cuda_dijkstra cuda_dijkstra.cu

Run with:

 ./cuda_dijkstra -n <number of threads> -i <input file>
