# =============================================================================
# Copyright (c) 2018-2023, NVIDIA CORPORATION.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except
# in compliance with the License. You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software distributed under the License
# is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
# or implied. See the License for the specific language governing permissions and limitations under
# the License.
# =============================================================================

cmake_minimum_required(VERSION 3.26.4 FATAL_ERROR)

include(../fetch_rapids.cmake)
include(rapids-cmake)
include(rapids-cpm)
include(rapids-cuda)
include(rapids-export)
include(rapids-find)

rapids_cuda_init_architectures(CUDF)

project(
  CUDF
  VERSION 23.08.00
  LANGUAGES C CXX CUDA
)
if(CMAKE_CUDA_COMPILER_ID STREQUAL "NVIDIA" AND CMAKE_CUDA_COMPILER_VERSION VERSION_LESS 11.5)
  message(
    FATAL_ERROR
      "libcudf requires CUDA Toolkit 11.5+ to compile (nvcc ${CMAKE_CUDA_COMPILER_VERSION} provided)"
  )
endif()

# Needed because GoogleBenchmark changes the state of FindThreads.cmake, causing subsequent runs to
# have different values for the `Threads::Threads` target. Setting this flag ensures
# `Threads::Threads` is the same value in first run and subsequent runs.
set(THREADS_PREFER_PTHREAD_FLAG ON)

# ##################################################################################################
# * build options ---------------------------------------------------------------------------------

option(USE_NVTX "Build with NVTX support" ON)
option(BUILD_TESTS "Configure CMake to build tests" ON)
option(BUILD_BENCHMARKS "Configure CMake to build (google & nvbench) benchmarks" OFF)
option(BUILD_SHARED_LIBS "Build cuDF shared libraries" ON)
option(JITIFY_USE_CACHE "Use a file cache for JIT compiled kernels" ON)
option(CUDF_BUILD_TESTUTIL "Whether to build the test utilities contained in libcudf" ON)
mark_as_advanced(CUDF_BUILD_TESTUTIL)
option(CUDF_USE_PROPRIETARY_NVCOMP "Download and use NVCOMP with proprietary extensions" ON)
option(CUDF_USE_ARROW_STATIC "Build and statically link Arrow libraries" OFF)
option(CUDF_ENABLE_ARROW_ORC "Build the Arrow ORC adapter" OFF)
option(CUDF_ENABLE_ARROW_PYTHON "Find (or build) Arrow with Python support" OFF)
option(CUDF_ENABLE_ARROW_PARQUET "Find (or build) Arrow with Parquet support" OFF)
option(CUDF_ENABLE_ARROW_S3 "Build/Enable AWS S3 Arrow filesystem support" OFF)
option(
  CUDF_USE_PER_THREAD_DEFAULT_STREAM
  "Build cuDF with per-thread default stream, including passing the per-thread default
         stream to external libraries."
  OFF
)
# Option to add all symbols to the dynamic symbol table in the library file, allowing to retrieve
# human-readable stacktrace for debugging.
option(
  CUDF_BUILD_STACKTRACE_DEBUG
  "Replace the current optimization flags by the options '-rdynamic -Og -NDEBUG', useful for debugging with stacktrace retrieval"
  OFF
)
option(DISABLE_DEPRECATION_WARNINGS "Disable warnings generated from deprecated declarations." OFF)
# Option to enable line info in CUDA device compilation to allow introspection when profiling /
# memchecking
option(CUDA_ENABLE_LINEINFO
       "Enable the -lineinfo option for nvcc (useful for cuda-memcheck / profiler)" OFF
)
option(CUDA_WARNINGS_AS_ERRORS "Enable -Werror=all-warnings for all CUDA compilation" ON)
# cudart can be statically linked or dynamically linked. The python ecosystem wants dynamic linking
option(CUDA_STATIC_RUNTIME "Statically link the CUDA runtime" OFF)

set(DEFAULT_CUDF_BUILD_STREAMS_TEST_UTIL ON)
if(CUDA_STATIC_RUNTIME OR NOT BUILD_SHARED_LIBS)
  set(DEFAULT_CUDF_BUILD_STREAMS_TEST_UTIL OFF)
endif()
option(
  CUDF_BUILD_STREAMS_TEST_UTIL
  "Whether to build the utilities for stream testing contained in libcudf"
  ${DEFAULT_CUDF_BUILD_STREAMS_TEST_UTIL}
)
mark_as_advanced(CUDF_BUILD_STREAMS_TEST_UTIL)

option(USE_LIBARROW_FROM_PYARROW "Use the libarrow contained within pyarrow." OFF)
mark_as_advanced(USE_LIBARROW_FROM_PYARROW)

message(VERBOSE "CUDF: Build with NVTX support: ${USE_NVTX}")
message(VERBOSE "CUDF: Configure CMake to build tests: ${BUILD_TESTS}")
message(VERBOSE "CUDF: Configure CMake to build (google & nvbench) benchmarks: ${BUILD_BENCHMARKS}")
message(VERBOSE "CUDF: Build cuDF shared libraries: ${BUILD_SHARED_LIBS}")
message(VERBOSE "CUDF: Use a file cache for JIT compiled kernels: ${JITIFY_USE_CACHE}")
message(VERBOSE "CUDF: Build and statically link Arrow libraries: ${CUDF_USE_ARROW_STATIC}")
message(VERBOSE "CUDF: Build and enable S3 filesystem support for Arrow: ${CUDF_ENABLE_ARROW_S3}")
message(VERBOSE "CUDF: Build with per-thread default stream: ${CUDF_USE_PER_THREAD_DEFAULT_STREAM}")
message(
  VERBOSE
  "CUDF: Replace the current optimization flags by the options '-rdynamic -Og' (useful for debugging with stacktrace retrieval): ${CUDF_BUILD_STACKTRACE_DEBUG}"
)
message(
  VERBOSE
  "CUDF: Disable warnings generated from deprecated declarations: ${DISABLE_DEPRECATION_WARNINGS}"
)
message(
  VERBOSE
  "CUDF: Enable the -lineinfo option for nvcc (useful for cuda-memcheck / profiler): ${CUDA_ENABLE_LINEINFO}"
)
message(VERBOSE "CUDF: Statically link the CUDA runtime: ${CUDA_STATIC_RUNTIME}")

# Set a default build type if none was specified
rapids_cmake_build_type("Release")
set(CUDF_BUILD_TESTS ${BUILD_TESTS})
set(CUDF_BUILD_BENCHMARKS ${BUILD_BENCHMARKS})
if(BUILD_TESTS AND NOT CUDF_BUILD_TESTUTIL)
  message(
    FATAL_ERROR
      "Tests cannot be built without building cudf test utils. Please set CUDF_BUILD_TESTUTIL=ON or BUILD_TESTS=OFF"
  )
endif()

if(CUDF_BUILD_STACKTRACE_DEBUG AND NOT CMAKE_COMPILER_IS_GNUCXX)
  message(FATAL_ERROR "CUDF_BUILD_STACKTRACE_DEBUG is only supported with GCC compiler")
endif()

set(CUDF_CXX_FLAGS "")
set(CUDF_CUDA_FLAGS "")
set(CUDF_CXX_DEFINITIONS "")
set(CUDF_CUDA_DEFINITIONS "")

# Set logging level
set(LIBCUDF_LOGGING_LEVEL
    "INFO"
    CACHE STRING "Choose the logging level."
)
set_property(
  CACHE LIBCUDF_LOGGING_LEVEL PROPERTY STRINGS "TRACE" "DEBUG" "INFO" "WARN" "ERROR" "CRITICAL"
                                       "OFF"
)
message(VERBOSE "CUDF: LIBCUDF_LOGGING_LEVEL = '${LIBCUDF_LOGGING_LEVEL}'.")

if(NOT CUDF_GENERATED_INCLUDE_DIR)
  set(CUDF_GENERATED_INCLUDE_DIR ${CUDF_BINARY_DIR})
endif()

# ##################################################################################################
# * conda environment -----------------------------------------------------------------------------
rapids_cmake_support_conda_env(conda_env MODIFY_PREFIX_PATH)

# ##################################################################################################
# * compiler options ------------------------------------------------------------------------------
rapids_find_package(
  CUDAToolkit REQUIRED
  BUILD_EXPORT_SET cudf-exports
  INSTALL_EXPORT_SET cudf-exports
)
include(cmake/Modules/ConfigureCUDA.cmake) # set other CUDA compilation flags

# ##################################################################################################
# * dependencies ----------------------------------------------------------------------------------

# find zlib
rapids_find_package(ZLIB REQUIRED)

if(CUDF_BUILD_TESTUTIL)
  # find Threads (needed by cudftestutil)
  rapids_find_package(
    Threads REQUIRED
    BUILD_EXPORT_SET cudf-exports
    INSTALL_EXPORT_SET cudf-exports
  )
endif()

# add third party dependencies using CPM
rapids_cpm_init()
# find jitify
include(cmake/thirdparty/get_jitify.cmake)
# find nvCOMP
include(cmake/thirdparty/get_nvcomp.cmake)
# find thrust/cub
include(cmake/thirdparty/get_thrust.cmake)
# find rmm
include(cmake/thirdparty/get_rmm.cmake)
# find arrow
include(cmake/thirdparty/get_arrow.cmake)
# find dlpack
include(cmake/thirdparty/get_dlpack.cmake)
# find libcu++
include(cmake/thirdparty/get_libcudacxx.cmake)
# find cuCollections Should come after including thrust and libcudacxx
include(cmake/thirdparty/get_cucollections.cmake)
# find or install GoogleTest
if(CUDF_BUILD_TESTUTIL)
  include(cmake/thirdparty/get_gtest.cmake)
endif()
# preprocess jitify-able kernels
include(cmake/Modules/JitifyPreprocessKernels.cmake)
# find cuFile
include(cmake/thirdparty/get_cufile.cmake)
# find KvikIO
include(cmake/thirdparty/get_kvikio.cmake)
# find fmt
include(cmake/thirdparty/get_fmt.cmake)
# find spdlog
include(cmake/thirdparty/get_spdlog.cmake)

# Workaround until https://github.com/rapidsai/rapids-cmake/issues/176 is resolved
if(NOT BUILD_SHARED_LIBS)
  include("${rapids-cmake-dir}/export/find_package_file.cmake")
  list(APPEND METADATA_KINDS BUILD INSTALL)
  list(APPEND dependencies KvikIO ZLIB nvcomp)
  if(TARGET cufile::cuFile_interface)
    list(APPEND dependencies cuFile)
  endif()

  foreach(METADATA_KIND IN LISTS METADATA_KINDS)
    foreach(dep IN LISTS dependencies)
      rapids_export_package(${METADATA_KIND} ${dep} cudf-exports)
    endforeach()
  endforeach()

  if(TARGET conda_env)
    install(TARGETS conda_env EXPORT cudf-exports)
  endif()
endif()

# ##################################################################################################
# * library targets -------------------------------------------------------------------------------

add_library(
  cudf
  src/aggregation/aggregation.cpp
  src/aggregation/aggregation.cu
  src/aggregation/result_cache.cpp
  src/ast/expression_parser.cpp
  src/ast/expressions.cpp
  src/binaryop/binaryop.cpp
  src/binaryop/compiled/ATan2.cu
  src/binaryop/compiled/Add.cu
  src/binaryop/compiled/BitwiseAnd.cu
  src/binaryop/compiled/BitwiseOr.cu
  src/binaryop/compiled/BitwiseXor.cu
  src/binaryop/compiled/Div.cu
  src/binaryop/compiled/FloorDiv.cu
  src/binaryop/compiled/Greater.cu
  src/binaryop/compiled/GreaterEqual.cu
  src/binaryop/compiled/IntPow.cu
  src/binaryop/compiled/Less.cu
  src/binaryop/compiled/LessEqual.cu
  src/binaryop/compiled/LogBase.cu
  src/binaryop/compiled/LogicalAnd.cu
  src/binaryop/compiled/LogicalOr.cu
  src/binaryop/compiled/Mod.cu
  src/binaryop/compiled/Mul.cu
  src/binaryop/compiled/NullEquals.cu
  src/binaryop/compiled/NullLogicalAnd.cu
  src/binaryop/compiled/NullLogicalOr.cu
  src/binaryop/compiled/NullMax.cu
  src/binaryop/compiled/NullMin.cu
  src/binaryop/compiled/PMod.cu
  src/binaryop/compiled/Pow.cu
  src/binaryop/compiled/PyMod.cu
  src/binaryop/compiled/ShiftLeft.cu
  src/binaryop/compiled/ShiftRight.cu
  src/binaryop/compiled/ShiftRightUnsigned.cu
  src/binaryop/compiled/Sub.cu
  src/binaryop/compiled/TrueDiv.cu
  src/binaryop/compiled/binary_ops.cu
  src/binaryop/compiled/equality_ops.cu
  src/binaryop/compiled/util.cpp
  src/labeling/label_bins.cu
  src/bitmask/null_mask.cu
  src/bitmask/is_element_valid.cpp
  src/column/column.cu
  src/column/column_device_view.cu
  src/column/column_factories.cpp
  src/column/column_factories.cu
  src/column/column_view.cpp
  src/copying/concatenate.cu
  src/copying/contiguous_split.cu
  src/copying/copy.cpp
  src/copying/copy.cu
  src/copying/copy_range.cu
  src/copying/gather.cu
  src/copying/get_element.cu
  src/copying/pack.cpp
  src/copying/purge_nonempty_nulls.cu
  src/copying/reverse.cu
  src/copying/sample.cu
  src/copying/scatter.cu
  src/copying/shift.cu
  src/copying/slice.cu
  src/copying/split.cpp
  src/copying/segmented_shift.cu
  src/datetime/datetime_ops.cu
  src/dictionary/add_keys.cu
  src/dictionary/decode.cu
  src/dictionary/detail/concatenate.cu
  src/dictionary/detail/merge.cu
  src/dictionary/dictionary_column_view.cpp
  src/dictionary/dictionary_factories.cu
  src/dictionary/encode.cu
  src/dictionary/remove_keys.cu
  src/dictionary/replace.cu
  src/dictionary/search.cu
  src/dictionary/set_keys.cu
  src/filling/calendrical_month_sequence.cu
  src/filling/fill.cu
  src/filling/repeat.cu
  src/filling/sequence.cu
  src/groupby/groupby.cu
  src/groupby/hash/groupby.cu
  src/groupby/sort/aggregate.cpp
  src/groupby/sort/group_argmax.cu
  src/groupby/sort/group_argmin.cu
  src/groupby/sort/group_collect.cu
  src/groupby/sort/group_correlation.cu
  src/groupby/sort/group_count.cu
  src/groupby/sort/group_m2.cu
  src/groupby/sort/group_max.cu
  src/groupby/sort/group_min.cu
  src/groupby/sort/group_merge_lists.cu
  src/groupby/sort/group_merge_m2.cu
  src/groupby/sort/group_nth_element.cu
  src/groupby/sort/group_nunique.cu
  src/groupby/sort/group_product.cu
  src/groupby/sort/group_quantiles.cu
  src/groupby/sort/group_std.cu
  src/groupby/sort/group_sum.cu
  src/groupby/sort/scan.cpp
  src/groupby/sort/group_count_scan.cu
  src/groupby/sort/group_max_scan.cu
  src/groupby/sort/group_min_scan.cu
  src/groupby/sort/group_rank_scan.cu
  src/groupby/sort/group_replace_nulls.cu
  src/groupby/sort/group_sum_scan.cu
  src/groupby/sort/sort_helper.cu
  src/hash/hashing.cu
  src/hash/md5_hash.cu
  src/hash/murmur_hash.cu
  src/hash/spark_murmur_hash.cu
  src/interop/dlpack.cpp
  src/interop/from_arrow.cu
  src/interop/to_arrow.cu
  src/interop/detail/arrow_allocator.cpp
  src/io/avro/avro.cpp
  src/io/avro/avro_gpu.cu
  src/io/avro/reader_impl.cu
  src/io/comp/brotli_dict.cpp
  src/io/comp/cpu_unbz2.cpp
  src/io/comp/debrotli.cu
  src/io/comp/gpuinflate.cu
  src/io/comp/nvcomp_adapter.cpp
  src/io/comp/nvcomp_adapter.cu
  src/io/comp/snap.cu
  src/io/comp/statistics.cu
  src/io/comp/uncomp.cpp
  src/io/comp/unsnap.cu
  src/io/csv/csv_gpu.cu
  src/io/csv/durations.cu
  src/io/csv/reader_impl.cu
  src/io/csv/writer_impl.cu
  src/io/functions.cpp
  src/io/json/json_column.cu
  src/io/json/json_gpu.cu
  src/io/json/json_tree.cu
  src/io/json/nested_json_gpu.cu
  src/io/json/reader_impl.cu
  src/io/json/experimental/byte_range_info.cu
  src/io/json/experimental/read_json.cpp
  src/io/json/write_json.cu
  src/io/orc/aggregate_orc_metadata.cpp
  src/io/orc/dict_enc.cu
  src/io/orc/orc.cpp
  src/io/orc/reader_impl.cu
  src/io/orc/stats_enc.cu
  src/io/orc/stripe_data.cu
  src/io/orc/stripe_enc.cu
  src/io/orc/stripe_init.cu
  src/datetime/timezone.cpp
  src/io/orc/writer_impl.cu
  src/io/parquet/compact_protocol_reader.cpp
  src/io/parquet/compact_protocol_writer.cpp
  src/io/parquet/page_data.cu
  src/io/parquet/chunk_dict.cu
  src/io/parquet/page_enc.cu
  src/io/parquet/page_hdr.cu
  src/io/parquet/reader.cpp
  src/io/parquet/reader_impl.cpp
  src/io/parquet/reader_impl_helpers.cpp
  src/io/parquet/reader_impl_preprocess.cu
  src/io/parquet/writer_impl.cu
  src/io/statistics/orc_column_statistics.cu
  src/io/statistics/parquet_column_statistics.cu
  src/io/text/byte_range_info.cpp
  src/io/text/data_chunk_source_factories.cpp
  src/io/text/bgzip_data_chunk_source.cu
  src/io/text/bgzip_utils.cpp
  src/io/text/multibyte_split.cu
  src/io/utilities/column_buffer.cpp
  src/io/utilities/config_utils.cpp
  src/io/utilities/data_sink.cpp
  src/io/utilities/datasource.cpp
  src/io/utilities/file_io_utilities.cpp
  src/io/utilities/parsing_utils.cu
  src/io/utilities/row_selection.cpp
  src/io/utilities/trie.cu
  src/jit/cache.cpp
  src/jit/parser.cpp
  src/jit/util.cpp
  src/join/conditional_join.cu
  src/join/cross_join.cu
  src/join/hash_join.cu
  src/join/join.cu
  src/join/join_utils.cu
  src/join/mixed_join.cu
  src/join/mixed_join_kernel.cu
  src/join/mixed_join_kernel_nulls.cu
  src/join/mixed_join_kernels_semi.cu
  src/join/mixed_join_semi.cu
  src/join/mixed_join_size_kernel.cu
  src/join/mixed_join_size_kernel_nulls.cu
  src/join/mixed_join_size_kernels_semi.cu
  src/join/semi_join.cu
  src/lists/contains.cu
  src/lists/combine/concatenate_list_elements.cu
  src/lists/combine/concatenate_rows.cu
  src/lists/copying/concatenate.cu
  src/lists/copying/copying.cu
  src/lists/copying/gather.cu
  src/lists/copying/segmented_gather.cu
  src/lists/copying/scatter_helper.cu
  src/lists/count_elements.cu
  src/lists/dremel.cu
  src/lists/explode.cu
  src/lists/extract.cu
  src/lists/interleave_columns.cu
  src/lists/lists_column_factories.cu
  src/lists/lists_column_view.cu
  src/lists/reverse.cu
  src/lists/segmented_sort.cu
  src/lists/sequences.cu
  src/lists/set_operations.cu
  src/lists/stream_compaction/apply_boolean_mask.cu
  src/lists/stream_compaction/distinct.cu
  src/lists/utilities.cu
  src/merge/merge.cu
  src/partitioning/partitioning.cu
  src/partitioning/round_robin.cu
  src/quantiles/tdigest/tdigest.cu
  src/quantiles/tdigest/tdigest_aggregation.cu
  src/quantiles/tdigest/tdigest_column_view.cpp
  src/quantiles/quantile.cu
  src/quantiles/quantiles.cu
  src/reductions/all.cu
  src/reductions/any.cu
  src/reductions/collect_ops.cu
  src/reductions/max.cu
  src/reductions/mean.cu
  src/reductions/min.cu
  src/reductions/minmax.cu
  src/reductions/nth_element.cu
  src/reductions/product.cu
  src/reductions/reductions.cpp
  src/reductions/scan/rank_scan.cu
  src/reductions/scan/scan.cpp
  src/reductions/scan/scan_exclusive.cu
  src/reductions/scan/scan_inclusive.cu
  src/reductions/segmented/all.cu
  src/reductions/segmented/any.cu
  src/reductions/segmented/counts.cu
  src/reductions/segmented/max.cu
  src/reductions/segmented/mean.cu
  src/reductions/segmented/min.cu
  src/reductions/segmented/nunique.cu
  src/reductions/segmented/product.cu
  src/reductions/segmented/reductions.cpp
  src/reductions/segmented/std.cu
  src/reductions/segmented/sum.cu
  src/reductions/segmented/sum_of_squares.cu
  src/reductions/segmented/update_validity.cu
  src/reductions/segmented/var.cu
  src/reductions/std.cu
  src/reductions/sum.cu
  src/reductions/sum_of_squares.cu
  src/reductions/var.cu
  src/replace/clamp.cu
  src/replace/nans.cu
  src/replace/nulls.cu
  src/replace/replace.cu
  src/reshape/byte_cast.cu
  src/reshape/interleave_columns.cu
  src/reshape/tile.cu
  src/rolling/detail/rolling_collect_list.cu
  src/rolling/detail/rolling_fixed_window.cu
  src/rolling/detail/rolling_variable_window.cu
  src/rolling/grouped_rolling.cu
  src/rolling/range_window_bounds.cpp
  src/rolling/rolling.cu
  src/round/round.cu
  src/scalar/scalar.cpp
  src/scalar/scalar_factories.cpp
  src/search/contains_column.cu
  src/search/contains_scalar.cu
  src/search/contains_table.cu
  src/search/search_ordered.cu
  src/sort/is_sorted.cu
  src/sort/rank.cu
  src/sort/segmented_sort.cu
  src/sort/sort_column.cu
  src/sort/sort.cu
  src/sort/stable_segmented_sort.cu
  src/sort/stable_sort_column.cu
  src/sort/stable_sort.cu
  src/stream_compaction/apply_boolean_mask.cu
  src/stream_compaction/distinct.cu
  src/stream_compaction/distinct_count.cu
  src/stream_compaction/distinct_reduce.cu
  src/stream_compaction/drop_nans.cu
  src/stream_compaction/drop_nulls.cu
  src/stream_compaction/stable_distinct.cu
  src/stream_compaction/unique.cu
  src/stream_compaction/unique_count.cu
  src/stream_compaction/unique_count_column.cu
  src/strings/attributes.cu
  src/strings/capitalize.cu
  src/strings/case.cu
  src/strings/char_types/char_cases.cu
  src/strings/char_types/char_types.cu
  src/strings/combine/concatenate.cu
  src/strings/combine/join.cu
  src/strings/combine/join_list_elements.cu
  src/strings/contains.cu
  src/strings/convert/convert_booleans.cu
  src/strings/convert/convert_datetime.cu
  src/strings/convert/convert_durations.cu
  src/strings/convert/convert_fixed_point.cu
  src/strings/convert/convert_floats.cu
  src/strings/convert/convert_hex.cu
  src/strings/convert/convert_integers.cu
  src/strings/convert/convert_ipv4.cu
  src/strings/convert/convert_urls.cu
  src/strings/convert/convert_lists.cu
  src/strings/copying/concatenate.cu
  src/strings/copying/copying.cu
  src/strings/copying/shift.cu
  src/strings/count_matches.cu
  src/strings/extract/extract.cu
  src/strings/extract/extract_all.cu
  src/strings/filling/fill.cu
  src/strings/filter_chars.cu
  src/strings/like.cu
  src/strings/padding.cu
  src/strings/json/json_path.cu
  src/strings/regex/regcomp.cpp
  src/strings/regex/regexec.cpp
  src/strings/regex/regex_program.cpp
  src/strings/repeat_strings.cu
  src/strings/replace/backref_re.cu
  src/strings/replace/multi.cu
  src/strings/replace/multi_re.cu
  src/strings/replace/replace.cu
  src/strings/replace/replace_re.cu
  src/strings/reverse.cu
  src/strings/search/findall.cu
  src/strings/search/find.cu
  src/strings/search/find_multiple.cu
  src/strings/slice.cu
  src/strings/split/partition.cu
  src/strings/split/split.cu
  src/strings/split/split_re.cu
  src/strings/split/split_record.cu
  src/strings/strings_column_factories.cu
  src/strings/strings_column_view.cpp
  src/strings/strings_scalar_factories.cpp
  src/strings/strip.cu
  src/strings/translate.cu
  src/strings/utilities.cu
  src/strings/wrap.cu
  src/structs/copying/concatenate.cu
  src/structs/structs_column_factories.cu
  src/structs/structs_column_view.cpp
  src/structs/utilities.cpp
  src/table/row_operators.cu
  src/table/table.cpp
  src/table/table_device_view.cu
  src/table/table_view.cpp
  src/text/detokenize.cu
  src/text/edit_distance.cu
  src/text/generate_ngrams.cu
  src/text/minhash.cu
  src/text/ngrams_tokenize.cu
  src/text/normalize.cu
  src/text/replace.cu
  src/text/stemmer.cu
  src/text/subword/bpe_tokenizer.cu
  src/text/subword/data_normalizer.cu
  src/text/subword/load_hash_file.cu
  src/text/subword/load_merges_file.cu
  src/text/subword/subword_tokenize.cu
  src/text/subword/wordpiece_tokenizer.cu
  src/text/tokenize.cu
  src/transform/bools_to_mask.cu
  src/transform/compute_column.cu
  src/transform/encode.cu
  src/transform/mask_to_bools.cu
  src/transform/nans_to_nulls.cu
  src/transform/one_hot_encode.cu
  src/transform/row_bit_count.cu
  src/transform/transform.cpp
  src/transpose/transpose.cu
  src/unary/cast_ops.cu
  src/unary/math_ops.cu
  src/unary/nan_ops.cu
  src/unary/null_ops.cu
  src/utilities/default_stream.cpp
  src/utilities/linked_column.cpp
  src/utilities/logger.cpp
  src/utilities/stacktrace.cpp
  src/utilities/traits.cpp
  src/utilities/type_checks.cpp
  src/utilities/type_dispatcher.cpp
)

# Anything that includes jitify needs to be compiled with _FILE_OFFSET_BITS=64 due to a limitation
# in how conda builds glibc
set_source_files_properties(
  src/binaryop/binaryop.cpp
  src/jit/cache.cpp
  src/rolling/detail/rolling_fixed_window.cu
  src/rolling/detail/rolling_variable_window.cu
  src/rolling/grouped_rolling.cu
  src/rolling/rolling.cu
  src/transform/transform.cpp
  PROPERTIES COMPILE_DEFINITIONS "_FILE_OFFSET_BITS=64"
)

set_target_properties(
  cudf
  PROPERTIES BUILD_RPATH "\$ORIGIN"
             INSTALL_RPATH "\$ORIGIN"
             # set target compile options
             CXX_STANDARD 17
             CXX_STANDARD_REQUIRED ON
             # For std:: support of __int128_t. Can be removed once using cuda::std
             CXX_EXTENSIONS ON
             CUDA_STANDARD 17
             CUDA_STANDARD_REQUIRED ON
             POSITION_INDEPENDENT_CODE ON
             INTERFACE_POSITION_INDEPENDENT_CODE ON
)

target_compile_options(
  cudf PRIVATE "$<$<COMPILE_LANGUAGE:CXX>:${CUDF_CXX_FLAGS}>"
               "$<$<COMPILE_LANGUAGE:CUDA>:${CUDF_CUDA_FLAGS}>"
)

if(CUDF_BUILD_STACKTRACE_DEBUG)
  # Remove any optimization level to avoid nvcc warning "incompatible redefinition for option
  # 'optimize'".
  string(REGEX REPLACE "(\-O[0123])" "" CMAKE_CUDA_FLAGS "${CMAKE_CUDA_FLAGS}")
  string(REGEX REPLACE "(\-O[0123])" "" CMAKE_CUDA_FLAGS_RELEASE "${CMAKE_CUDA_FLAGS_RELEASE}")
  string(REGEX REPLACE "(\-O[0123])" "" CMAKE_CUDA_FLAGS_MINSIZEREL
                       "${CMAKE_CUDA_FLAGS_MINSIZEREL}"
  )
  string(REGEX REPLACE "(\-O[0123])" "" CMAKE_CUDA_FLAGS_RELWITHDEBINFO
                       "${CMAKE_CUDA_FLAGS_RELWITHDEBINFO}"
  )

  add_library(cudf_backtrace INTERFACE)
  target_compile_definitions(cudf_backtrace INTERFACE CUDF_BUILD_STACKTRACE_DEBUG)
  target_compile_options(
    cudf_backtrace INTERFACE "$<$<COMPILE_LANGUAGE:CXX>:-Og>"
                             "$<$<COMPILE_LANGUAGE:CUDA>:-Xcompiler=-Og>"
  )
  target_link_options(
    cudf_backtrace INTERFACE "$<$<LINK_LANGUAGE:CXX>:-rdynamic>"
    "$<$<LINK_LANGUAGE:CUDA>:-Xlinker=-rdynamic>"
  )
  target_link_libraries(cudf PRIVATE cudf_backtrace)
endif()

# Specify include paths for the current target and dependents
target_include_directories(
  cudf
  PUBLIC "$<BUILD_INTERFACE:${DLPACK_INCLUDE_DIR}>"
         "$<BUILD_INTERFACE:${JITIFY_INCLUDE_DIR}>"
         "$<BUILD_INTERFACE:${CUDF_SOURCE_DIR}/include>"
         "$<BUILD_INTERFACE:${CUDF_GENERATED_INCLUDE_DIR}/include>"
  PRIVATE "$<BUILD_INTERFACE:${CUDF_SOURCE_DIR}/src>"
  INTERFACE "$<INSTALL_INTERFACE:include>"
)

target_compile_definitions(
  cudf PUBLIC "$<$<COMPILE_LANGUAGE:CXX>:${CUDF_CXX_DEFINITIONS}>"
              "$<BUILD_INTERFACE:$<$<COMPILE_LANGUAGE:CUDA>:${CUDF_CUDA_DEFINITIONS}>>"
)

# Disable Jitify log printing. See https://github.com/NVIDIA/jitify/issues/79
target_compile_definitions(cudf PRIVATE "JITIFY_PRINT_LOG=0")

if(JITIFY_USE_CACHE)
  # Instruct src/jit/cache what version of cudf we are building so it can compute a cal-ver cache
  # directory. We isolate this definition to the single source so it doesn't effect compiling
  # caching for all of libcudf
  set_property(
    SOURCE src/jit/cache.cpp
    APPEND
    PROPERTY COMPILE_DEFINITIONS "JITIFY_USE_CACHE" "CUDF_VERSION=${PROJECT_VERSION}"
  )
endif()

# Per-thread default stream
if(CUDF_USE_PER_THREAD_DEFAULT_STREAM)
  target_compile_definitions(
    cudf PUBLIC CUDA_API_PER_THREAD_DEFAULT_STREAM CUDF_USE_PER_THREAD_DEFAULT_STREAM
  )
endif()

# Disable NVTX if necessary
if(NOT USE_NVTX)
  target_compile_definitions(cudf PUBLIC NVTX_DISABLE)
endif()

# Define RMM logging level
target_compile_definitions(cudf PRIVATE "RMM_LOGGING_LEVEL=LIBCUDF_LOGGING_LEVEL")

# Define spdlog level
target_compile_definitions(cudf PUBLIC "SPDLOG_ACTIVE_LEVEL=SPDLOG_LEVEL_${LIBCUDF_LOGGING_LEVEL}")

# Compile stringified JIT sources first
add_dependencies(cudf jitify_preprocess_run)

# Specify the target module library dependencies
target_link_libraries(
  cudf
  PUBLIC ${ARROW_LIBRARIES} libcudacxx::libcudacxx cudf::Thrust rmm::rmm
  PRIVATE cuco::cuco ZLIB::ZLIB nvcomp::nvcomp kvikio::kvikio
          $<TARGET_NAME_IF_EXISTS:cuFile_interface>
)

# Add Conda library, and include paths if specified
if(TARGET conda_env)
  target_link_libraries(cudf PRIVATE conda_env)
endif()

if(CUDA_STATIC_RUNTIME)
  # Tell CMake what CUDA language runtime to use
  set_target_properties(cudf PROPERTIES CUDA_RUNTIME_LIBRARY Static)
  # Make sure to export to consumers what runtime we used
  target_link_libraries(cudf PUBLIC CUDA::cudart_static)
else()
  # Tell CMake what CUDA language runtime to use
  set_target_properties(cudf PROPERTIES CUDA_RUNTIME_LIBRARY Shared)
  # Make sure to export to consumers what runtime we used
  target_link_libraries(cudf PUBLIC CUDA::cudart)
endif()

file(
  WRITE "${CUDF_BINARY_DIR}/fatbin.ld"
  [=[
SECTIONS
{
  .nvFatBinSegment : { *(.nvFatBinSegment) }
  .nv_fatbin : { *(.nv_fatbin) }
}
]=]
)
target_link_options(cudf PRIVATE "$<HOST_LINK:${CUDF_BINARY_DIR}/fatbin.ld>")

add_library(cudf::cudf ALIAS cudf)

# ##################################################################################################
# * tests and benchmarks --------------------------------------------------------------------------
# ##################################################################################################

# ##################################################################################################
# * build cudftestutil ----------------------------------------------------------------------------

if(CUDF_BUILD_TESTUTIL)
  add_library(
    cudftest_default_stream
    # When compiled as a dynamic library allows us to use LD_PRELOAD injection of symbols. We
    # currently leverage this for stream-related library validation and may make use of it for
    # other similar features in the future.
    tests/utilities/default_stream.cpp
  )
  set_target_properties(
    cudftest_default_stream
    PROPERTIES BUILD_RPATH "\$ORIGIN"
               INSTALL_RPATH "\$ORIGIN"
               # set target compile options
               CXX_STANDARD 17
               CXX_STANDARD_REQUIRED ON
               CUDA_STANDARD 17
               CUDA_STANDARD_REQUIRED ON
               POSITION_INDEPENDENT_CODE ON
               INTERFACE_POSITION_INDEPENDENT_CODE ON
  )
  target_link_libraries(
    cudftest_default_stream
    PUBLIC cudf
    PRIVATE $<TARGET_NAME_IF_EXISTS:conda_env>
  )

  add_library(cudf::cudftest_default_stream ALIAS cudftest_default_stream)

  # Needs to be static so that we support usage of static builds of gtest which doesn't compile with
  # fPIC enabled and therefore can't be embedded into shared libraries.
  add_library(
    cudftestutil STATIC
    tests/io/metadata_utilities.cpp
    tests/utilities/base_fixture.cpp
    tests/utilities/column_utilities.cu
    tests/utilities/table_utilities.cu
    tests/utilities/tdigest_utilities.cu
  )

  set_target_properties(
    cudftestutil
    PROPERTIES BUILD_RPATH "\$ORIGIN"
               INSTALL_RPATH "\$ORIGIN"
               # set target compile options
               CXX_STANDARD 17
               CXX_STANDARD_REQUIRED ON
               CUDA_STANDARD 17
               CUDA_STANDARD_REQUIRED ON
               POSITION_INDEPENDENT_CODE ON
               INTERFACE_POSITION_INDEPENDENT_CODE ON
  )

  target_compile_options(
    cudftestutil PUBLIC "$<BUILD_INTERFACE:$<$<COMPILE_LANGUAGE:CXX>:${CUDF_CXX_FLAGS}>>"
                        "$<BUILD_INTERFACE:$<$<COMPILE_LANGUAGE:CUDA>:${CUDF_CUDA_FLAGS}>>"
  )

  target_link_libraries(
    cudftestutil
    PUBLIC GTest::gmock GTest::gtest Threads::Threads cudf cudftest_default_stream
    PRIVATE $<TARGET_NAME_IF_EXISTS:conda_env>
  )

  target_include_directories(
    cudftestutil PUBLIC "$<BUILD_INTERFACE:${CUDF_SOURCE_DIR}>"
                        "$<BUILD_INTERFACE:${CUDF_SOURCE_DIR}/src>"
  )
  add_library(cudf::cudftestutil ALIAS cudftestutil)

endif()

# * build cudf_identify_stream_usage --------------------------------------------------------------

if(CUDF_BUILD_STREAMS_TEST_UTIL)
  if(CUDA_STATIC_RUNTIME)
    message(
      FATAL_ERROR
        "Stream identification cannot be used with a static CUDA runtime. Please set CUDA_STATIC_RUNTIME=OFF or CUDF_BUILD_STREAMS_TEST_UTIL=OFF."
    )
  endif()

  # Libraries for stream-related testing. We build the library twice, one with STREAM_MODE_TESTING
  # on and one with it set to off. Each test will then be configured to use the appropriate library
  # depending via ctest and whether it has been updated to expose public stream APIs.
  foreach(_mode cudf testing)
    set(_tgt "cudf_identify_stream_usage_mode_${_mode}")
    add_library(
      ${_tgt} SHARED src/utilities/stacktrace.cpp tests/utilities/identify_stream_usage.cpp
    )

    set_target_properties(
      ${_tgt}
      PROPERTIES # set target compile options
                 CXX_STANDARD 17
                 CXX_STANDARD_REQUIRED ON
                 POSITION_INDEPENDENT_CODE ON
    )
    target_compile_options(
      ${_tgt} PRIVATE "$<BUILD_INTERFACE:$<$<COMPILE_LANGUAGE:CXX>:${CUDF_CXX_FLAGS}>>"
    )
    target_include_directories(${_tgt} PRIVATE "$<BUILD_INTERFACE:${CUDF_SOURCE_DIR}/include>")
    target_link_libraries(${_tgt} PUBLIC CUDA::cudart rmm::rmm)
    if(CUDF_BUILD_STACKTRACE_DEBUG)
      target_link_libraries(${_tgt} PRIVATE cudf_backtrace)
    endif()
    add_library(cudf::${_tgt} ALIAS ${_tgt})

    if("${_mode}" STREQUAL "testing")
      target_compile_definitions(${_tgt} PUBLIC STREAM_MODE_TESTING)
    endif()
  endforeach()
endif()

# ##################################################################################################
# * add tests -------------------------------------------------------------------------------------

if(CUDF_BUILD_TESTS)
  # include CTest module -- automatically calls enable_testing()
  include(CTest)

  # ctest cuda memcheck
  find_program(CUDA_SANITIZER compute-sanitizer)
  set(MEMORYCHECK_COMMAND ${CUDA_SANITIZER})
  set(MEMORYCHECK_TYPE CudaSanitizer)
  set(CUDA_SANITIZER_COMMAND_OPTIONS "--tool memcheck")

  # Always print verbose output when tests fail if run using `make test`.
  list(APPEND CMAKE_CTEST_ARGUMENTS "--output-on-failure")
  add_subdirectory(tests)
endif()

# ##################################################################################################
# * add benchmarks --------------------------------------------------------------------------------

if(CUDF_BUILD_BENCHMARKS)
  # Find or install GoogleBench
  include(${rapids-cmake-dir}/cpm/gbench.cmake)
  rapids_cpm_gbench()

  # Find or install nvbench
  include(cmake/thirdparty/get_nvbench.cmake)

  add_subdirectory(benchmarks)
endif()

# ##################################################################################################
# * install targets -------------------------------------------------------------------------------
rapids_cmake_install_lib_dir(lib_dir)
include(CPack)
include(GNUInstallDirs)

set(CMAKE_INSTALL_DEFAULT_COMPONENT_NAME cudf)

# install target for cudf_base and the proxy libcudf.so
install(
  TARGETS cudf
  DESTINATION ${lib_dir}
  EXPORT cudf-exports
)

set(_components_export_string)
if(TARGET cudftestutil)
  install(
    TARGETS cudftest_default_stream cudftestutil
    DESTINATION ${lib_dir}
    EXPORT cudf-testing-exports
  )
  set(_components_export_string COMPONENTS testing COMPONENTS_EXPORT_SET cudf-testing-exports)
endif()

install(DIRECTORY ${CUDF_SOURCE_DIR}/include/cudf ${CUDF_SOURCE_DIR}/include/cudf_test
                  ${CUDF_SOURCE_DIR}/include/nvtext DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
)

if(CUDF_BUILD_STREAMS_TEST_UTIL)
  install(TARGETS cudf_identify_stream_usage_mode_cudf DESTINATION ${lib_dir})
  install(TARGETS cudf_identify_stream_usage_mode_testing DESTINATION ${lib_dir})
endif()

set(doc_string
    [=[
Provide targets for the cudf library.

Built based on the Apache Arrow columnar memory format, cuDF is a GPU DataFrame
library for loading, joining, aggregating, filtering, and otherwise
manipulating data.

cuDF provides a pandas-like API that will be familiar to data engineers &
data scientists, so they can use it to easily accelerate their workflows
without going into the details of CUDA programming.


Imported Targets
^^^^^^^^^^^^^^^^

If cudf is found, this module defines the following IMPORTED GLOBAL
targets:

 cudf::cudf             - The main cudf library.

This module offers an optional testing component which defines the
following IMPORTED GLOBAL  targets:

 cudf::cudftestutil     - The main cudf testing library
    ]=]
)

set(common_code_string
    [=[
if(NOT TARGET cudf::Thrust)
  thrust_create_target(cudf::Thrust FROM_OPTIONS)
endif()
]=]
)

if(CUDF_ENABLE_ARROW_PARQUET)
  string(
    APPEND
    install_code_string
    [=[
  if(NOT Parquet_DIR)
    set(Parquet_DIR "${Arrow_DIR}")
  endif()
  set(ArrowDataset_DIR "${Arrow_DIR}")
  find_dependency(ArrowDataset)
  ]=]
  )
endif()

string(
  APPEND
  install_code_string
  [=[
if(testing IN_LIST cudf_FIND_COMPONENTS)
  enable_language(CUDA)
endif()
]=]
)
string(APPEND install_code_string "${common_code_string}")

rapids_export(
  INSTALL cudf
  EXPORT_SET cudf-exports ${_components_export_string}
  GLOBAL_TARGETS cudf cudftestutil
  NAMESPACE cudf::
  DOCUMENTATION doc_string
  FINAL_CODE_BLOCK install_code_string
)

# ##################################################################################################
# * build export -------------------------------------------------------------------------------
set(build_code_string
    [=[
if(EXISTS "${CMAKE_CURRENT_LIST_DIR}/cudf-testing-dependencies.cmake")
  include("${CMAKE_CURRENT_LIST_DIR}/cudf-testing-dependencies.cmake")
endif()
if(EXISTS "${CMAKE_CURRENT_LIST_DIR}/cudf-testing-targets.cmake")
  include("${CMAKE_CURRENT_LIST_DIR}/cudf-testing-targets.cmake")
endif()
]=]
)

string(APPEND build_code_string "${common_code_string}")

rapids_export(
  BUILD cudf
  EXPORT_SET cudf-exports ${_components_export_string}
  GLOBAL_TARGETS cudf cudftestutil
  NAMESPACE cudf::
  DOCUMENTATION doc_string
  FINAL_CODE_BLOCK build_code_string
)

# ##################################################################################################
# * make documentation ----------------------------------------------------------------------------

# doc targets for cuDF
add_custom_command(
  OUTPUT CUDF_DOXYGEN
  WORKING_DIRECTORY ${CUDF_SOURCE_DIR}/doxygen
  COMMAND doxygen Doxyfile
  VERBATIM
  COMMENT "Custom command for building cudf doxygen docs."
)

add_custom_target(
  docs_cudf
  DEPENDS CUDF_DOXYGEN
  COMMENT "Custom command for building cudf doxygen docs."
)

# ##################################################################################################
# * make gdb helper scripts ------------------------------------------------------------------------

# build pretty-printer load script
if(Thrust_SOURCE_DIR AND rmm_SOURCE_DIR)
  configure_file(scripts/load-pretty-printers.in load-pretty-printers @ONLY)
endif()
