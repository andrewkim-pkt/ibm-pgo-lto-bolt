#!/bin/bash
# The single definition of the TPC-H work point, sourced by train/bench/bolt so that
# training, profiling and measurement all drive the binary identically.
#
# Work point from Velox's own tuning doc (velox/docs/develop/TpchBenchmark.rst):
#   num_drivers    = max(20, vCPU * 3/4)   -> 144 of 192
#   num_io_threads = max(16, vCPU * 3/8)   ->  72
#   cache_gb       = ~50% of system RAM    -> 360 of 755 GiB
# The dataset is 39.5 GiB, so after the first pass it is fully resident in the Velox
# cache and the measurement is CPU-bound rather than I/O-bound -- which is the regime
# where the DB campaigns found FDO gains appear at all.
velox_workload_args() {
  echo "-data_path $DATA \
 -data_format parquet \
 -num_drivers ${WL_DRIVERS:-144} \
 -num_io_threads ${WL_IO_THREADS:-72} \
 -cache_gb ${WL_CACHE_GB:-360} \
 -num_splits_per_file ${WL_SPLITS:-10} \
 -num_repeats ${WL_REPEATS:-1} \
 -run_query_verbose -1"
}
