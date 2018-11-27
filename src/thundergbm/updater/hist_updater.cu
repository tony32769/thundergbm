
#include <thundergbm/updater/hist_updater.h>

#include "thundergbm/updater/hist_updater.h"
#include "thundergbm/util/cub_wrapper.h"

void HistUpdater::init_cut(const vector<std::shared_ptr<SparseColumns>> &v_columns, InsStat &stats, int n_instances) {
    LOG(TRACE) << "init cut";
    if (!do_cut) {
        v_cut.resize(n_devices);
        for (int i = 0; i < n_devices; i++)
            v_cut[i].get_cut_points(*v_columns[i], stats, max_num_bin, n_instances, i);
        bin_id.resize(n_devices);
        cub_seg_sort_by_key(v_columns[0]->csc_row_idx, v_columns[0]->csc_val, v_columns[0]->csc_col_ptr, true);
        DO_ON_MULTI_DEVICES(n_devices, [&](int device_id) {
            get_bin_ids(*v_columns[device_id]);
        });
    }
//    LOG(INFO) << v_cut[0].cut_points;
//    LOG(INFO) << v_cut[0].cut_points_val;
//    LOG(INFO) << v_cut[0].cut_row_ptr;
//    LOG(INFO) << v_columns[0]->csc_val;
//    LOG(INFO) << *bin_id[0];
    do_cut = 1;
}

void HistUpdater::get_bin_ids(const SparseColumns &columns) {
    using namespace thrust;
    int cur_device;
    cudaGetDevice(&cur_device);
    int n_column = columns.n_column;
    int nnz = columns.nnz;
    auto cut_row_ptr = v_cut[cur_device].cut_row_ptr.host_data();
    auto cut_points_ptr = v_cut[cur_device].cut_points_val.device_data();
    auto csc_val_data = columns.csc_val.device_data();
    auto csc_col_data = columns.csc_col_ptr.host_data();
    bin_id[cur_device].reset(new SyncArray<int>(nnz));
    auto bin_id_ptr = (*bin_id[cur_device]).device_data();
    int n_block = (nnz - 1) / 256 + 1;
//    device_loop_2d(n_column, columns.csc_col_ptr.device_data(), [=]__device__(int cid, int i){
//        auto cutbegin = cut_points_ptr + cut_row_ptr[cid];
//        auto cutend = cut_points_ptr + cut_row_ptr[cid + 1];
//        bin_id_ptr[i] = lower_bound(cuda::par, cutbegin, cutend, csc_val_data[i], thrust::greater<float_type>()) - cutbegin;
//    }, n_column);
//    device_loop(n_column, [=]__device__(int cid) {
    for (int cid = 0; cid < n_column; ++cid) {
        auto cutbegin = cut_points_ptr + cut_row_ptr[cid];
        auto cutend = cut_points_ptr + cut_row_ptr[cid + 1];
        auto valbeign = csc_val_data + csc_col_data[cid];
        auto valend = csc_val_data + csc_col_data[cid + 1];
        lower_bound(cuda::par, cutbegin, cutend, valbeign, valend,
                    bin_id_ptr + csc_col_data[cid], thrust::greater<float_type>());
    }
//        for_each(cuda::par, bin_id_ptr + csc_col_data[cid],
//                 bin_id_ptr + csc_col_data[cid + 1], thrust::placeholders::_1 += cut_row_ptr[cid]);
//    });
}

__global__ void
hist_kernel(GHPair *hist_data, int fea_offset, const int *bid, int bin_id_len, int n_fea_bin, int n_bins,
            const int *iid, const GHPair *gh, const int *nid, int nid_offset, int n_nodes_in_level) {
    //n_nodes_in_level * n_fea_bin
    extern __shared__ GHPair local_hist[];
    for (int i = threadIdx.x; i < n_fea_bin * n_nodes_in_level; i += blockDim.x) {
        local_hist[i] = 0;
    }
    __syncthreads();

    for (int i = blockIdx.x * blockDim.x + threadIdx.x; i < bin_id_len; i += blockDim.x * gridDim.x) {
        int ins_id = iid[i];
        int node_id0 = nid[ins_id] - nid_offset;
        if (node_id0 < 0) return;
        int bin_id = bid[i];
        GHPair &dest = local_hist[node_id0 * n_fea_bin + bin_id];
        const GHPair &src = gh[ins_id];
        atomicAdd(&dest.g, src.g);
        atomicAdd(&dest.h, src.h);
    }
    __syncthreads();
    for (int i = threadIdx.x; i < n_fea_bin * n_nodes_in_level; i += blockDim.x) {
        int node_id0 = i / n_fea_bin;
        int bin_id = i % n_fea_bin;
        GHPair &dest = hist_data[node_id0 * n_bins + fea_offset + bin_id];
        GHPair &src = local_hist[i];
        atomicAdd(&dest.g, src.g);
        atomicAdd(&dest.h, src.h);
    }
}

void HistUpdater::find_split(int level, const SparseColumns &columns, const Tree &tree, const InsStat &stats,
                             const HistCut &cut,
                             SyncArray<SplitPoint> &sp) {
    int n_nodes_in_level = static_cast<int>(pow(2, level));
    int nid_offset = static_cast<int>(pow(2, level) - 1);
    int n_column = columns.n_column;
    int n_partition = n_column * n_nodes_in_level;
    int nnz = columns.nnz;
    int n_bins = cut.cut_points.size();
    int n_block = std::min((nnz / n_column - 1) / 256 + 1, 32 * 56);
    int n_max_nodes = 2 << this->depth;
    int n_max_splits = n_max_nodes * n_bins;
    int n_split = n_nodes_in_level * n_bins;

    LOG(TRACE) << "start finding split";

    //find the best split locally
    {
        using namespace thrust;

        //calculate split information for each split
        SyncArray<GHPair> hist(n_max_splits);
        SyncArray<GHPair> missing_gh(n_partition);
        auto cut_fid_data = cut.cut_fid.device_data();
        auto i2fid = [=] __device__(int i) { return cut_fid_data[i % n_bins]; };
        auto hist_fid = make_transform_iterator(counting_iterator<int>(0), i2fid);
        {
            {
                TIMED_SCOPE(timerObj, "histogram");
                //input
                {
//                    TIMED_SCOPE(timerOBj, "hist");
//                    auto *nid_data = stats.nid.device_data();
//                    auto hist_data = hist.device_data();
//                    auto cut_row_ptr_data = cut.cut_row_ptr.device_data();
//                    auto iid_data = columns.csc_row_idx.device_data();
//                    auto gh_data = stats.gh_pair.device_data();
//                    auto bin_id_data = bin_id[0]->device_data();
//                    device_loop_2d(n_column, columns.csc_col_ptr.device_data(), [=]__device__(int fid, int i) {
//                        int iid = iid_data[i];
//                        int nid0 = nid_data[iid] - nid_offset;
//                        if (nid0 < 0) return;
//                        int hist_offset = nid0 * n_bins;
//                        int feature_offset = cut_row_ptr_data[fid];
//                        int bin_id = bin_id_data[i];
//                        GHPair &dest = hist_data[hist_offset + feature_offset + bin_id];
//                        const GHPair &src = gh_data[iid];
//                        //TODO use shared memory
//                        atomicAdd(&dest.g, src.g);
//                        atomicAdd(&dest.h, src.h);
//                    }, n_block);
                }
                {
                    TIMED_SCOPE(timerObj, "hist3");
                    if (n_nodes_in_level == 1) {
                        //root
                        auto hist_data = hist.device_data();
                        auto cut_row_ptr_data = cut.cut_row_ptr.device_data();
                        auto gh_data = stats.gh_pair.device_data();
                        auto dense_bin_id_data = dense_bin_id.device_data();
                        auto max_num_bin = this->max_num_bin;
                        auto n_instances = stats.n_instances;
//                        {
//                            device_loop(stats.n_instances * n_column, [=]__device__(int i) {
//                                int iid = i / n_column;
//                                int fid = i % n_column;
//                                unsigned char bid = dense_bin_id_data[iid * n_column + fid];
//                                if (bid != max_num_bin) {
//                                    int feature_offset = cut_row_ptr_data[fid];
//                                    const GHPair src = gh_data[iid];
//                                    GHPair &dest = hist_data[feature_offset + bid];
//                                    //TODO use shared memory
//                                    atomicAdd(&dest.g, src.g);
//                                    atomicAdd(&dest.h, src.h);
//                                }
//                            });
//                        }
                        {
                            const size_t smem_size = n_bins * sizeof(GHPair);
//                            LOG(INFO)<<"smem size = " << smem_size / 1024.0;
                            anonymous_kernel([=]__device__() {
                                extern __shared__ GHPair local_hist[];
                                for (int i = threadIdx.x; i < n_bins; i += blockDim.x) {
                                    local_hist[i] = 0;
                                }
                                __syncthreads();
                                for (int i = blockIdx.x * blockDim.x + threadIdx.x;
                                     i < n_instances * n_column; i += blockDim.x * gridDim.x) {
                                    int iid = i / n_column;
                                    int fid = i % n_column;
                                    unsigned char bid = dense_bin_id_data[iid * n_column + fid];
                                    if (bid != max_num_bin) {
                                        int feature_offset = cut_row_ptr_data[fid];
                                        const GHPair src = gh_data[iid];
                                        GHPair &dest = local_hist[feature_offset + bid];
                                        atomicAdd(&dest.g, src.g);
                                        atomicAdd(&dest.h, src.h);
                                    }
                                }
                                __syncthreads();
                                for (int i = threadIdx.x; i < n_bins; i += blockDim.x) {
                                    GHPair &dest = hist_data[i];
                                    GHPair src = local_hist[i];
                                    atomicAdd(&dest.g, src.g);
                                    atomicAdd(&dest.h, src.h);
                                }
                            }, smem_size);
                        }
                    } else {
                        //otherwise
                        SyncArray<int> node_idx(stats.n_instances);
                        SyncArray<int> node_ptr(n_nodes_in_level + 1);
                        {
                            TIMED_SCOPE(timerObj, "gather node idx");
                            SyncArray<unsigned char> nid4sort(stats.n_instances);
                            nid4sort.copy_from(stats.nid);
                            sequence(cuda::par, node_idx.device_data(), node_idx.device_end(), 0);
                            cub_sort_by_key(nid4sort, node_idx);
                            auto counting_iter = make_counting_iterator < int > (nid_offset);
                            node_ptr.host_data()[0] =
                                    lower_bound(cuda::par, nid4sort.device_data(), nid4sort.device_end(), nid_offset) -
                                    nid4sort.device_data();
                            upper_bound(cuda::par, nid4sort.device_data(), nid4sort.device_end(), counting_iter,
                                        counting_iter + n_nodes_in_level, node_ptr.device_data() + 1);
                        }
                        for (int i = 0; i < n_nodes_in_level / 2; ++i) {
                            int nid0_to_compute = i * 2;
                            int nid0_to_substract = i * 2 + 1;
                            auto node_ptr_data = node_ptr.host_data();
                            int n_ins_left = node_ptr_data[nid0_to_compute + 1] - node_ptr_data[nid0_to_compute];
                            int n_ins_right = node_ptr_data[nid0_to_substract + 1] - node_ptr_data[nid0_to_substract];
                            if (max(n_ins_left, n_ins_right) == 0) continue;
                            if (n_ins_left > n_ins_right)
                                swap(nid0_to_compute, nid0_to_substract);

                            //compute
                            {
                                int nid0 = nid0_to_compute;
                                auto idx_begin = node_ptr.host_data()[nid0];
                                auto idx_end = node_ptr.host_data()[nid0 + 1];
                                auto node_idx_data = node_idx.device_data();
                                auto hist_data = hist.device_data() + nid0 * n_bins;
                                auto cut_row_ptr_data = cut.cut_row_ptr.device_data();
                                auto gh_data = stats.gh_pair.device_data();
                                auto dense_bin_id_data = dense_bin_id.device_data();
                                auto max_num_bin = this->max_num_bin;

                                {
//                                device_loop((idx_end - idx_begin) * n_column, [=]__device__(int i) {
//                                    int iid = node_idx_data[i / n_column + idx_begin];
//                                    int fid = i % n_column;
//                                    unsigned char bid = dense_bin_id_data[iid * n_column + fid];
//                                    if (bid != max_num_bin) {
//                                        int feature_offset = cut_row_ptr_data[fid];
//                                        const GHPair src = gh_data[iid];
//                                        GHPair &dest = hist_data[feature_offset + bid];
//                                        //TODO use shared memory
//                                        atomicAdd(&dest.g, src.g);
//                                        atomicAdd(&dest.h, src.h);
//                                    }
//                                });
                                }
                                {
                                    const size_t smem_size = n_bins * sizeof(GHPair);
                                    anonymous_kernel([=]__device__() {
                                        extern __shared__ GHPair local_hist[];
                                        for (int i = threadIdx.x; i < n_bins; i += blockDim.x) {
                                            local_hist[i] = 0;
                                        }
                                        __syncthreads();

                                        for (int i = blockIdx.x * blockDim.x + threadIdx.x;
                                             i < (idx_end - idx_begin) * n_column; i += blockDim.x * gridDim.x) {
                                            int iid = node_idx_data[i / n_column + idx_begin];
                                            int fid = i % n_column;
                                            unsigned char bid = dense_bin_id_data[iid * n_column + fid];
                                            if (bid != max_num_bin) {
                                                int feature_offset = cut_row_ptr_data[fid];
                                                const GHPair src = gh_data[iid];
                                                GHPair &dest = local_hist[feature_offset + bid];
                                                atomicAdd(&dest.g, src.g);
                                                atomicAdd(&dest.h, src.h);
                                            }
                                        }
                                        __syncthreads();
                                        for (int i = threadIdx.x; i < n_bins; i += blockDim.x) {
                                            GHPair &dest = hist_data[i];
                                            GHPair src = local_hist[i];
                                            atomicAdd(&dest.g, src.g);
                                            atomicAdd(&dest.h, src.h);
                                        }
                                    }, smem_size);
                                }
                            }

                            //substract
                            {
                                auto hist_data_computed = hist.device_data() + nid0_to_compute * n_bins;
                                auto hist_data_to_compute = hist.device_data() + nid0_to_substract * n_bins;
                                auto father_hist_data = last_hist.device_data() + (nid0_to_substract / 2) * n_bins;
                                device_loop(n_bins, [=]__device__(int i) {
                                    hist_data_to_compute[i] = father_hist_data[i] - hist_data_computed[i];
                                });
                            }
//                            PERFORMANCE_CHECKPOINT(timerObj);
                        }
                    }
                    last_hist.copy_from(hist);
                }
                {
//                    SyncArray<GHPair> hist(n_max_splits);
//                    TIMED_SCOPE(timerObj, "hist2");
//                    auto nid_data = stats.nid.device_data();
//                    auto hist_data = hist.device_data();
//                    auto cut_row_ptr_data = cut.cut_row_ptr.device_data();
//                    auto gh_data = stats.gh_pair.device_data();
//                    auto dense_bin_id_data = dense_bin_id.device_data();
//                    auto max_num_bin = this->max_num_bin;
//                    device_loop(stats.n_instances * n_column, [=]__device__(int i) {
//                        unsigned char bid = dense_bin_id_data[i];
//                        if (bid != max_num_bin) {
//                            int iid = i / n_column;
//                            int fid = i % n_column;
//                            int nid0 = nid_data[iid] - nid_offset;
//                            if (nid0 < 0) return;
//                            int hist_offset = nid0 * n_bins;
//                            int feature_offset = cut_row_ptr_data[fid];
//                            GHPair &dest = hist_data[hist_offset + feature_offset + bid];
//                            const GHPair &src = gh_data[iid];
//                            //TODO use shared memory
//                            atomicAdd(&dest.g, src.g);
//                            atomicAdd(&dest.h, src.h);
//                        }
//                    });
//                    LOG(INFO)<<hist;
//                    LOG(INFO)<<hist2;
//                    for (int i = 0; i < n_max_splits; ++i) {
//                        GHPair gh1 = hist.host_data()[i];
//                        GHPair gh2 = hist2.host_data()[i];
//                        CHECK_EQ(gh1.g, gh2.g);
//                        CHECK_EQ(gh1.h, gh2.h);
//                    }
                }
//                {
//                    TIMED_SCOPE(timerOBj, "hist");
//                    //for each feature
//                    //construct hist[node][bin]
//                    //multi block, each block has a local histogram
//                    //shared memory size = (4+4)Bytes * #node * #bin
//                    //syncthreads
//                    //sum local histogram in thread0 to global memory
//                    for (int fid = 0; fid < n_column; ++fid) {
//                        auto feature_start = columns.csc_col_ptr.host_data()[fid];
//                        auto feature_len = columns.csc_col_ptr.host_data()[fid + 1] - feature_start;
//                        const int *iid_data = columns.csc_row_idx.device_data() + feature_start;
//                        const int *bin_id_data = bin_id[0]->device_data() + feature_start;
//                        int fea_offset = cut.cut_row_ptr.host_data()[fid];
//                        int n_fea_bin = cut.cut_row_ptr.host_data()[fid + 1] - cut.cut_row_ptr.host_data()[fid];
//                        int shared_mem_size = sizeof(GHPair) * n_nodes_in_level * n_fea_bin;
//                        LOG(DEBUG)<<"smem size = " << shared_mem_size / 1024.0 << "KB";
//                        auto hist_data = hist.device_data();
//                        hist_kernel << < 2 * 56, 256, shared_mem_size >> >
//                                                      (hist_data, fea_offset, bin_id_data, feature_len, n_fea_bin, n_bins, iid_data,
//                                                              stats.gh_pair.device_data(), stats.nid.device_data(), nid_offset, n_nodes_in_level);
//                        CUDA_CHECK(cudaGetLastError());
//                    }
//                }
//                for (int i = 0; i < hist.size(); ++i) {
//                    CHECK_EQ(hist.host_data()[i].g, hist2.host_data()[i].g);
//                    CHECK_EQ(hist.host_data()[i].h, hist2.host_data()[i].h);
//                }
                LOG(DEBUG) << "hist new = " << hist;
                //calculate missing value for each partition
//                int temp = reduce_by_key(cuda::par, hist_fid, hist_fid + n_split, hist.device_data(),
//                                         make_discard_iterator(), missing_gh.device_data()).second -
//                           missing_gh.device_data();
//                LOG(INFO)<<temp;
//                CHECK_EQ(temp, n_partition);
//                LOG(DEBUG) << missing_gh;
                inclusive_scan_by_key(cuda::par, hist_fid, hist_fid + n_split,
                                      hist.device_data(), hist.device_data());
                LOG(DEBUG) << hist;

                auto nodes_data = tree.nodes.device_data();
                auto missing_gh_data = missing_gh.device_data();
                auto cut_row_ptr = cut.cut_row_ptr.device_data();
                auto hist_data = hist.device_data();
                device_loop(n_partition, [=]__device__(int pid) {
                    int nid0 = pid / n_column;
                    int nid = nid0 + nid_offset;
                    if (!nodes_data[nid].splittable()) return;
                    int fid = pid % n_column;
                    GHPair node_gh = hist_data[nid0 * n_bins + cut_row_ptr[fid + 1] - 1];
                    missing_gh_data[pid] = nodes_data[nid].sum_gh_pair - node_gh;
                });
                LOG(DEBUG) << missing_gh;
//                auto missing_data = missing_gh.host_data();
//                LOG(INFO)<<cut.cut_row_ptr;
//                if (tree.nodes.host_data()[32].is_valid == 1) {
//                    for (int j = 0; j < n_partition; ++j) {
//                        if (missing_data[j].h < 0) {
//                            LOG(INFO) << string_format("%d, %f, nid = %d, fid = %d", j, missing_data[j].h,
//                                                       j / n_column + nid_offset, j % n_column);
//                            LOG(INFO) << hist.host_data()[n_bins + 253];
//                            LOG(INFO)<<tree.nodes.host_data()[15];
//                        }
//                    }
//                    for (int i = 0; i < n_bins; ++i) {
//                        LOG(INFO)<<i <<" " << hist.host_data()[1 * n_bins + i];
//                    }
//                    exit(0);
//                };
            }
        }
        //calculate gain of each split
        SyncArray<float_type> gain(n_max_splits);
        {
            TIMED_SCOPE(timerObj, "calculate gain");
            auto compute_gain = []__device__(GHPair father, GHPair lch, GHPair rch, float_type min_child_weight,
                                             float_type lambda) -> float_type {
                if (lch.h >= min_child_weight && rch.h >= min_child_weight)
                    return (lch.g * lch.g) / (lch.h + lambda) + (rch.g * rch.g) / (rch.h + lambda) -
                           (father.g * father.g) / (father.h + lambda);
                else
                    return 0;
//float_type father_gain = (father.g * father.g) / (father.h + lambda);
            };

            const Tree::TreeNode *nodes_data = tree.nodes.device_data();
            GHPair *gh_prefix_sum_data = hist.device_data();
            float_type *gain_data = gain.device_data();
            const auto missing_gh_data = missing_gh.device_data();
            //for lambda expression
            float_type mcw = min_child_weight;
            float_type l = lambda;
            device_loop(n_split, [=]__device__(int i) {
                int nid0 = i / n_bins;
                int nid = nid0 + nid_offset;
                if (nodes_data[nid].is_valid) {
                    int pid = nid0 * n_column + hist_fid[i];
                    GHPair father_gh = nodes_data[nid].sum_gh_pair;
                    GHPair p_missing_gh = missing_gh_data[pid];
                    GHPair rch_gh = gh_prefix_sum_data[i];
                    float_type default_to_left_gain = max(0.,
                                                          compute_gain(father_gh, father_gh - rch_gh, rch_gh, mcw, l));
                    rch_gh = rch_gh + p_missing_gh;
                    float_type default_to_right_gain = max(0.,
                                                           compute_gain(father_gh, father_gh - rch_gh, rch_gh, mcw, l));
                    if (default_to_left_gain > default_to_right_gain)
                        gain_data[i] = default_to_left_gain;
                    else
                        gain_data[i] = -default_to_right_gain;//negative means default split to right

                } else gain_data[i] = 0;
            });
            LOG(DEBUG) << "gain = " << gain;
        }

        SyncArray<int_float> best_idx_gain(n_nodes_in_level);
        {
            TIMED_SCOPE(timerObj, "get best gain");
            auto arg_abs_max = []__device__(const int_float &a, const int_float &b) {
                if (fabsf(get<1>(a)) == fabsf(get<1>(b)))
                    return get<0>(a) < get<0>(b) ? a : b;
                else
                    return fabsf(get<1>(a)) > fabsf(get<1>(b)) ? a : b;
            };

            auto nid_iterator = make_transform_iterator(counting_iterator<int>(0), placeholders::_1 / n_bins);

            reduce_by_key(
                    cuda::par,
                    nid_iterator, nid_iterator + n_split,
                    make_zip_iterator(make_tuple(counting_iterator<int>(0), gain.device_data())),
                    make_discard_iterator(),
                    best_idx_gain.device_data(),
                    thrust::equal_to<int>(),
                    arg_abs_max
            );
            LOG(DEBUG) << n_split;
            LOG(DEBUG) << "best idx & gain = " << best_idx_gain;
        }

        //get split points
        {
            const int_float *best_idx_gain_data = best_idx_gain.device_data();
            auto hist_data = hist.device_data();
            const auto missing_gh_data = missing_gh.device_data();
            auto cut_val_data = cut.cut_points_val.device_data();

            sp.resize(n_nodes_in_level);
            auto sp_data = sp.device_data();
            auto nodes_data = tree.nodes.device_data();

            int column_offset = columns.column_offset;

            auto cut_row_ptr_data = cut.cut_row_ptr.device_data();
            device_loop(n_nodes_in_level, [=]__device__(int i) {
                int_float bst = best_idx_gain_data[i];
                float_type best_split_gain = get<1>(bst);
                int split_index = get<0>(bst);
                if (!nodes_data[i + nid_offset].is_valid) {
                    sp_data[i].split_fea_id = -1;
                    sp_data[i].nid = -1;
                    return;
                }
                int fid = hist_fid[split_index];
                sp_data[i].split_fea_id = fid + column_offset;
                sp_data[i].nid = i + nid_offset;
                sp_data[i].gain = fabsf(best_split_gain);
                sp_data[i].fval = cut_val_data[split_index % n_bins];
                sp_data[i].split_bid = (unsigned char) (split_index % n_bins - cut_row_ptr_data[fid]);
                sp_data[i].fea_missing_gh = missing_gh_data[i * n_column + hist_fid[split_index]];
                sp_data[i].default_right = best_split_gain < 0;
                sp_data[i].rch_sum_gh = hist_data[split_index];
            });
        }
    }

    LOG(DEBUG) << "split points (gain/fea_id/nid): " << sp;
}

void HistUpdater::grow(Tree &tree, const vector<std::shared_ptr<SparseColumns>> &v_columns, InsStat &stats) {
    TIMED_SCOPE(timerObj, "grow tree");

    int n_instances = stats.n_instances;
    int cur_device = 0;

    LOG(TRACE) << "broadcast tree and stats";
    v_stats.resize(n_devices);
    v_trees.resize(n_devices);
    init_tree(tree, stats);
    DO_ON_MULTI_DEVICES(n_devices, [&](int device_id) {
        //copy stats and tree from host (stats, tree) to multi-device (v_stats, v_trees)

        //stats
        int n_instances = stats.n_instances;
        v_stats[device_id].reset(new InsStat());
        InsStat &gpu_stats = *v_stats[device_id];
        gpu_stats.resize(n_instances);
        gpu_stats.gh_pair.copy_from(stats.gh_pair.host_data(), n_instances);
        gpu_stats.nid.copy_from(stats.nid.host_data(), n_instances);
        //        gpu_stats.y.copy_from(stats.y.host_data(), n_instances);
//        gpu_stats.y_predict.copy_from(stats.y_predict.host_data(), n_instances);

        //tree
        v_trees[device_id].reset(new Tree());
        Tree &gpu_tree = *v_trees[device_id];
        gpu_tree.nodes.resize(tree.nodes.size());
        gpu_tree.nodes.copy_from(tree.nodes.host_data(), tree.nodes.size());
    });

    last_hist.resize((2 << depth) * v_cut[0].cut_points.size());
    for (int i = 0; i < depth; ++i) {
        LOG(TRACE) << "growing tree at depth " << i;
        vector<SyncArray<SplitPoint>> local_sp(n_devices);
        {
            TIMED_SCOPE(timerObj, "find split");
            DO_ON_MULTI_DEVICES(n_devices, [&](int device_id) {
                LOG(TRACE) << string_format("finding split on device %d", device_id);
                find_split(i, *v_columns[device_id], *v_trees[device_id], *v_stats[device_id], v_cut[device_id],
                           local_sp[device_id]);
            });
        }

        int n_max_nodes_in_level = 1 << i;//2^i
        int nid_offset = (1 << i) - 1;//2^i - 1
        SyncArray<SplitPoint> global_sp(n_max_nodes_in_level);
        {
            TIMED_SCOPE(timerObj, "split point all reduce");
            if (n_devices > 1)
                split_point_all_reduce(local_sp, global_sp, i);
            else
                global_sp.copy_from(local_sp[0].device_data(), local_sp[0].size());
//            if (n_executor > 1) {
//                if (rank == 0) {
//                    SyncArray<SplitPoint> global_sp2(n_max_nodes_in_level);
//                    MPI_Recv(global_sp2.host_data(), global_sp2.mem_size(), MPI_CHAR, 1, 0, MPI_COMM_WORLD,
//                             MPI_STATUS_IGNORE);
//                    auto global_sp_data = global_sp.host_data();
//                    auto global_sp2_data = global_sp2.host_data();
//                    for (int j = 0; j < global_sp.size(); ++j) {
//                        if (global_sp2_data[j].gain > global_sp_data[j].gain)
//                            global_sp_data[j] = global_sp2_data[j];
//                    }
//                } else if (rank == 1) {
//                    MPI_Send(global_sp.host_data(), global_sp.mem_size(), MPI_CHAR, 0, 0, MPI_COMM_WORLD);
//                }
//                if (rank == 0) {
//                    MPI_Send(global_sp.host_data(), global_sp.mem_size(), MPI_CHAR, 1, 0, MPI_COMM_WORLD);
//                } else {
//                    MPI_Recv(global_sp.host_data(), global_sp.mem_size(), MPI_CHAR, 0, 0, MPI_COMM_WORLD,
//                             MPI_STATUS_IGNORE);
//                }
//            }
        }
//        LOG(DEBUG) << "rank " << rank << " sp" << global_sp;

        //do split
        {
            TIMED_SCOPE(timerObj, "update tree");
            update_tree(*v_trees[0], global_sp);
        }

        //broadcast tree
        if (n_devices > 1) {
            LOG(TRACE) << "broadcasting updated tree";
            //copy tree on gpu 0 to host, prepare to broadcast
            v_trees[0]->nodes.to_host();
            DO_ON_MULTI_DEVICES(n_devices, [&](int device_id) {
                v_trees[device_id]->nodes.copy_from(v_trees[0]->nodes.host_data(), v_trees[0]->nodes.size());
            });
        }

        {
            vector<bool> v_has_split(n_devices);
            LOG(TRACE) << "reset ins2node id";
            DO_ON_MULTI_DEVICES(n_devices, [&](int device_id) {
                v_has_split[device_id] = reset_ins2node_id(*v_stats[device_id], *v_trees[device_id],
                                                           *v_columns[device_id]);
            });

            LOG(TRACE) << "gathering ins2node id";
            //get final result of the reset instance id to node id
//            if (n_executor == 1) {
            bool has_split = false;
            for (int d = 0; d < n_devices; d++) {
                has_split |= v_has_split[d];
            }
            if (!has_split) {
                LOG(INFO) << "no splittable nodes, stop";
                break;
            }
//            } else {
//                todo early stop
//            }
        }

        //get global ins2node id
        {
            TIMED_SCOPE(timerObj, "global ins2node id");
            SyncArray<int> local_ins2node_id(n_instances);
            auto local_ins2node_id_data = local_ins2node_id.device_data();
            auto global_ins2node_id_data = v_stats[0]->nid.device_data();
            for (int d = 1; d < n_devices; d++) {
                CUDA_CHECK(cudaMemcpyPeerAsync(local_ins2node_id_data, cur_device,
                                               v_stats[d]->nid.device_data(), d,
                                               sizeof(int) * n_instances));
                cudaDeviceSynchronize();
                device_loop(n_instances, [=]__device__(int i) {
                    global_ins2node_id_data[i] = (global_ins2node_id_data[i] > local_ins2node_id_data[i]) ?
                                                 global_ins2node_id_data[i] : local_ins2node_id_data[i];
                });
            }
//            if (n_executor > 1) {
//                if (rank == 0) {
//                    MPI_Recv(local_ins2node_id.host_data(), local_ins2node_id.mem_size(), MPI_CHAR, 1, 0,
//                             MPI_COMM_WORLD,
//                             MPI_STATUS_IGNORE);
//                    auto local_ins2node_id_data = local_ins2node_id.device_data();
//                    auto global_ins2node_id_data = stats.nid.device_data();
//                    device_loop(n_instances, [=]__device__(int i) {
//                        global_ins2node_id_data[i] = (global_ins2node_id_data[i] > local_ins2node_id_data[i]) ?
//                                                     global_ins2node_id_data[i] : local_ins2node_id_data[i];
//                    });
//                } else {
//                    MPI_Send(stats.nid.host_data(), stats.nid.mem_size(), MPI_CHAR, 0, 0, MPI_COMM_WORLD);
//                }
//                if (rank == 0) {
//                    MPI_Send(stats.nid.host_data(), stats.nid.mem_size(), MPI_CHAR, 1, 0, MPI_COMM_WORLD);
//                } else {
//                    MPI_Recv(stats.nid.host_data(), stats.nid.mem_size(), MPI_CHAR, 0, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
//                }
//            }
        }
        //processing missing value
        {
//            TIMED_SCOPE(timerObj, "process missing value");
//            LOG(TRACE) << "update ins2node id for each missing fval";
//            auto global_ins2node_id_data = v_stats[0]->nid.device_data();//essential
//            auto nodes_data = v_trees[0]->nodes.device_data();//already broadcast above
//            device_loop(n_instances, [=]__device__(int iid) {
//                int nid = global_ins2node_id_data[iid];
//                //if the instance is not on leaf node and not goes down
//                if (nodes_data[nid].splittable() && nid < nid_offset + n_max_nodes_in_level) {
//                    //let the instance goes down
//                    const Tree::TreeNode &node = nodes_data[nid];
//                    if (node.default_right)
//                        global_ins2node_id_data[iid] = node.rch_index;
//                    else
//                        global_ins2node_id_data[iid] = node.lch_index;
//                }
//            });
//            LOG(DEBUG) << "new nid = " << stats.nid;
//            for (int i = 0; i < stats.n_instances; ++i) {
//                printf("%d,",stats.nid.host_data()[i]);
//            }
            //broadcast ins2node id
            v_stats[0]->nid.to_host();
            DO_ON_MULTI_DEVICES(n_devices, [&](int device_id) {
//                v_stats[device_id]->nid.copy_from(stats.nid.host_data(), stats.nid.size());
                v_stats[device_id]->nid.copy_from(v_stats[0]->nid.host_data(), stats.nid.size());
            });
        }
    }
    tree.nodes.copy_from(v_trees[0]->nodes);
    stats.nid.copy_from(v_stats[0]->nid);
}

void HistUpdater::init_dense_data(const SparseColumns &columns, int n_instances) {
    LOG(TRACE) << "init dense data";
    int n_column = columns.n_column;
    int nnz = columns.nnz;
    int n_block = std::min((nnz / n_column - 1) / 256 + 1, 32 * 56);
    dense_bin_id.resize(n_instances * n_column);
    auto bin_id_data = bin_id[0]->device_data();
    auto csc_row_idx_data = columns.csc_row_idx.device_data();
    auto dense_bin_id_data = dense_bin_id.device_data();
    auto max_num_bin = this->max_num_bin;
    device_loop(n_instances * n_column, [=]__device__(int i) {
        dense_bin_id_data[i] = max_num_bin;
    });
    device_loop_2d(n_column, columns.csc_col_ptr.device_data(), [=]__device__(int fid, int i) {
        int row = csc_row_idx_data[i];
        unsigned char bid = bin_id_data[i];
        dense_bin_id_data[row * n_column + fid] = bid;
    }, n_block);
}

bool HistUpdater::reset_ins2node_id(InsStat &stats, const Tree &tree, const SparseColumns &columns) {
    SyncArray<bool> has_splittable(1);
    //set new node id for each instance
    {
        TIMED_SCOPE(timerObj, "get new node id");
        auto nid_data = stats.nid.device_data();
        const int *iid_data = columns.csc_row_idx.device_data();
        const Tree::TreeNode *nodes_data = tree.nodes.device_data();
        const int *col_ptr_data = columns.csc_col_ptr.device_data();
        const float_type *f_val_data = columns.csc_val.device_data();
        has_splittable.host_data()[0] = false;
        bool *h_s_data = has_splittable.device_data();
        int column_offset = columns.column_offset;

        int n_column = columns.n_column;
        int nnz = columns.nnz;
        int n_block = std::min((nnz / n_column - 1) / 256 + 1, 32 * 56);
        auto dense_bin_id_data = dense_bin_id.device_data();
        int max_num_bin = this->max_num_bin;
        device_loop(stats.n_instances, [=]__device__(int iid) {
            int nid = nid_data[iid];
            const Tree::TreeNode &node = nodes_data[nid];
            if (node.splittable()) {
                h_s_data[0] = true;
                int split_fid = node.split_feature_id;
                unsigned char split_bid = node.split_bid;
                unsigned char bid = dense_bin_id_data[iid * n_column + split_fid];
                bool to_left = true;
                if ((bid == max_num_bin && node.default_right) || (bid <= split_bid))
                    to_left = false;
                if (to_left) {
                    //goes to left child
                    nid_data[iid] = node.lch_index;
                } else {
                    //right child
                    nid_data[iid] = node.rch_index;
                }
            }
        });
//        LOG(TRACE) << "update ins2node id for each fval";
//        device_loop_2d(n_column, col_ptr_data,
//                       [=]__device__(int col_id, int fvid) {
//                           //feature value id -> instance id
//                           int iid = iid_data[fvid];
//                           //instance id -> node id
//                           int nid = nid_data[iid];
//                           //node id -> node
//                           const Tree::TreeNode &node = nodes_data[nid];
//                           //if the node splits on this feature
//                           if (node.splittable() && node.split_feature_id == col_id + column_offset) {
//                               h_s_data[0] = true;
//                               if (f_val_data[fvid] < node.split_value)
//                                   //goes to left child
//                                   nid_data[iid] = node.lch_index;
//                               else
//                                   //right child
//                                   nid_data[iid] = node.rch_index;
//                           }
//                       }, n_block);
//
    }
    LOG(DEBUG) << "new tree_id = " << stats.nid;
//    for (int i = 0; i < stats.n_instances; ++i) {
//        printf("%d,", stats.nid.host_data()[i]);
//    }
//    printf("\n");
//        LOG(DEBUG) << v_trees[cur_device_id].nodes;
    return has_splittable.host_data()[0];
}