/*!
 *  Copyright (c) 2022 by Contributors
 * \file array/cuda/rowwise_sampling_prob.cu
 * \brief weighted rowwise sampling
 * \author pengqirong (OPPO)
 */
#include <dgl/random.h>
#include <dgl/runtime/device_api.h>
#include <curand_kernel.h>
#include <numeric>

#include "./dgl_cub.cuh"
#include "../../array/cuda/atomic.cuh"
#include "../../runtime/cuda/cuda_common.h"

using namespace dgl::aten::cuda;

namespace dgl {
namespace aten {
namespace impl {

namespace {

constexpr int CTA_SIZE = 128;

/**
* @brief Compute the size of each row in the sampled CSR, without replacement.
*
* @tparam IdType The type of node and edge indexes.
* @param num_picks The number of non-zero entries to pick per row.
* @param num_rows The number of rows to pick.
* @param in_rows The set of rows to pick.
* @param in_ptr The index where each row's edges start.
* @param out_deg The size of each row in the sampled matrix, as indexed by `in_rows` (output).
* @param temp_deg The size of each row in the input matrix, as indexed by `in_rows` (output).
*/
template<typename IdType>
__global__ void _CSRRowWiseSampleDegreeKernel(
    const int64_t num_picks,
    const int64_t num_rows,
    const IdType * const in_rows,
    const IdType * const in_ptr,
    IdType * const out_deg,
    IdType * const temp_deg) {
  const int64_t tIdx = threadIdx.x + blockIdx.x * blockDim.x;

  if (tIdx < num_rows) {
    const int64_t in_row = in_rows[tIdx];
    const int64_t out_row = tIdx;
    const int64_t deg = in_ptr[in_row + 1]- in_ptr[in_row];
    // temp_deg is used to generate ares_ptr
    temp_deg[out_row] = deg > num_picks ? deg : 0;
    out_deg[out_row] = min(num_picks, deg);

    if (out_row == num_rows - 1) {
      // make the prefixsum work
      out_deg[num_rows] = 0;
      temp_deg[num_rows] = 0;
    }
  }
}

/**
* @brief Compute the size of each row in the sampled CSR, with replacement.
*
* @tparam IdType The type of node and edge indexes.
* @param num_picks The number of non-zero entries to pick per row.
* @param num_rows The number of rows to pick.
* @param in_rows The set of rows to pick.
* @param in_ptr The index where each row's edges start.
* @param out_deg The size of each row in the sampled matrix, as indexed by `in_rows` (output).
* @param temp_deg The size of each row in the input matrix, as indexed by `in_rows` (output).
*/
template<typename IdType>
__global__ void _CSRRowWiseSampleDegreeReplaceKernel(
    const int64_t num_picks,
    const int64_t num_rows,
    const IdType * const in_rows,
    const IdType * const in_ptr,
    IdType * const out_deg,
    IdType * const temp_deg) {
  const int64_t tIdx = threadIdx.x + blockIdx.x * blockDim.x;

  if (tIdx < num_rows) {
    const int64_t in_row = in_rows[tIdx];
    const int64_t out_row = tIdx;

    const int64_t deg = in_ptr[in_row + 1]- in_ptr[in_row];
    temp_deg[out_row] = static_cast<IdType>(deg);
    out_deg[out_row] = static_cast<IdType>(deg == 0 ? 0 : num_picks);

    if (out_row == num_rows - 1) {
      // make the prefixsum work
      out_deg[num_rows] = 0;
      temp_deg[num_rows] = 0;
    }
  }
}

/**
* @brief Compute A-Res value. A-Res value needs to be calculated only if deg 
* is greater than num_picks in without replacement weighted rowwise sampling.
*
* @tparam IdType The ID type used for matrices.
* @tparam FloatType The Float type used for matrices.
* @tparam BLOCK_CTAS The number of rows each thread block runs in parallel.
* @tparam TILE_SIZE The number of rows covered by each threadblock.
* @param rand_seed The random seed to use.
* @param num_picks The number of non-zeros to pick per row.
* @param num_rows The number of rows to pick.
* @param in_rows The set of rows to pick.
* @param in_ptr The indptr array of the input CSR.
* @param prob The probability array of the input CSR.
* @param ares_ptr The offset to write each row to in the A-res array.
* @param ares_idxs The A-Res value corresponding index array, the index of input CSR.
* @param ares The A-Res value array.
* @author pengqirong (OPPO)
*/
template<typename IdType, typename FloatType, int BLOCK_CTAS, int TILE_SIZE>
__global__ void _CSR_A_Res(
    const uint64_t rand_seed,
    const int64_t num_picks,
    const int64_t num_rows,
    const IdType * const in_rows,
    const IdType * const in_ptr,
    const FloatType * const prob,
    const IdType * const ares_ptr, 
    IdType * const ares_idxs, 
    FloatType * const ares) {

  int64_t out_row = blockIdx.x * TILE_SIZE + threadIdx.y;
  const int64_t last_row = min(static_cast<int64_t>(blockIdx.x + 1) * TILE_SIZE, num_rows);

  curandStatePhilox4_32_10_t rng;
  curand_init((rand_seed * gridDim.x + blockIdx.x) * blockDim.y + threadIdx.y, threadIdx.x, 0, &rng);

  while (out_row < last_row) {
    const int64_t row = in_rows[out_row];

    const int64_t in_row_start = in_ptr[row];
    const int64_t deg = in_ptr[row + 1] - in_row_start;
    // A-Res value needs to be calculated only if deg is greater than num_picks in without replacement weighted rowwise sampling
    if (deg > num_picks) {
      const int64_t ares_row_start = ares_ptr[out_row];

      for (int64_t idx = threadIdx.x; idx < deg; idx += CTA_SIZE) {
        const int64_t in_idx = in_row_start + idx;
        const int64_t ares_idx = ares_row_start + idx;
        FloatType item_prob = prob[in_idx];
        // compute A-Res value
        ares[ares_idx] = static_cast<FloatType> (item_prob > 0.0f ? __powf(curand_uniform(&rng), 1.0f / item_prob) : 0.0f);
        ares_idxs[ares_idx] = static_cast<IdType>(in_idx);
      }

    }
    out_row += BLOCK_CTAS;
  }
}


/**
* @brief Perform weighted row-wise sampling on a CSR matrix, and generate a COO matrix,
* without replacement.
*
* @tparam IdType The ID type used for matrices.
* @tparam FloatType The Float type used for matrices.
* @tparam BLOCK_CTAS The number of rows each thread block runs in parallel.
* @tparam TILE_SIZE The number of rows covered by each threadblock.
* @param num_picks The number of non-zeros to pick per row.
* @param num_rows The number of rows to pick.
* @param in_rows The set of rows to pick.
* @param in_ptr The indptr array of the input CSR.
* @param in_cols The columns array of the input CSR.
* @param data The data array of the input CSR.
* @param out_ptr The offset to write each row to in the output COO.
* @param out_rows The rows of the output COO (output).
* @param out_cols The columns of the output COO (output).
* @param out_idxs The data array of the output COO (output).
* @param ares_ptr The offset to write each row to in the ares array.
* @param sort_ares_idxs The sorted A-Res value corresponding index array, the index of input CSR.
* @author pengqirong (OPPO)
*/
template<typename IdType, typename FloatType, int BLOCK_CTAS, int TILE_SIZE>
__global__ void _CSRRowWiseSampleKernel(
    const int64_t num_picks,
    const int64_t num_rows,
    const IdType * const in_rows,
    const IdType * const in_ptr,
    const IdType * const in_cols,
    const IdType * const data,
    const IdType * const out_ptr,
    IdType * const out_rows,
    IdType * const out_cols,
    IdType * const out_idxs,
    const IdType * const ares_ptr, 
    const IdType * const sort_ares_idxs) {
  // we assign one warp per row
  assert(blockDim.x == CTA_SIZE);

  int64_t out_row = blockIdx.x * TILE_SIZE + threadIdx.y;
  const int64_t last_row = min(static_cast<int64_t>(blockIdx.x + 1) * TILE_SIZE, num_rows);

  while (out_row < last_row) {
    const int64_t row = in_rows[out_row];

    const int64_t in_row_start = in_ptr[row];
    const int64_t out_row_start = out_ptr[out_row];
    const int64_t deg = in_ptr[row + 1] - in_row_start;


    if (deg > num_picks) {
      const int64_t ares_row_start = ares_ptr[out_row];
      for (int64_t idx = threadIdx.x; idx < num_picks; idx += CTA_SIZE) {
        // get in and out index, the in_idx is one of top num_picks A-Res value corresponding index in input CSR.
        const int64_t out_idx = out_row_start + idx;
        const int64_t ares_idx = ares_row_start + idx;
        const int64_t in_idx = sort_ares_idxs[ares_idx];
        // copy permutation over
        out_rows[out_idx] = static_cast<IdType>(row);
        out_cols[out_idx] = in_cols[in_idx];
        out_idxs[out_idx] = static_cast<IdType>(data ? data[in_idx] : in_idx);
      }
    } else {
      for (int64_t idx = threadIdx.x; idx < deg; idx += CTA_SIZE) {
        // get in and out index
        const int64_t out_idx = out_row_start + idx;
        const int64_t in_idx = in_row_start + idx;
        // copy permutation over
        out_rows[out_idx] = static_cast<IdType>(row);
        out_cols[out_idx] = in_cols[in_idx];
        out_idxs[out_idx] = static_cast<IdType>(data ? data[in_idx] : in_idx);
      }
    }

    out_row += BLOCK_CTAS;
  }
}


// A stateful callback functor that maintains a running prefix to be applied
// during consecutive scan operations.
template<typename FloatType>
struct BlockPrefixCallbackOp
{
    // Running prefix
    FloatType running_total;
    // Constructor
    __device__ BlockPrefixCallbackOp(FloatType running_total) : running_total(running_total) {}
    // Callback operator to be entered by the first warp of threads in the block.
    // Thread-0 is responsible for returning a value for seeding the block-wide scan.
    __device__ FloatType operator()(FloatType block_aggregate)
    {
        FloatType old_prefix = running_total;
        running_total += block_aggregate;
        return old_prefix;
    }
};

/**
* @brief Perform weighted row-wise sampling on a CSR matrix, and generate a COO matrix,
* with replacement.
*
* @tparam IdType The ID type used for matrices.
* @tparam FloatType The Float type used for matrices.
* @tparam BLOCK_CTAS The number of rows each thread block runs in parallel.
* @tparam TILE_SIZE The number of rows covered by each threadblock.
* @param rand_seed The random seed to use.
* @param num_picks The number of non-zeros to pick per row.
* @param num_rows The number of rows to pick.
* @param in_rows The set of rows to pick.
* @param in_ptr The indptr array of the input CSR.
* @param in_cols The columns array of the input CSR.
* @param data The data array of the input CSR.
* @param out_ptr The offset to write each row to in the output COO.
* @param out_rows The rows of the output COO (output).
* @param out_cols The columns of the output COO (output).
* @param out_idxs The data array of the output COO (output).
* @param ares_ptr The offset to write each row to in the ares array.
* @param sort_ares_idxs The sorted A-Res value corresponding index array, the index of input CSR.
* @author pengqirong (OPPO)
*/
template<typename IdType, typename FloatType, int BLOCK_CTAS, int TILE_SIZE>
__global__ void _CSRRowWiseSampleReplaceKernel(
    const uint64_t rand_seed,
    const int64_t num_picks,
    const int64_t num_rows,
    const IdType * const in_rows,
    const IdType * const in_ptr,
    const IdType * const in_cols,
    const IdType * const data,
    const FloatType * const prob,
    const IdType * const out_ptr,
    IdType * const out_rows,
    IdType * const out_cols,
    IdType * const out_idxs,
    const IdType * const cdf_ptr, 
    FloatType * const cdf
) {
  // we assign one warp per row
  assert(blockDim.x == CTA_SIZE);

  int64_t out_row = blockIdx.x * TILE_SIZE + threadIdx.y;
  const int64_t last_row = min(static_cast<int64_t>(blockIdx.x + 1) * TILE_SIZE, num_rows);

  curandStatePhilox4_32_10_t rng;
  curand_init((rand_seed * gridDim.x + blockIdx.x) * blockDim.y + threadIdx.y, threadIdx.x, 0, &rng);

  while (out_row < last_row) {
    const int64_t row = in_rows[out_row];

    const int64_t in_row_start = in_ptr[row];
    const int64_t out_row_start = out_ptr[out_row];
    const int64_t cdf_row_start = cdf_ptr[out_row];

    const int64_t deg = in_ptr[row + 1] - in_row_start;
    const FloatType MIN_THREAD_DATA = static_cast<FloatType>(0.0f);

    if (deg > 0) {
        // Specialize BlockScan for a 1D block of CTA_SIZE threads
        typedef cub::BlockScan<FloatType, CTA_SIZE> BlockScan;
        // Allocate shared memory for BlockScan
        __shared__ typename BlockScan::TempStorage temp_storage;
        // Initialize running total
        BlockPrefixCallbackOp<FloatType> prefix_op(MIN_THREAD_DATA);

        int64_t max = (1 + (deg - 1) / CTA_SIZE) * CTA_SIZE;
        // Have the block iterate over segments of items
        for (int64_t idx = threadIdx.x; idx < max; idx += CTA_SIZE)
        {
            // Load a segment of consecutive items that are blocked across threads
            FloatType thread_data = idx < deg ? prob[in_row_start + idx] : MIN_THREAD_DATA;
            if (thread_data < MIN_THREAD_DATA) {
              thread_data = MIN_THREAD_DATA;
            }
            // Collectively compute the block-wide inclusive prefix sum
            BlockScan(temp_storage).InclusiveSum(thread_data, thread_data, prefix_op);
            __syncthreads();

            // Store scanned items to cdf array
            if (idx < deg) {
              cdf[cdf_row_start + idx] = thread_data;
            }
        }
        __syncthreads();
        
        for (int64_t idx = threadIdx.x; idx < num_picks; idx += CTA_SIZE) {
            // get random value
            FloatType sum = cdf[cdf_row_start + deg - 1]; 
            FloatType rand = static_cast<FloatType>(curand_uniform(&rng) * sum);
            // get the offset of the first value within cdf array which compares greater than random value. 
            int64_t item = cub::UpperBound<FloatType* , int64_t, FloatType>(&cdf[cdf_row_start], deg, rand);
            item = min(item, deg - 1);
            // get in and out index
            const int64_t in_idx = in_row_start + item;
            const int64_t out_idx = out_row_start + idx;
            // copy permutation over
            out_rows[out_idx] = static_cast<IdType>(row);
            out_cols[out_idx] = in_cols[in_idx];
            out_idxs[out_idx] = static_cast<IdType>(data ? data[in_idx] : in_idx);
        }
    }
    out_row += BLOCK_CTAS;
  }
}

}  // namespace

/////////////////////////////// CSR ///////////////////////////////

/**
* @brief Perform weighted row-wise sampling on a CSR matrix, and generate a COO matrix.
* Use CDF sampling algorithm with replacement and A-Res sampling algorithm without replacement
*
* @tparam XPU The device type used for matrices.
* @tparam IdType The ID type used for matrices.
* @tparam FloatType The Float type used for matrices.
* @param mat The CSR matrix.
* @param rows The set of rows to pick.
* @param num_picks The number of non-zeros to pick per row.
* @param prob The probability array of the input CSR.
* @param replace Is replacement sampling?
* @author pengqirong (OPPO)
*/
template <DLDeviceType XPU, typename IdType, typename FloatType>
COOMatrix CSRRowWiseSampling(CSRMatrix mat, 
                             IdArray rows, 
                             int64_t num_picks,
                             FloatArray prob, 
                             bool replace) {
  const auto& ctx = rows->ctx;
  auto device = runtime::DeviceAPI::Get(ctx);

  // TODO(dlasalle): Once the device api supports getting the stream from the
  // context, that should be used instead of the default stream here.
  cudaStream_t stream = 0;

  const int64_t num_rows = rows->shape[0];
  const IdType * const slice_rows = static_cast<const IdType*>(rows->data);

  IdArray picked_row = NewIdArray(num_rows * num_picks, ctx, sizeof(IdType) * 8);
  IdArray picked_col = NewIdArray(num_rows * num_picks, ctx, sizeof(IdType) * 8);
  IdArray picked_idx = NewIdArray(num_rows * num_picks, ctx, sizeof(IdType) * 8);
  const IdType * const in_ptr = static_cast<const IdType*>(mat.indptr->data);
  const IdType * const in_cols = static_cast<const IdType*>(mat.indices->data);
  IdType* const out_rows = static_cast<IdType*>(picked_row->data);
  IdType* const out_cols = static_cast<IdType*>(picked_col->data);
  IdType* const out_idxs = static_cast<IdType*>(picked_idx->data);

  const IdType* const data = CSRHasData(mat) ?
      static_cast<IdType*>(mat.data->data) : nullptr;
  const FloatType* const prob_data = static_cast<const FloatType*>(prob->data);

  // compute degree
  IdType * out_deg = static_cast<IdType*>(
      device->AllocWorkspace(ctx, (num_rows + 1) * sizeof(IdType)));
  IdType * temp_deg = static_cast<IdType*>(
    device->AllocWorkspace(ctx, (num_rows + 1) * sizeof(IdType)));
  if (replace) {
    const dim3 block(512);
    const dim3 grid((num_rows + block.x - 1) / block.x);
    _CSRRowWiseSampleDegreeReplaceKernel<<<grid, block, 0, stream>>>(
        num_picks, num_rows, slice_rows, in_ptr, out_deg, temp_deg);
  } else {
    const dim3 block(512);
    const dim3 grid((num_rows + block.x - 1) / block.x);
    _CSRRowWiseSampleDegreeKernel<<<grid, block, 0, stream>>>(
        num_picks, num_rows, slice_rows, in_ptr, out_deg, temp_deg);
  }

  // fill temp_ptr
  IdType * temp_ptr = static_cast<IdType*>(
    device->AllocWorkspace(ctx, (num_rows + 1)*sizeof(IdType)));
  size_t prefix_temp_size1 = 0;
  CUDA_CALL(cub::DeviceScan::ExclusiveSum(nullptr, prefix_temp_size1,
      temp_deg,
      temp_ptr,
      num_rows + 1,
      stream));
  void * prefix_temp1 = device->AllocWorkspace(ctx, prefix_temp_size1);
  CUDA_CALL(cub::DeviceScan::ExclusiveSum(prefix_temp1, prefix_temp_size1,
      temp_deg,
      temp_ptr,
      num_rows + 1,
      stream));
  device->FreeWorkspace(ctx, prefix_temp1);
  device->FreeWorkspace(ctx, temp_deg);

  cudaEvent_t copyEvent1;
  CUDA_CALL(cudaEventCreate(&copyEvent1));
  
  // TODO(dlasalle): use pinned memory to overlap with the actual sampling, and wait on
  // a cudaevent
  IdType temp_len;
  device->CopyDataFromTo(temp_ptr, num_rows * sizeof(temp_len), &temp_len, 0,
        sizeof(temp_len),
        ctx,
        DGLContext{kDLCPU, 0},
        mat.indptr->dtype,
        stream);
  CUDA_CALL(cudaEventRecord(copyEvent1, stream));
  
  // fill out_ptr
  IdType * out_ptr = static_cast<IdType*>(
      device->AllocWorkspace(ctx, (num_rows+1)*sizeof(IdType)));
  size_t prefix_temp_size = 0;
  CUDA_CALL(cub::DeviceScan::ExclusiveSum(nullptr, prefix_temp_size,
      out_deg,
      out_ptr,
      num_rows+1,
      stream));
  void * prefix_temp = device->AllocWorkspace(ctx, prefix_temp_size);
  CUDA_CALL(cub::DeviceScan::ExclusiveSum(prefix_temp, prefix_temp_size,
      out_deg,
      out_ptr,
      num_rows+1,
      stream));
  device->FreeWorkspace(ctx, prefix_temp);
  device->FreeWorkspace(ctx, out_deg);

  cudaEvent_t copyEvent;
  CUDA_CALL(cudaEventCreate(&copyEvent));
  // TODO(dlasalle): use pinned memory to overlap with the actual sampling, and wait on
  // a cudaevent
  IdType new_len;
  device->CopyDataFromTo(out_ptr, num_rows * sizeof(new_len), &new_len, 0,
        sizeof(new_len),
        ctx,
        DGLContext{kDLCPU, 0},
        mat.indptr->dtype,
        stream);
  CUDA_CALL(cudaEventRecord(copyEvent, stream));

  // wait for copying `temp_len` to finish
  CUDA_CALL(cudaEventSynchronize(copyEvent1));
  CUDA_CALL(cudaEventDestroy(copyEvent1));

  FloatType * temp = static_cast<FloatType*>(
      device->AllocWorkspace(ctx, temp_len * sizeof(FloatType)));

  const uint64_t rand_seed = RandomEngine::ThreadLocal()->RandInt(1000000000);

  // select edges
  if (replace) {
    constexpr int BLOCK_CTAS = 128 / CTA_SIZE;
    // the number of rows each thread block will cover
    constexpr int TILE_SIZE = BLOCK_CTAS;
    const dim3 block(CTA_SIZE, BLOCK_CTAS);
    const dim3 grid((num_rows + TILE_SIZE - 1) / TILE_SIZE);
    // Perform weighted row-wise sampling on a CSR matrix, and generate a COO matrix,
    // with replacement.
    _CSRRowWiseSampleReplaceKernel<IdType, FloatType, BLOCK_CTAS, TILE_SIZE><<<grid, block, 0, stream>>>(
      rand_seed, 
      num_picks, 
      num_rows, 
      slice_rows, 
      in_ptr, 
      in_cols, 
      data, 
      prob_data, 
      out_ptr, 
      out_rows, 
      out_cols, 
      out_idxs, 
      temp_ptr, 
      temp);
    device->FreeWorkspace(ctx, temp);
  } else {
    IdType* temp_idxs = static_cast<IdType*>(
      device->AllocWorkspace(ctx, (temp_len) * sizeof(IdType)));

    constexpr int BLOCK_CTAS = 128 / CTA_SIZE;
    // the number of rows each thread block will cover
    constexpr int TILE_SIZE = BLOCK_CTAS;
    const dim3 block(CTA_SIZE, BLOCK_CTAS);
    const dim3 grid((num_rows + TILE_SIZE - 1) / TILE_SIZE);

    // Compute A-Res value. A-Res value needs to be calculated only if deg 
    // is greater than num_picks in without replacement weighted rowwise sampling.
    _CSR_A_Res<IdType, FloatType, BLOCK_CTAS, TILE_SIZE><<<grid, block, 0, stream>>>(
      rand_seed, 
      num_picks, 
      num_rows, 
      slice_rows, 
      in_ptr, 
      prob_data, 
      temp_ptr, 
      temp_idxs, 
      temp);

    // sort A-Res value array.
    FloatType* sort_temp = static_cast<FloatType*>(
      device->AllocWorkspace(ctx, temp_len * sizeof(FloatType)));
    IdType* sort_temp_idxs = static_cast<IdType*>(
      device->AllocWorkspace(ctx, (temp_len) * sizeof(IdType)));

    cub::DoubleBuffer<FloatType> sort_keys(temp, sort_temp);
    cub::DoubleBuffer<IdType> sort_values(temp_idxs, sort_temp_idxs);

    void *d_temp_storage = nullptr;
    size_t temp_storage_bytes = 0;

    CUDA_CALL(cub::DeviceSegmentedRadixSort::SortPairsDescending(
      d_temp_storage, 
      temp_storage_bytes, 
      sort_keys, 
      sort_values, 
      temp_len, 
      num_rows, 
      temp_ptr, 
      temp_ptr + 1, 
      0, 
      sizeof(FloatType) * 8, stream));

    d_temp_storage = device->AllocWorkspace(ctx, temp_storage_bytes);

    CUDA_CALL(cub::DeviceSegmentedRadixSort::SortPairsDescending(
      d_temp_storage, 
      temp_storage_bytes, 
      sort_keys, 
      sort_values, 
      temp_len, 
      num_rows, 
      temp_ptr, 
      temp_ptr + 1, 0, 
      sizeof(FloatType) * 8, 
      stream));

    device->FreeWorkspace(ctx, d_temp_storage);
    device->FreeWorkspace(ctx, temp);
    device->FreeWorkspace(ctx, temp_idxs);
    device->FreeWorkspace(ctx, sort_temp);
    // Perform weighted row-wise sampling on a CSR matrix, and generate a COO matrix,
    // without replacement.
    _CSRRowWiseSampleKernel<IdType, FloatType, BLOCK_CTAS, TILE_SIZE><<<grid, block, 0, stream>>>(
      num_picks,
      num_rows,
      slice_rows,
      in_ptr,
      in_cols,
      data, 
      out_ptr,
      out_rows,
      out_cols,
      out_idxs, 
      temp_ptr,
      sort_temp_idxs
    );

    device->FreeWorkspace(ctx, sort_temp_idxs);
  }

  device->FreeWorkspace(ctx, temp_ptr);
  device->FreeWorkspace(ctx, out_ptr);

  // wait for copying `new_len` to finish
  CUDA_CALL(cudaEventSynchronize(copyEvent));
  CUDA_CALL(cudaEventDestroy(copyEvent));

  picked_row = picked_row.CreateView({new_len}, picked_row->dtype);
  picked_col = picked_col.CreateView({new_len}, picked_col->dtype);
  picked_idx = picked_idx.CreateView({new_len}, picked_idx->dtype);

  return COOMatrix(mat.num_rows, mat.num_cols, picked_row,
      picked_col, picked_idx);
}

template COOMatrix CSRRowWiseSampling<kDLGPU, int32_t, float>(
  CSRMatrix, IdArray, int64_t, FloatArray, bool);
template COOMatrix CSRRowWiseSampling<kDLGPU, int64_t, float>(
  CSRMatrix, IdArray, int64_t, FloatArray, bool);
template COOMatrix CSRRowWiseSampling<kDLGPU, int32_t, double>(
  CSRMatrix, IdArray, int64_t, FloatArray, bool);
template COOMatrix CSRRowWiseSampling<kDLGPU, int64_t, double>(
  CSRMatrix, IdArray, int64_t, FloatArray, bool);


}  // namespace impl
}  // namespace aten
}  // namespace dgl
